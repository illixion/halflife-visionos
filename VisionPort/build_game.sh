#!/usr/bin/env bash
# Builds one game's code (server + client) for the app, from any
# hlsdk-portable-based source: Half-Life itself, the built-in Opposing Force
# and Blue Shift ports, or a mod someone compiles themselves.
#
#   ./build_game.sh <git-url-or-path> [branch]
#   ./build_game.sh https://github.com/FWGS/hlsdk-portable opfor
#   ./build_game.sh ~/src/mymod                 (a local checkout, built in place)
#   XR_SIM=1 ./build_game.sh ...                (visionOS Simulator)
#   ./build_game.sh --mac ...                   (native Mac dylibs, for build_xash_macos.sh)
#
# Options: --title "Name" (the library's display name; known gamedirs have
# one), --no-pack (don't fold the result into libxash.a).
#
# Steps: fetch (a URL is cloned under VisionPort/games-src/, a path is used
# as is), apply the VR layer (hlsdk-vr/apply.sh), build with waf, prelink
# server + client into one object whose exported symbols carry the prefix
# "lg_<gamedir>_" (the engine's COM_GetProcAddress adds it; see lib_posix.c),
# and write LambdaVision/Vendor/libxash/games/libgame-<gamedir>[-sim].a, which
# also registers the game for the compiled-games table. Then pack_libxash.sh
# folds every games/ archive into libxash.a, which the app force-loads.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=xros_env.sh
. "$here/xros_env.sh"

porting_guide="https://github.com/FWGS/xash3d-fwgs/blob/master/Documentation/development/mod-porting-guide.md"
title="" pack=1 mac=0
while [ $# -gt 0 ]; do
    case "$1" in
        --title) title="$2"; shift 2 ;;
        --no-pack) pack=0; shift ;;
        --mac) mac=1; shift ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) break ;;
    esac
done
source_arg="${1:-}"
ref="${2:-}"
if [ -z "$source_arg" ]; then
    echo "usage: $0 [--title Name] [--no-pack] [--mac] <git-url-or-path> [branch]" >&2
    exit 2
fi

# --- 1. source ---
if [ -d "$source_arg" ]; then
    src="$(cd "$source_arg" && pwd)"
    if [ -n "$ref" ]; then
        git -C "$src" checkout -q "$ref"
    fi
    origin="$src"
else
    name="$(basename "$source_arg" .git)"
    src="$here/games-src/$name${ref:+@$ref}"
    origin="$source_arg"
    if [ ! -d "$src/.git" ]; then
        mkdir -p "$here/games-src"
        git init -q "$src"
        git -C "$src" remote add origin "$source_arg"
    fi
    echo "Fetching $source_arg ${ref:-(default branch)}"
    git -C "$src" fetch -q --depth 1 origin "${ref:-HEAD}"
    # The VR layer edited tracked files last time; start from the fetched tree.
    git -C "$src" reset -q --hard FETCH_HEAD
    git -C "$src" submodule update -q --init --recursive --depth 1
fi
commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "Source: $origin${ref:+ ($ref)} at $commit"

if [ ! -f "$src/waf" ] || [ ! -f "$src/wscript" ] || [ ! -d "$src/dlls" ] || [ ! -d "$src/cl_dll" ]; then
    echo "ERROR: $src doesn't look like an hlsdk-portable tree (needs waf, wscript, dlls/, cl_dll/)." >&2
    echo "Mods written against Valve's original Windows HLSDK need porting first:" >&2
    echo "  $porting_guide" >&2
    exit 1
fi

# --- 2. VR layer ---
"$here/hlsdk-vr/apply.sh" "$src"

# --- 3. build ---
cd "$src"
build_failed() {
    echo "ERROR: $src didn't build as hlsdk-portable ($1); the log is above." >&2
    echo "If this mod targets Valve's original HLSDK (MSVC-isms, include case," >&2
    echo "64-bit pointer casts), port it first: $porting_guide" >&2
    exit 1
}
if [ "$mac" = 1 ]; then
    out=build-mac
    python3 ./waf configure -o "$out" -T release >/dev/null || build_failed "configure"
else
    if [ "${XR_SIM:-0}" = "1" ]; then out=build-xrsim; else out=build-xros; fi
    # Plain compiler flags rather than a waf platform option: works with
    # whatever waifulib the mod carries.
    xflags="-isysroot $(xcrun --show-sdk-path --sdk "$SDK_NAME") --target=$CLANG_TARGET"
    CC=clang CXX=clang++ CFLAGS="$xflags" CXXFLAGS="$xflags" LINKFLAGS="$xflags" \
        python3 ./waf configure -o "$out" >/dev/null || build_failed "configure"
fi
python3 ./waf build >/dev/null || build_failed "build"

cache_value() {
    sed -n "s/^$1 = '\\(.*\\)'\$/\\1/p" "$out/c4che/_cache.py" | head -n 1
}
gamedir="$(cache_value GAMEDIR)"
dll="$(cache_value SERVER_LIBRARY_NAME_OSX)"
[ -n "$dll" ] || dll="$(cache_value SERVER_LIBRARY_NAME)"
if [ -z "$gamedir" ] || [ -z "$dll" ]; then
    echo "ERROR: couldn't read GAMEDIR / SERVER_LIBRARY_NAME from $src/$out/c4che (mod_options.txt)." >&2
    exit 1
fi
if [ -z "$title" ]; then
    case "$gamedir" in
        valve) title="Half-Life" ;;
        gearbox) title="Opposing Force" ;;
        bshift) title="Blue Shift" ;;
        *) title="$gamedir" ;;
    esac
fi
echo "Built $title: gamedir $gamedir, gamedll $dll"

if [ "$mac" = 1 ]; then
    echo "server: $(find "$src/$out/dlls" -maxdepth 1 -name '*.dylib' | head -n 1)"
    echo "client: $(find "$src/$out/cl_dll" -maxdepth 1 -name '*.dylib' | head -n 1)"
    exit 0
fi

# --- 4. prelink to one object with the game's prefix ---
xros_find_objcopy
san="$(printf '%s' "$gamedir" | LC_ALL=C tr -c 'A-Za-z0-9_' '_')"
prefix="lg_${san}_"
work="$out/lambda"
mkdir -p "$work"

# waf numbers each task generator's objects (.N.o): the server and the client
# compile some files (weapons, pm_shared) both ways, so pick each side by a
# file only it has. vcs_info is a static lib both link; it goes in once.
obj_index() { find "$out/$1" -maxdepth 1 -name "$2.*.o" | sed -E 's/.*\.([0-9]+)\.o$/\1/' | head -n 1; }
sidx="$(obj_index dlls player.cpp)"
cidx="$(obj_index cl_dll cdll_int.cpp)"
if [ -z "$sidx" ] || [ -z "$cidx" ]; then
    echo "ERROR: can't find dlls/player.cpp or cl_dll/cdll_int.cpp objects in $src/$out." >&2
    exit 1
fi
objs_with_index() { find "$out" -name "*.$1.o" ! -name 'vcs_info.c.*' | sort; }
server_objs=() client_objs=()
while IFS= read -r f; do server_objs+=("$f"); done < <(objs_with_index "$sidx")
while IFS= read -r f; do client_objs+=("$f"); done < <(objs_with_index "$cidx")
vcs_obj="$(find "$out/game_shared" -name 'vcs_info.c.*.o' | head -n 1)"

# The client keeps only its C entry points (HUD_*, Initialize, F, V_*, …) and
# the VR layer's platform globals visible; its C++ classes duplicate the
# server's. IN_ActivateMouse / IN_DeactivateMouse / IN_MouseEvent stay hidden:
# the engine binds the app's stubs of those names (Lambda_Bridge.c), which are
# safe to call before Initialize.
client_dylib="$(find "$out/cl_dll" -maxdepth 1 -name 'client*.dylib' | head -n 1)"
{
    nm -gU "$client_dylib" | awk '/ T / {print $NF}' | grep -v '^__Z' \
        | grep -vE '^_IN_(ActivateMouse|DeactivateMouse|MouseEvent)$' || true
    nm -gU "$client_dylib" | awk '{print $NF}' | grep '^_g_vr_' || true
} > "$work/client_exports.list"

xros_prelink -o "$work/server.o" "${server_objs[@]}"
xros_prelink -exported_symbols_list "$work/client_exports.list" -o "$work/client.o" "${client_objs[@]}"
game_obj="$work/lg_${san}.o"   # the archive member name, unique in libxash.a
xros_prelink -o "$game_obj" "$work/server.o" "$work/client.o" ${vcs_obj:+"$vcs_obj"}

# Every exported name gets the prefix except the VR layer's platform globals,
# which are weak and shared by all games (the bridge reads one copy).
nm -gU "$game_obj" | awk '{print $NF}' | grep -v '^_g_vr_' \
    | awk -v p="_$prefix" '{print $1 " " p substr($1, 2)}' > "$work/renames.list"
"$OBJCOPY" --redefine-syms="$work/renames.list" "$game_obj" "$game_obj"

# The registration record pack_libxash.sh builds the table from.
entry_c="$work/${prefix}entry.c"
cat > "$entry_c" <<EOF
// Generated by build_game.sh from $origin${ref:+ ($ref)} at $commit.
typedef struct { const char *gamedir, *dll, *title; } lambda_compiled_game_t;
__attribute__((used, visibility("default")))
const lambda_compiled_game_t lambda_game_entry_${san} = { "$gamedir", "$dll", "$title" };
EOF
xcrun clang --target="$CLANG_TARGET" -isysroot "$(xcrun --show-sdk-path --sdk "$SDK_NAME")" \
    -c "$entry_c" -o "$work/${prefix}entry.o"

mkdir -p "$LIBXASH_DIR/games"
game_ar="$LIBXASH_DIR/games/libgame-$gamedir$GAME_SUFFIX.a"
xcrun libtool -static -no_warning_for_no_symbols -o "$game_ar" "$game_obj" "$work/${prefix}entry.o"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$gamedir" "$dll" "$title" "$origin" "${ref:-}" "$commit" \
    > "$LIBXASH_DIR/games/libgame-$gamedir$GAME_SUFFIX.source"
echo "Wrote $game_ar ($(stat -f%z "$game_ar") bytes, symbols ${prefix}*)"

if [ "$pack" = 1 ]; then
    "$here/pack_libxash.sh"
fi
