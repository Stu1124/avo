#!/bin/zsh
# zsh-only substitutions live below, so re-exec under zsh when started as `bash <script>`.
[ -n "$ZSH_VERSION" ] || exec /bin/zsh "$0" "$@"
# Compiles and runs every tests/*Tests.swift as a standalone executable.
# Each test file declares its source dependencies on its first line:
#   // deps: Avo/Agent/RequestPolicy.swift Avo/Agent/Other.swift
set -e
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/avo-tests; mkdir -p "$OUT"
exit_status=0
for t in tests/*Tests.swift; do
  name=$(basename "$t" .swift)
  deps=$(head -1 "$t" | sed -nE 's#^// deps: ##p')
  if ! swiftc -O -parse-as-library "$t" ${=deps} -o "$OUT/$name" 2>"$OUT/$name.log"; then
    echo "FAIL (compile): $name"; cat "$OUT/$name.log"; exit_status=1; continue
  fi
  if "$OUT/$name"; then :; else echo "FAIL: $name"; exit_status=1; fi
done
exit $exit_status
