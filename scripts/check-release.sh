#!/bin/zsh
# zsh-only substitutions live below, so re-exec under zsh when started as `bash <script>`.
[ -n "$ZSH_VERSION" ] || exec /bin/zsh "$0" "$@"
# Publish gate. Prints every string that must not ship and exits 1 if there are any.
#
# Two passes over the working tree:
#   1. personal strings — names and old project names (case-insensitive), plus absolute home paths
#      (case-sensitive: `/Users/` is a real macOS path, while a case-insensitive match also hits
#      `/users/me` in the Google API URLs, which is not a personal string);
#   2. the old product name, everywhere except CHANGELOG.md, where one "formerly Halo" line is
#      deliberate.
# The LICENSE copyright line is the one allowed personal string and is filtered out of both.
#
# Runs in CI and in the release workflow, and is worth running by hand before tagging: it should
# print nothing but the two "(none)" lines.
set -uo pipefail
cd "$(dirname "$0")/.."

# --exclude-dir matches a directory's *name*, not a path, so the internal planning notes — removed
# from the public snapshot — are skipped by naming both directory names they use.
# This script is excluded from its own passes: the comments above have to name the strings they
# look for, and a gate that always reports itself is a gate nobody reads.
EXCLUDES=(--exclude-dir=.git --exclude-dir=.superpowers --exclude-dir=superpowers
          --exclude-dir=dist --exclude-dir=build --exclude=check-release.sh)
# BSD grep prints paths without a leading "./" and GNU grep prints them with one, so match both.
NOT_LICENSE='(^\./)?LICENSE'

fail=0

names=$(grep -rniE 'aristu|sachdev|wiener|fogcity|voiceos' "${EXCLUDES[@]}" . | grep -vE "$NOT_LICENSE" || true)
paths=$(grep -rnE '/Users/' "${EXCLUDES[@]}" . | grep -vE "$NOT_LICENSE" || true)
hits=${${names}:+$names$'\n'}$paths
hits=${hits%$'\n'}
echo "=== personal strings ==="
if [[ -n "$hits" ]]; then print -r -- "$hits"; fail=1; else echo "(none)"; fi

# CHANGELOG.md keeps the single "formerly Halo" line that tells upgraders what this used to be.
hits=$(grep -rniE 'halo' "${EXCLUDES[@]}" --exclude=CHANGELOG.md . | grep -vE "$NOT_LICENSE" || true)
echo "=== old product name (CHANGELOG.md excluded) ==="
if [[ -n "$hits" ]]; then print -r -- "$hits"; fail=1; else echo "(none)"; fi

if (( fail )); then
  echo
  echo "Release gate FAILED. Remove the lines above before publishing."
  exit 1
fi
echo
echo "Release gate passed."
