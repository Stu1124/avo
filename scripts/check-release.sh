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

# What ships is what is tracked, so inside a git work tree the gate scans tracked files only.
# Untracked scratch and the ignored internal planning notes never reach a clone, and a gate that
# reported them is a gate nobody reads. An extracted tarball has no git metadata, so the fallback
# walks the tree instead, skipping the same directories by name (--exclude-dir matches a
# directory's *name*, not a path).
# This script is excluded from every pass: the comments here have to name the strings they look
# for. The LICENSE copyright line is the one allowed personal string and is filtered out too.
EXCLUDES=(--exclude-dir=.git --exclude-dir=.superpowers
          --exclude-dir=dist --exclude-dir=build --exclude=check-release.sh)
EXTRA=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  scan() { git grep -nE "$@" -- . ':(exclude)scripts/check-release.sh' "${EXTRA[@]}" || true }
  skip_changelog() { EXTRA=(':(exclude)CHANGELOG.md') }
else
  scan() { grep -rnE "$@" "${EXCLUDES[@]}" "${EXTRA[@]}" . || true }
  skip_changelog() { EXTRA=(--exclude=CHANGELOG.md) }
fi

# BSD grep prints paths without a leading "./" and GNU grep prints them with one, so match both.
NOT_LICENSE='(^\./)?LICENSE'

fail=0

names=$(scan -i 'aristu|sachdev|wiener|fogcity|voiceos' | grep -vE "$NOT_LICENSE" || true)
paths=$(scan '/Users/' | grep -vE "$NOT_LICENSE" || true)
hits=${${names}:+$names$'\n'}$paths
hits=${hits%$'\n'}
echo "=== personal strings ==="
if [[ -n "$hits" ]]; then print -r -- "$hits"; fail=1; else echo "(none)"; fi

# CHANGELOG.md keeps the single "formerly Halo" line that tells upgraders what this used to be.
skip_changelog
hits=$(scan -i 'halo' | grep -vE "$NOT_LICENSE" || true)
echo "=== old product name (CHANGELOG.md excluded) ==="
if [[ -n "$hits" ]]; then print -r -- "$hits"; fail=1; else echo "(none)"; fi

if (( fail )); then
  echo
  echo "Release gate FAILED. Remove the lines above before publishing."
  exit 1
fi
echo
echo "Release gate passed."
