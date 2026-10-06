#!/usr/bin/env bash
# Checks the HEV HUD overlay's lazy view follow on the Mac against the app's
# own source (LazyViewFollower.swift, compiled verbatim): bounded lag,
# convergence without overshoot, and the same motion at any frame rate.
#
#   ./build.sh
#
# Exits non-zero on the first failed check.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app="$repo/LambdaVision/LambdaVision"
out="$repo/build/hud-probe"
mkdir -p "$out"

swiftc -O "$app/LazyViewFollower.swift" "$here/main.swift" -o "$out/probe"
"$out/probe" "$@"
