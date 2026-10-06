#!/usr/bin/env bash
# Builds xash3d-fwgs and the game code natively for this Mac, with the
# visionOS patches and the VR layer applied, and lays out a runnable game
# folder in build/mac-run: Half-Life, plus every game build_game.sh has
# fetched (VisionPort/games-src/, e.g. Opposing Force as gearbox) whose files
# are in HalfLifeAssets. For work that needs the real engine but not the headset:
# timing level changes ([LT] lines in the log), trying engine changes, and
# dumping views for the snapshot probe (r_vrdump N → vrdumpN.bin).
#
#   ./build_xash_macos.sh                 build and lay out
#   cd ../build/mac-run && ./xash3d -game valve -dev 1 -windowed +map c1a0
#   cd ../build/mac-run && ./xash3d -game gearbox -dev 1 -windowed +map of1a1
#   cd ../build/mac-run-ro && XASH_FS_RAMCACHE=1 ./xash3d -game valve \
#       -rodir ../../HalfLifeAssets -dev 1 -windowed +map c1a0   (device layout)
#
# Builds out of tree (build-mac/), so the device builds are untouched.
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
# Game code: Half-Life from hlsdk-portable, plus every other game fetched by
# build_game.sh (VisionPort/games-src/*) whose files are in HalfLifeAssets.
games=("$here/hlsdk-portable")
for g in "$here"/games-src/*; do [ -d "$g" ] && games+=("$g"); done

# lay_out <gamedir> <server dylib> <client dylib> <dll name>
lay_out() {
    local gd="$1" sv="$2" cl="$3" dll="$4" e n f
    local a="$root/HalfLifeAssets/$gd"
    mkdir -p "$run/$gd/dlls" "$run/$gd/cl_dlls" "$run/$gd/maps/graphs" "$run/$gd/media"
    for e in "$a"/*; do
        n=$(basename "$e")
        case "$n" in
            dlls|cl_dlls|maps|media|config.cfg|save|SAVE) ;;
            *) ln -sfn "$e" "$run/$gd/$n" ;;
        esac
    done
    for f in "$a"/maps/*; do
        [ "$(basename "$f")" = graphs ] || ln -sfn "$f" "$run/$gd/maps/"
    done
    # Node graphs are rewritten when stale, so the folder gets copies.
    [ -d "$a/maps/graphs" ] && cp -pn "$a"/maps/graphs/* "$run/$gd/maps/graphs/" 2>/dev/null || true
    for f in "$a"/media/*; do ln -sfn "$f" "$run/$gd/media/"; done
    for n in "$dll" "${dll}_arm64"; do ln -sfn "$sv" "$run/$gd/dlls/$n.dylib"; done
    for n in client client_arm64; do ln -sfn "$cl" "$run/$gd/cl_dlls/$n.dylib"; done
    # The device's layout: game files read-only through -rodir, only the game
    # code and whatever the engine writes in the working folder. This is the
    # layout the RAM mirror (filesystem/ramcache.c) covers, so load timing
    # with XASH_FS_RAMCACHE=1 belongs here.
    mkdir -p "$ro/$gd/dlls" "$ro/$gd/cl_dlls"
    for n in "$dll" "${dll}_arm64"; do ln -sfn "$sv" "$ro/$gd/dlls/$n.dylib"; done
    for n in client client_arm64; do ln -sfn "$cl" "$ro/$gd/cl_dlls/$n.dylib"; done
    cp -p "$a/liblist.gam" "$ro/$gd/"
}

ro="$root/build/mac-run-ro"
mkdir -p "$ro"
# Copies, as the engine takes its folder from the binary. install writes a
# new file and renames it over the old one: rewriting a signed binary in
# place gets it killed at launch (Code Signature Invalid).
for f in "$run"/xash3d "$run"/*.dylib; do install -m 755 "$f" "$ro/"; done

built=()
for g in "${games[@]}"; do
    info="$("$here/build_game.sh" --mac "$g" | tail -n 4)"
    gd="$(printf '%s\n' "$info" | sed -n 's/^gamedir: //p')"
    dll="$(printf '%s\n' "$info" | sed -n 's/^dll: //p')"
    sv="$(printf '%s\n' "$info" | sed -n 's/^server: //p')"
    cl="$(printf '%s\n' "$info" | sed -n 's/^client: //p')"
    if [ ! -f "$root/HalfLifeAssets/$gd/liblist.gam" ]; then
        echo "skipping $gd: no game files in HalfLifeAssets/$gd"
        continue
    fi
    lay_out "$gd" "$sv" "$cl" "$dll"
    built+=("$gd")
done
echo "ready (${built[*]}): $run/xash3d -game <gamedir>"
echo "       $ro/xash3d -game <gamedir> -rodir $root/HalfLifeAssets   (device layout)"
