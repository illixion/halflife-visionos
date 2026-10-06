# Sourced by the visionOS build scripts (build_xash_libxash.sh, build_game.sh,
# pack_libxash.sh): device vs simulator settings and the llvm-objcopy lookup.
#
# XR_SIM=1 selects the visionOS Simulator.
# shellcheck shell=bash disable=SC2034 # the variables are for the scripts that source this

if [ "${XR_SIM:-0}" = "1" ]; then
  WAF_PLATFORM=--xros-simulator; SDK_NAME=xrsimulator; LD_PLATFORM=xros-simulator
  CLANG_TARGET=arm64-apple-xros2.0-simulator; ARCHIVE=libxash-sim.a; GAME_SUFFIX=-sim
else
  WAF_PLATFORM=--xros; SDK_NAME=xros; LD_PLATFORM=xros
  CLANG_TARGET=arm64-apple-xros2.0; ARCHIVE=libxash.a; GAME_SUFFIX=
fi
LIBXASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/LambdaVision/Vendor/libxash"

# `ld -r` for this platform: prelinks objects into one.
xros_prelink() {
  xcrun ld -r -arch arm64 -platform_version "$LD_PLATFORM" 2.0 26.4 "$@"
}

# llvm-objcopy is needed for the --redefine-sym prelink fixups (Apple's
# toolchain ships no objcopy). Prefer an explicit $LLVM_OBJCOPY, then Homebrew
# LLVM, then PATH, then the emsdk's bundled LLVM — any recent build handles
# Mach-O.
xros_find_objcopy() {
  OBJCOPY="${LLVM_OBJCOPY:-}"
  local cand
  for cand in /opt/homebrew/opt/llvm/bin/llvm-objcopy \
              "$(command -v llvm-objcopy 2>/dev/null || true)" \
              "$HOME/Projects/emsdk/upstream/bin/llvm-objcopy"; do
    [[ -n "$OBJCOPY" && -x "$OBJCOPY" ]] && break
    [[ -n "$cand" && -x "$cand" ]] && OBJCOPY="$cand"
  done
  if [[ -z "$OBJCOPY" || ! -x "$OBJCOPY" ]]; then
    echo "ERROR: llvm-objcopy not found — brew install llvm, or set LLVM_OBJCOPY=/path/to/llvm-objcopy" >&2
    exit 1
  fi
}
