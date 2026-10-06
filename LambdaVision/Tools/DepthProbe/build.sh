#!/usr/bin/env bash
# Checks the reprojection-depth shaders (Shaders.metal fragmentShaderDepth,
# reprojectionDepthMerge) on the Mac against engine dumps (r_vrdump N writes
# vrdumpN.bin — see VisionPort's desktop build). See main.swift.
#
#   ./build.sh vrdump1.bin [vrdump2.bin ...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
app=$(cd "$here/../../LambdaVision" && pwd)
work="${TMPDIR:-/tmp}/depth_probe.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

xcrun -sdk macosx metal -std=metal3.1 -I "$app" -c "$app/Shaders.metal" -o "$work/s.air"
xcrun -sdk macosx metallib "$work/s.air" -o "$work/shaders.metallib"
swiftc -O -import-objc-header "$app/ShaderTypes.h" "$here/main.swift" -o "$work/probe" \
    -framework Metal
"$work/probe" "$work/shaders.metallib" "$@"
