#!/usr/bin/env bash
# Checks the input catcher's decision rule and its events-per-second counter
# on the Mac against the app's own source (InputCatcherRule.swift and
# InputMode.swift, compiled verbatim).
#
#   ./build.sh
#
# Exits non-zero on the first failed check.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app="$repo/LambdaVision/LambdaVision"
out="$repo/build/catcher-probe"
mkdir -p "$out"

swiftc -O "$app/InputCatcherRule.swift" "$app/InputMode.swift" "$here/main.swift" -o "$out/probe"
"$out/probe" "$@"
