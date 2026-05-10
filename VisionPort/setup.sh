#!/usr/bin/env bash
# Recreates the gitignored vendored dependencies:
#   - xash3d-fwgs (FWGS upstream + visionOS patch)
#   - hlsdk-portable (Half-Life game logic source)
#   - MoltenVK.xcframework (Vulkan-on-Metal, with prebuilt visionOS slice)
set -euo pipefail
cd "$(dirname "$0")"

# 1. xash3d-fwgs + visionOS patch
if [[ ! -d xash3d-fwgs ]]; then
    git clone --depth 1 --recursive https://github.com/FWGS/xash3d-fwgs.git
    (cd xash3d-fwgs && git apply ../xash3d-visionos.patch)
fi

# 2. Half-Life SDK
if [[ ! -d hlsdk-portable ]]; then
    git clone --depth 1 --recursive https://github.com/FWGS/hlsdk-portable.git
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
