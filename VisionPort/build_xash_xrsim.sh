#!/usr/bin/env bash
# Build xash3d-fwgs (dedicated server, ref_null) for arm64 visionOS Simulator.
# Confirmed working on Xcode 26.4 / visionOS 26.4 SDK (May 2026).
set -euo pipefail
cd "$(dirname "$0")/xash3d-fwgs"
git submodule update --init --recursive
rm -rf build
python3 ./waf configure --xros-simulator -d --disable-gl
python3 ./waf build
file build/engine/xash
otool -l build/engine/xash | grep -A 3 LC_BUILD_VERSION
