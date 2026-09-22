#!/usr/bin/env bash
# Builds and runs the avatar probe on the Mac against the app's own sources.
#
#   ./build.sh            run every check
#   ./build.sh --bones    also dump the rest skeleton
#   ./build.sh --obj      also write avatar_posed.obj (head and legs cut) here
#   ./build.sh --grips    also write grip_<weapon>.tri here: Gordon's right arm
#                         holding each gun; render_tri.py turns one into a PNG
#   ./build.sh path/to/other.mdl   probe a different player model
#
# Needs RAVEEngine checked out beside this repo (the app's own package
# dependency) — it is built in release once and linked directly.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
rave="$repo/../RAVEEngine"
app="$repo/LambdaVision/LambdaVision"

(cd "$rave" && swift build -c release --product RAVERig >/dev/null)
rk="$rave/.build/release"
out="${TMPDIR:-/tmp}/avatar_probe.$$"
swiftc -O -g -I "$rk" -L "$rk" -lRAVERig \
    -I "$app/Bridge" -import-objc-header "$here/bridge.h" \
    "$app/AvatarRig.swift" "$app/ViewmodelGrip.swift" \
    "$here/main.swift" "$here/viewmodels.swift" "$here/stubs.c" \
    "$app/Bridge/Lambda_WeaponModel.c" -o "$out" 2>&1 | grep -v "^$" | grep -vi "warning" || true
[ -x "$out" ] || { echo "build failed"; exit 1; }
trap 'rm -rf "$out" "$out.dSYM"' EXIT

model="$repo/HalfLifeAssets/valve/models/player/gordon/gordon.mdl"
"$out" "$model" "$@" 2>/dev/null
