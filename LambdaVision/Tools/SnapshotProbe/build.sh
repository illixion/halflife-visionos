#!/usr/bin/env bash
# Tunes the level-load snapshot (SnapshotShaders.metal) on the Mac.
#
# Renders views dumped by the Mac engine build (r_vrdump N writes
# vrdumpN.bin — see VisionPort's desktop build) from a set of head motions,
# the way the app redraws the last frame before a load, and writes one PNG
# per motion plus a contact sheet.
#
#   ./build.sh out_dir vrdump1.bin [vrdump2.bin ...] [--grid 16] [--tear 1.08]
#
# The unmoved view must reproduce the dump; the probe fails if it does not.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
app=$(cd "$here/../../LambdaVision" && pwd)
work="${TMPDIR:-/tmp}/snapshot_probe.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

xcrun -sdk macosx metal -std=metal3.1 -I "$app" -c "$app/SnapshotShaders.metal" -o "$work/s.air"
xcrun -sdk macosx metallib "$work/s.air" -o "$work/snapshot.metallib"
swiftc -O -import-objc-header "$app/ShaderTypes.h" "$here/main.swift" -o "$work/probe" \
    -framework Metal -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers
"$work/probe" "$work/snapshot.metallib" "$@"
