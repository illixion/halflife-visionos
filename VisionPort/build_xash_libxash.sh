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
python3 ./waf configure --xros --disable-gl --disable-soft --enable-gles3compat --enable-static-gl
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
  ! -name 'launcher.c.*.o' \
  ! -path "*build/game_launch/*" \
  ! -path "*build/ref/common/ref_context.c.*.o" \
  ! -path "*build/ref/gl/*" | sort)

# Pre-link ref_gl objects (the GLES3COMPAT renderer + gl2_shim) into one .o
# with renderer entry-points (R_Init, R_Shutdown, Tri*, etc.) hidden. Those
# names collide with the engine's ref_common dispatch wrappers when whole-
# archive linked. GetRefAPI stays exported — engine reaches it via
# dlsym(RTLD_DEFAULT) at runtime, like vklite did.
GL_RAW_OBJS=( $(find "$PWD/build/ref/gl" -type f -name '*.o' | sort) )
GL_UNEXPORTS="$PWD/build/ref/gl/unexports.list"
cat > "$GL_UNEXPORTS" <<'EOF'
_R_Init
_R_Shutdown
_GL_GetProcAddress
_TriBrightness
_TriColor4f
_TriColor4ub
_TriCullFace
_TriRenderMode
_TriSpriteTexture
_TriWorldToScreen
_Mod_LoadAliasModel
EOF
GL_OBJ="$PWD/build/ref/gl/ref_gl.combined.o"
xcrun ld -r -arch arm64 -platform_version xros 2.0 26.4 \
  -unexported_symbols_list "$GL_UNEXPORTS" \
  -o "$GL_OBJ" "${GL_RAW_OBJS[@]}"
XASH_OBJS+=("$GL_OBJ")

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
mapfile -t HLSDK_RAW_OBJS < <(find "$PWD/build/dlls" "$PWD/build/game_shared" "$PWD/build/pm_shared" -type f -name '*.1.o' \
  ! -name 'vcs_info.c.*.o' | sort)
# vcs_info.c is intentionally kept raw (NOT in either prelink) so its
# globals (_g_VCSInfo_Commit / _g_VCSInfo_Branch) stay externally visible —
# both server's and cl_dll's Initialize() reference them via the prelinks'
# undefined-import slots, and resolve at app-link time to this single .o.
HLSDK_VCS_OBJ="$PWD/build/game_shared/vcs_info.c.1.o"

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
HLSDK_OBJS=("$HLSDK_OBJ" "$HLSDK_VCS_OBJ")

# --- hlsdk-portable client (cl_dll) ---
# Engine's CL_LoadProgs dlsyms HUD_VidInit / HUD_Init / Initialize / etc. from
# the client.dll. visionOS forbids dlopen, so prelink cl_dll's .2.o files into
# one .o with ONLY the C-style HUD_*/CAM_*/CL_*/IN_*/V_*/KB_*/Demo_* exports
# visible. C++ class method symbols (Z-mangled) overlap with server side and
# stay hidden — engine never resolves them via cl_dll anyway.
HLSDK_CL_RAW_OBJS=( $(find "$HERE/hlsdk-portable/build/cl_dll" "$HERE/hlsdk-portable/build/game_shared" "$HERE/hlsdk-portable/build/pm_shared" "$HERE/hlsdk-portable/build/dlls" -type f -name '*.2.o' \
  ! -name 'vcs_info.c.*.o' | sort) )
HLSDK_CL_EXPORTS="$HERE/hlsdk-portable/build/cl_exports.list"
nm -gU "$HERE/hlsdk-portable/build/cl_dll/client_arm64.dylib" \
  | awk '/ T / {print $NF}' | grep -v '^__Z' \
  | grep -vE '^_IN_(ActivateMouse|DeactivateMouse|MouseEvent)$' > "$HLSDK_CL_EXPORTS"

# IN_ActivateMouse / IN_DeactivateMouse / IN_MouseEvent collide three ways:
# (a) engine's input.c defines them (used by SDL hosts we don't compile,
#     and by in_keys.c which DOES need them callable),
# (b) cl_dll's input.cpp defines them as the HLSDK-side mouse handlers
#     (callable only after Initialize() — early calls deref NULL),
# (c) cl_game.c dlsyms them from RTLD_DEFAULT for cdll_exports.
# We rename the engine-side trio out of the way and supply no-op stubs from
# Lambda_Bridge.c (linked into the app exec). cl_dll's stay hidden in the
# combined .o. in_keys.c's intra-engine calls now resolve to the bridge
# stubs (safe early), and dlsym finds the bridge stubs (non-NULL → satisfies
# cdll_exports mandatory check). HLSDK's own client mouse path is inert in
# Stage A.
ENGINE_INPUT_OBJ="$HERE/xash3d-fwgs/build/engine/client/input/input.c.2.o"
/opt/homebrew/opt/llvm/bin/llvm-objcopy \
  --redefine-sym _IN_ActivateMouse=_xash_engine_IN_ActivateMouse \
  --redefine-sym _IN_DeactivateMouse=_xash_engine_IN_DeactivateMouse \
  --redefine-sym _IN_MouseEvent=_xash_engine_IN_MouseEvent \
  "$ENGINE_INPUT_OBJ" "$ENGINE_INPUT_OBJ"
HLSDK_CL_OBJ="$HERE/hlsdk-portable/build/cl_dll.combined.o"
xcrun ld -r -arch arm64 -platform_version xros 2.0 26.4 \
  -exported_symbols_list "$HLSDK_CL_EXPORTS" \
  -o "$HLSDK_CL_OBJ" "${HLSDK_CL_RAW_OBJS[@]}"
HLSDK_OBJS+=("$HLSDK_CL_OBJ")

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
