#!/usr/bin/env bash
# Checks the keyboard/mouse/gamepad free-aim zone on the Mac against the app's
# own source (FreeAim.swift and LazyViewFollower.swift, compiled verbatim):
# offset, overflow into body yaw, pitch clamping, the ellipse, the recentre,
# the head anchor's lazy follow, the engine offset and the gun transform.
#
#   ./build.sh
#
# Exits non-zero on the first failed check.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app="$repo/LambdaVision/LambdaVision"
out="$repo/build/free-aim-probe"
mkdir -p "$out"

swiftc -O "$app/FreeAim.swift" "$app/LazyViewFollower.swift" "$here/main.swift" -o "$out/probe"
"$out/probe" "$@"
