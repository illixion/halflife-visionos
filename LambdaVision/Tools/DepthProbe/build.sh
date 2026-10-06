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

# SHADERS=path/to/Shaders.metal runs another version (an A/B against an
# older commit); SSPR_DEBUG adds the resolve's per-ray record the
# see-through check reads (the app never defines it).
xcrun -sdk macosx metal -std=metal3.1 -DSSPR_DEBUG=1 ${SSPR_DEFINES:-} -I "$app" -c "${SHADERS:-$app/Shaders.metal}" -o "$work/s.air"
xcrun -sdk macosx metallib "$work/s.air" -o "$work/shaders.metallib"
swiftc -O -import-objc-header "$app/ShaderTypes.h" "$here/main.swift" -o "$work/probe" \
    -framework Metal -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers
"$work/probe" "$work/shaders.metallib" "$@"
