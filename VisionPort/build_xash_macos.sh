#!/usr/bin/env bash
# Builds xash3d-fwgs and hlsdk-portable natively for this Mac, with the
# visionOS patches applied, and lays out a runnable game folder in
# build/mac-run. For work that needs the real engine but not the headset:
# timing level changes ([LT] lines in the log), trying engine changes, and
# dumping views for the snapshot probe (r_vrdump N → vrdumpN.bin).
#
#   ./build_xash_macos.sh                 build and lay out
#   cd ../build/mac-run && ./xash3d -game valve -dev 1 -windowed +map c1a0
#
# Builds out of tree (build-mac/), so the device build (build/) is untouched.
# Needs Homebrew SDL2 and the game files in HalfLifeAssets/.
#
# The game folder links the assets in read-only: every directory the engine
# writes into (maps/graphs for node graphs, media for cdaudio.txt, saves,
# config) is local to build/mac-run, never a symlink into HalfLifeAssets.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
assets="$root/HalfLifeAssets/valve"
run="$root/build/mac-run"
[ -f "$assets/liblist.gam" ] || { echo "no game files in $assets" >&2; exit 1; }

(cd "$here/xash3d-fwgs" && python3 ./waf configure -o build-mac -T release --sdl-use-pkgconfig >/dev/null \
    && python3 ./waf build >/dev/null && python3 ./waf install --destdir="$run" >/dev/null)
(cd "$here/hlsdk-portable" && python3 ./waf configure -o build-mac -T release >/dev/null \
    && python3 ./waf build >/dev/null)

mkdir -p "$run/valve/dlls" "$run/valve/cl_dlls" "$run/valve/maps/graphs" "$run/valve/media"
for e in "$assets"/*; do
    n=$(basename "$e")
    case "$n" in
        dlls|cl_dlls|maps|media|config.cfg|save|SAVE) ;;
        *) ln -sfn "$e" "$run/valve/$n" ;;
    esac
done
for f in "$assets"/maps/*; do
    [ "$(basename "$f")" = graphs ] || ln -sfn "$f" "$run/valve/maps/"
done
# Node graphs are rewritten when stale, so the folder gets copies.
[ -d "$assets/maps/graphs" ] && cp -pn "$assets"/maps/graphs/* "$run/valve/maps/graphs/" 2>/dev/null || true
for f in "$assets"/media/*; do ln -sfn "$f" "$run/valve/media/"; done
hl="$here/hlsdk-portable/build-mac"
for n in hl hl_arm64; do ln -sfn "$hl/dlls/hl_arm64.dylib" "$run/valve/dlls/$n.dylib"; done
for n in client client_arm64; do ln -sfn "$hl/cl_dll/client_arm64.dylib" "$run/valve/cl_dlls/$n.dylib"; done
echo "ready: $run/xash3d -game valve"
