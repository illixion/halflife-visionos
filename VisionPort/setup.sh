#!/usr/bin/env bash
# Recreates the gitignored vendored dependencies:
#   - xash3d-fwgs (FWGS upstream + visionOS patch)
#   - hlsdk-portable (Half-Life game logic source)
#   - MoltenVK.xcframework (Vulkan-on-Metal, with prebuilt visionOS slice)
#
# Both upstream repos are pinned to a known-good commit. The visionOS patches
# are unified diffs with fixed line numbers against specific source, so they
# silently stop applying (or worse, apply cleanly against different
# surrounding code) the moment upstream moves — `git clone` of a floating
# default branch is not reproducible across time. Bump these only alongside
# re-verifying (and if needed regenerating) both .patch files.
set -euo pipefail
cd "$(dirname "$0")"

XASH3D_FWGS_COMMIT=33b3cdb0f53ad1faafd2d3a0e6b4cb3d594e8cfb
HLSDK_PORTABLE_COMMIT=a4e584d9b4f37e705fa9ee76af85a79daad9831c

# 1. xash3d-fwgs + visionOS patch
if [[ ! -d xash3d-fwgs ]]; then
    git init xash3d-fwgs
    (cd xash3d-fwgs \
        && git remote add origin https://github.com/FWGS/xash3d-fwgs.git \
        && git fetch --depth 1 origin "$XASH3D_FWGS_COMMIT" \
        && git checkout FETCH_HEAD \
        && git submodule update --init --recursive --depth 1 \
        && git apply ../xash3d-visionos.patch)
fi

# 2. Half-Life SDK (+ visionOS patch: VR aim ray, xcompile tweaks)
if [[ ! -d hlsdk-portable ]]; then
    git init hlsdk-portable
    (cd hlsdk-portable \
        && git remote add origin https://github.com/FWGS/hlsdk-portable.git \
        && git fetch --depth 1 origin "$HLSDK_PORTABLE_COMMIT" \
        && git checkout FETCH_HEAD \
        && git submodule update --init --recursive --depth 1 \
        && git apply ../hlsdk-visionos.patch)
fi

# 3. MoltenVK xcframework into the Xcode project's Vendor/
MVK_DEST="../LambdaVision/Vendor/MoltenVK.xcframework"
if [[ ! -d "$MVK_DEST" ]]; then
    TMP=$(mktemp -d)
    curl -sL "https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-all.tar" -o "$TMP/mvk.tar"
    tar xf "$TMP/mvk.tar" -C "$TMP"
    cp -R "$TMP/MoltenVK/MoltenVK/static/MoltenVK.xcframework" "$MVK_DEST"
    rm -rf "$TMP"
fi

echo "Setup complete."
echo "  xash3d-fwgs:  $(pwd)/xash3d-fwgs"
echo "  hlsdk-portable: $(pwd)/hlsdk-portable"
echo "  MoltenVK:     $(pwd)/$MVK_DEST"
