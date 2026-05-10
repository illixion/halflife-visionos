#!/usr/bin/env bash
# Build xash3d-fwgs (dedicated, no GL) and hlsdk-portable (server + client
# game logic) for arm64 visionOS device, then bundle every .o file into a
# single libxash.a that the Xcode project links via -force_load. visionOS
# forbids dlopen of external dylibs, so engine + filesystem + 3rdparty +
# HLSDK ship as one static archive; HLSDK entity factories are reached at
# runtime via dlsym(RTLD_DEFAULT) into the app's main exec.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# --- xash3d-fwgs ---
cd "$HERE/xash3d-fwgs"
git submodule update --init --recursive
rm -rf build
python3 ./waf configure --xros -d --disable-gl
# Final `xash` exec link is expected to fail (filesystem is normally a
# runtime-loaded dylib). We harvest .o files; ignore the link failure.
python3 ./waf build || true

SDK="$(xcrun --show-sdk-path --sdk xros)"
# Engine objects, raw — but excluding launcher.c (defines _main, conflicts
# with our SwiftUI app's main) and build/filesystem/ (those go through a
# pre-link step below to hide symbols that collide with engine globals when
# whole-archive linked via -force_load).
mapfile -t XASH_OBJS < <(find "$PWD/build" -type f -name '*.o' \
  ! -path "*build/filesystem/*" \
  ! -name 'launcher.c.*.o' | sort)

# Pre-link filesystem (filesystem_stdio) into one .o with overlap symbols
# hidden. Engine reaches FS via GetFSAPI/CreateInterface (extern in
# filesystem_engine.c under XASH_VISIONOS), so direct FS_* callers aren't
# needed visible.
FS_RAW_OBJS=( $(find "$PWD/build/filesystem" -type f -name '*.o' | sort) )
FS_UNEXPORTS="$PWD/build/filesystem/unexports.list"
cat > "$FS_UNEXPORTS" <<'EOF'
_FS_LoadFile
_FS_LoadDirectFile
_FS_Search
_FS_Open
_FS_Close
__Mem_Alloc
__Mem_Free
_FI
EOF
FS_OBJ="$PWD/build/filesystem/filesystem.combined.o"
xcrun ld -r -arch arm64 -platform_version xros 2.0 26.4 \
  -unexported_symbols_list "$FS_UNEXPORTS" \
  -o "$FS_OBJ" "${FS_RAW_OBJS[@]}"
# Filesystem defines `fs_globals_t FI;` (a 4112-byte struct) and engine
# defines `fs_globals_t *FI;` (an 8-byte pointer). Both are tentative
# (common) symbols, which the linker merges into the larger one when
# whole-archive linked — engine then reads filesystem's struct as if it
# were a pointer and dereferences ASCII garbage. Unexports don't hide
# common symbols, so rename filesystem's _FI here. Filesystem-internal
# references already resolved within the prelink above.
/opt/homebrew/opt/llvm/bin/llvm-objcopy --redefine-sym _FI=_xash_fs_FI "$FS_OBJ" "$FS_OBJ"
XASH_OBJS+=("$FS_OBJ")

# --- hlsdk-portable ---
# Only the server side (dlls/) goes into libxash.a today. The client side
# (cl_dll/) duplicates a large chunk of dlls/'s C++ classes (CBaseEntity,
# CBasePlayer, weapons, etc.) compiled with CLIENT_DLL — bundling both
# triggers ~hundreds of duplicate-symbol errors at app link time. We'll
# wire cl_dll back in once we tackle the renderer (HUD lives there);
# for now the server is enough to get the engine past entity init.
cd "$HERE/hlsdk-portable"
rm -rf build
python3 ./waf configure --xros
python3 ./waf build
# dlls/, game_shared/, pm_shared/ — only the .1.o flavor. waf compiles
# weapons + pm_shared TWICE (once for dlls without CLIENT_DLL/CLIENT_WEAPONS,
# once for cl_dll with both defined). The .1.o files are the dlls (server)
# build; .2.o is cl_dll's. We don't link cl_dll yet, so skipping .2.o
# avoids both duplicate symbols and the cl_dll-only externs (vJumpOrigin,
# iJumpSpectator) that would otherwise leak in.
mapfile -t HLSDK_RAW_OBJS < <(find "$PWD/build/dlls" "$PWD/build/game_shared" "$PWD/build/pm_shared" -type f -name '*.1.o' | sort)

# Hide HLSDK's pm_math/util internals that collide with engine globals
# under -force_load. Currently only _VectorAngles overlaps; if more turn
# up, append them here. Entity factories + GiveFnptrsToDll/etc. stay
# visible because they aren't listed.
HLSDK_UNEXPORTS="$HERE/hlsdk-portable/build/unexports.list"
printf '_VectorAngles\n' > "$HLSDK_UNEXPORTS"
HLSDK_OBJ="$HERE/hlsdk-portable/build/hlsdk.combined.o"
xcrun ld -r -arch arm64 -platform_version xros 2.0 26.4 \
  -unexported_symbols_list "$HLSDK_UNEXPORTS" \
  -o "$HLSDK_OBJ" "${HLSDK_RAW_OBJS[@]}"
HLSDK_OBJS=("$HLSDK_OBJ")

OUT="$HERE/../LambdaVision/Vendor/libxash"
mkdir -p "$OUT"

# --- cl_dll stubs ---
SDK="$(xcrun --show-sdk-path --sdk xros)"
STUB_OBJ="$HERE/lambda_hlsdk_stubs.o"
xcrun clang --target=arm64-apple-xros2.0 -isysroot "$SDK" -c \
  "$HERE/lambda_hlsdk_stubs.c" -o "$STUB_OBJ"

if [ "${SKIP_HLSDK:-0}" = "1" ]; then
  echo "Bundling ${#XASH_OBJS[@]} engine + 1 stub (HLSDK skipped) into libxash.a"
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/libxash.a" \
    "${XASH_OBJS[@]}" "$STUB_OBJ"
else
  echo "Bundling ${#XASH_OBJS[@]} engine + ${#HLSDK_OBJS[@]} HLSDK + 1 stub object files into libxash.a"
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/libxash.a" \
    "${XASH_OBJS[@]}" "${HLSDK_OBJS[@]}" "$STUB_OBJ"
fi
file "$OUT/libxash.a"
echo "Wrote $OUT/libxash.a ($(stat -f%z "$OUT/libxash.a") bytes)"
