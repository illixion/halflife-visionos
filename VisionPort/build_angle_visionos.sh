#!/usr/bin/env bash
# Build Google ANGLE (libEGL + libGLESv2, Metal backend only) for visionOS
# device + simulator, then bundle into one libANGLE.a per platform and drop
# it at LambdaVision/Vendor/angle/ for the Xcode project to link.
#
# Requires a sibling depot_tools checkout (managed under Vendor/angle-build).
# ~12 GiB of free disk for the gclient sync; subsequent rebuilds are quick.
set -euo pipefail

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
    git clone https://chromium.googlesource.com/angle/angle "$ANGLE_ROOT/angle"
    cd "$ANGLE_ROOT/angle"
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

echo "ANGLE static libs written to $OUT_DIR/"
