#!/usr/bin/env bash
# Build Google ANGLE (libEGL + libGLESv2, Metal backend only) for visionOS
# device + simulator, then bundle into one libANGLE.a per platform and drop
# it at LambdaVision/Vendor/angle/ for the Xcode project to link.
#
# Requires a sibling depot_tools checkout (managed under Vendor/angle-build).
# ~12 GiB of free disk for the gclient sync; subsequent rebuilds are quick.
#
# ANGLE is pinned to a known-good revision, the same way setup.sh pins
# xash3d-fwgs/hlsdk-portable: angle-visionos.patch edits chromium/build at
# the revision ANGLE's DEPS selects, so a floating HEAD stops applying (or
# builds something else) as upstream moves. gclient sync checks out the DEPS
# of this commit. The pin also keys the prebuilt release
# (scripts/prebuilt-keys.sh). Bump it only alongside re-verifying the patch.
set -euo pipefail

ANGLE_COMMIT=ca1dbd0b011ca3eeaae3a280bdd79cc8e22d211e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ANGLE_ROOT="$ROOT/Vendor/angle-build"
OUT_DIR="$ROOT/LambdaVision/Vendor/angle"

mkdir -p "$ANGLE_ROOT" "$OUT_DIR"

# --- 1. depot_tools ---
if [[ ! -d "$ANGLE_ROOT/depot_tools" ]]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git \
        "$ANGLE_ROOT/depot_tools"
fi
export PATH="$ANGLE_ROOT/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0

# --- 2. ANGLE source + gclient sync ---
if [[ ! -d "$ANGLE_ROOT/angle" ]]; then
    git init "$ANGLE_ROOT/angle"
    cd "$ANGLE_ROOT/angle"
    git remote add origin https://chromium.googlesource.com/angle/angle
    git fetch --depth 1 origin "$ANGLE_COMMIT"
    git checkout FETCH_HEAD
    cp scripts/bootstrap.py .
    python3 bootstrap.py
    gclient sync --no-history --shallow
    # Apply visionOS patches to chromium/build + ANGLE's known-rust-triples
    cd "$ANGLE_ROOT/angle/build"
    git apply "$HERE/angle-visionos.patch"
    # known-target-triples additions (not under build/, so handled separately)
    grep -qx 'aarch64-apple-visionos' \
        "$ANGLE_ROOT/angle/build/rust/known-target-triples.txt" || \
        printf 'aarch64-apple-visionos\naarch64-apple-visionos-sim\n' \
        >> "$ANGLE_ROOT/angle/build/rust/known-target-triples.txt"
else
    # An existing checkout is used as-is (no re-sync, its patched build/ stays).
    # Only say so when it isn't at the pin, since a rebuild then won't match
    # the prebuilt release.
    HAVE=$(git -C "$ANGLE_ROOT/angle" rev-parse HEAD 2>/dev/null || echo unknown)
    if [[ "$HAVE" != "$ANGLE_COMMIT" ]]; then
        echo "warning: Vendor/angle-build/angle is at $HAVE, pinned is $ANGLE_COMMIT." >&2
        echo "         Building the existing checkout; delete it to re-sync at the pin." >&2
    fi
fi

# --- 3. gn gen + ninja for device and simulator ---
cd "$ANGLE_ROOT/angle"
COMMON_ARGS='target_os="ios" target_platform="xros" target_cpu="arm64" ios_deployment_target="2.0" is_debug=false is_component_build=false ios_enable_code_signing=false angle_enable_metal=true angle_enable_vulkan=false angle_enable_gl=false angle_enable_swiftshader=false angle_enable_null=false angle_enable_wgpu=false symbol_level=1 use_custom_libcxx=false treat_warnings_as_errors=false'

for variant in device simulator; do
    if [[ "$variant" == device ]]; then OUT=out/xrosDevice; else OUT=out/xrosSim; fi
    gn gen "$OUT" --args="$COMMON_ARGS target_environment=\"$variant\""
    autoninja -C "$OUT" libEGL_static libGLESv2_static
done

# --- 4. Bundle .o files into one libANGLE.a per variant ---
# Exclude dawn (pulls vk* duplicates with MoltenVK), volk (Vulkan loader),
# and googletest. Apple's libtool can't read thin archives, so feed loose
# .o files directly via -filelist.
for variant in xrosDevice xrosSim; do
    if [[ "$variant" == xrosDevice ]]; then NAME=libANGLE.a; else NAME=libANGLE-sim.a; fi
    cd "$ANGLE_ROOT/angle/out/$variant"
    OBJLIST=$(mktemp)
    # Include every .o under obj/ except known-non-runtime paths:
    #   - dawn (WebGPU, brings vk* symbols colliding with MoltenVK)
    #   - volk (Vulkan loader, same collision)
    #   - googletest/gmock/gtest/samples/tests (no runtime use)
    #   - buildtools (build-time only)
    find obj -name '*.o' \
        -not -path '*/dawn/*' \
        -not -path '*/volk/*' \
        -not -path '*/googletest/*' \
        -not -path '*/gmock/*' \
        -not -path '*/gtest/*' \
        -not -path '*/samples/*' \
        -not -path '*/tests/*' \
        -not -path '*/buildtools/*' \
        > "$OBJLIST"
    libtool -static -filelist "$OBJLIST" -o "$OUT_DIR/$NAME" 2>&1 \
        | grep -v 'warning same member' || true
    rm -f "$OBJLIST"
    ls -lh "$OUT_DIR/$NAME"
done

# --- 5. Public headers (EGL/GLES/KHR) for the app's header search path ---
mkdir -p "$OUT_DIR/include"
cp -R "$ANGLE_ROOT/angle/include/." "$OUT_DIR/include/"

echo "ANGLE static libs + headers written to $OUT_DIR/"
