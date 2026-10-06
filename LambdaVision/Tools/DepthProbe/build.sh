#!/usr/bin/env bash
# Checks the composite shaders (Shaders.metal: reprojection depth and glass)
# on the Mac against engine dumps (r_vrdump N writes
# vrdumpN.bin — see VisionPort's desktop build). See main.swift.
#
#   ./build.sh [--png DIR] vrdump1.bin [vrdump2.bin ...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
app=$(cd "$here/../../LambdaVision" && pwd)
work="${TMPDIR:-/tmp}/depth_probe.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

xcrun -sdk macosx metal -std=metal3.1 -I "$app" -c "$app/Shaders.metal" -o "$work/s.air"
xcrun -sdk macosx metallib "$work/s.air" -o "$work/shaders.metallib"
swiftc -O -import-objc-header "$app/ShaderTypes.h" "$here/main.swift" -o "$work/probe" \
    -framework Metal -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers
"$work/probe" "$work/shaders.metallib" "$@"
