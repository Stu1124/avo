#!/bin/zsh
# Builds, signs with Developer ID, notarizes, staples, and packages Avo.dmg + Avo.zip into dist/.
#
# Env:
#   AVO_TEAM_ID       your Apple Developer team id. Required unless --unsigned.
#   NOTARY_KEY_PATH   path to the App Store Connect .p8 key   ┐
#   NOTARY_KEY_ID     its key id                              ├ required unless --skip-notarize
#   NOTARY_ISSUER     its issuer uuid                         ┘
#
# Flags:
#   --skip-notarize   sign with Developer ID, but do not submit to Apple. Still a signed package.
#   --unsigned        no signing at all. Produces a package macOS will quarantine; the release
#                     workflow uses this when the repository has no signing secrets.
#
# The signed path needs a "Developer ID Application" certificate in the keychain. Create one in
# Xcode → Settings → Accounts → your team → Manage Certificates → + (Account Holder or an Admin
# granted Developer ID access), or import a .p12. Notarization also requires the hardened runtime;
# it and automatic signing come from project-release.yml, which xcodegen merges only when this
# script exports AVO_RELEASE=true. Nothing about signing is passed to xcodebuild on the command
# line, because a command-line setting applies to every target in the build, SwiftMath included.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=signed
for arg in "$@"; do
  case "$arg" in
    --unsigned) MODE=unsigned ;;
    --skip-notarize) MODE=skip-notarize ;;
    *) echo "usage: scripts/release.sh [--skip-notarize|--unsigned]" >&2; exit 2 ;;
  esac
done

VERSION=$(sed -nE 's/^ *CFBundleShortVersionString: "([^"]+)"/\1/p' project.yml)
[[ -n "$VERSION" ]] || { echo "Could not read CFBundleShortVersionString from project.yml" >&2; exit 1; }
DD=/tmp/avo-dd-package
ARCHIVE=$DD/Avo.xcarchive
EXPORT=$DD/export
DIST=dist
STAGE=$DD/dmg
rm -rf "$DD" "$DIST"
mkdir -p "$DIST"

# Signing settings are target-scoped in project-release.yml rather than passed to xcodebuild.
# A setting on the xcodebuild command line is global to the build and would also land on the
# SwiftMath package target, which has no team and no matching identity and then fails to sign.
# Automatic signing wants the certificate *kind*, not a specific identity — naming one is a
# "conflicting provisioning settings" error — so this deliberately overrides an AVO_CODE_SIGN_IDENTITY
# the shell may already export for scripts/install.sh. Xcode resolves $(AVO_CODE_SIGN_IDENTITY) in
# project.yml from the environment, which is what makes the override land on the Avo target only.
if [[ "$MODE" != unsigned ]]; then
  export AVO_RELEASE=true
  export AVO_CODE_SIGN_IDENTITY="Developer ID Application"
fi
xcodegen generate >/dev/null

if [[ "$MODE" == unsigned ]]; then
  xcodebuild -project Avo.xcodeproj -scheme Avo -configuration Release -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|BUILD'
  APP=$DD/Build/Products/Release/Avo.app
else
  : "${AVO_TEAM_ID:?set AVO_TEAM_ID, or pass --unsigned}"
  xcodebuild -project Avo.xcodeproj -scheme Avo -configuration Release -derivedDataPath "$DD" \
    -archivePath "$ARCHIVE" archive 2>&1 | grep -E 'error:|ARCHIVE'

  cat > "$DD/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$AVO_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

  EXPORT_AUTH=()
  if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    EXPORT_AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$NOTARY_KEY_PATH"
      -authenticationKeyID "$NOTARY_KEY_ID"
      -authenticationKeyIssuerID "$NOTARY_ISSUER")
  fi
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$DD/export.plist" "${EXPORT_AUTH[@]}" 2>&1 | grep -E 'error:|EXPORT'
  APP=$EXPORT/Avo.app
fi

if [[ "$MODE" == signed ]]; then
  : "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH, or pass --skip-notarize}"
  : "${NOTARY_KEY_ID:?set NOTARY_KEY_ID, or pass --skip-notarize}"
  : "${NOTARY_ISSUER:?set NOTARY_ISSUER, or pass --skip-notarize}"
  ditto -c -k --keepParent "$APP" "$DD/notarize.zip"
  xcrun notarytool submit "$DD/notarize.zip" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$APP"
fi

ditto -c -k --keepParent "$APP" "$DIST/Avo-$VERSION.zip"

# Stage the app next to an /Applications symlink so the mounted disk image is a drag-to-install
# window rather than a lone app the user has to know where to put.
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Avo.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Avo -srcfolder "$STAGE" -ov -format UDZO "$DIST/Avo-$VERSION.dmg" >/dev/null

# Only meaningful on a signed app: on an unsigned one spctl always rejects, which reads as a failure.
[[ "$MODE" == unsigned ]] || spctl -a -vv "$APP" 2>&1 | tail -2 || true
echo "dist/Avo-$VERSION.dmg and .zip ready"
