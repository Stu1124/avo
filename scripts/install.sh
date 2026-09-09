#!/bin/zsh
# Build Release. Installs + relaunches only with --now (never while you are mid-use unless you ask).
#
# Signing: project.yml reads the team id from AVO_TEAM_ID at `xcodegen generate` time and signs
# ad-hoc by default, so a build works with no Apple Developer account:
#   export AVO_TEAM_ID=XXXXXXXXXX     # optional; your Apple Developer team id
# To sign with a real certificate, export AVO_CODE_SIGN_IDENTITY (its name as shown by
#   security find-identity -v -p codesigning
# e.g. "Developer ID Application: Example (XXXXXXXXXX)"). It is forwarded to xcodebuild below as a
# user-defined setting of that same name, and project.yml maps it to CODE_SIGN_IDENTITY on the Avo
# target only. Passing CODE_SIGN_IDENTITY directly on the command line would apply to every target
# in the build, including the SwiftMath package, which then fails to sign and breaks the build.
#
# Keychains. Three build shapes, in increasing order of how little Avo bothers you:
#   1. ad-hoc (no variables): legacy keychain. Every rebuild has a new code signature, so the first
#      read after a rebuild raises a Keychain access prompt.
#   2. AVO_TEAM_ID + AVO_CODE_SIGN_IDENTITY: still the legacy keychain, but the signing identity is
#      stable, so the items stay trusted across rebuilds and the prompt does not come back.
#   3. AVO_SIGNED=true, on top of 2: adds the data-protection keychain access group
#      ($(AppIdentifierPrefix)app.avo.mac), which grants access by team prefix rather than by binary.
# Set AVO_SIGNED=true *only* if your team has a provisioning profile for app.avo.mac (a Mac App
# Development or Developer ID profile Xcode can resolve). The entitlement requires one, and without
# it the build fails with "entitlements that require signing with a development certificate". It is
# never derived from AVO_TEAM_ID or AVO_CODE_SIGN_IDENTITY — having a team id is not having a profile.
#   export AVO_SIGNED=true
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
SIGN=(); [[ -n "${AVO_CODE_SIGN_IDENTITY:-}" ]] && SIGN=(AVO_CODE_SIGN_IDENTITY="$AVO_CODE_SIGN_IDENTITY")
OUT=$(xcodebuild -project Avo.xcodeproj -scheme Avo -configuration Release -derivedDataPath /tmp/avo-dd-release "${SIGN[@]}" build 2>&1)
echo "$OUT" | grep -E 'error:|BUILD'
echo "$OUT" | grep -q 'BUILD SUCCEEDED' || { echo "Build failed; nothing installed."; exit 1; }
if [[ "$1" != "--now" ]]; then
  echo "Built. Run  scripts/install.sh --now  to install to /Applications and relaunch."
  exit 0
fi
pkill -x Avo || true
sleep 1
rm -rf /Applications/Avo.app ~/Applications/Avo.app
cp -R /tmp/avo-dd-release/Build/Products/Release/Avo.app /Applications/Avo.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Avo.app
# Keep the avo CLI fresh (/usr/local/bin first, ~/bin fallback — it is on PATH).
if cp scripts/avo /usr/local/bin/avo.tmp 2>/dev/null && mv /usr/local/bin/avo.tmp /usr/local/bin/avo 2>/dev/null; then
  CLI="Installed CLI: /usr/local/bin/avo"
else
  mkdir -p "$HOME/bin" && cp scripts/avo "$HOME/bin/avo" && chmod +x "$HOME/bin/avo"
  CLI="Installed CLI: ~/bin/avo (already on PATH)"
fi
open /Applications/Avo.app
echo "$CLI"
echo "Installed /Applications/Avo.app and relaunched."
