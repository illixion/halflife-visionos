#!/usr/bin/env bash
# Build xash3d-fwgs (dedicated, no GL) for arm64 visionOS device, then
# bundle every .o file produced into a single libxash.a that the Xcode
# project can link directly. visionOS forbids loading external dylibs, so
# everything (engine + filesystem + 3rdparty) ships as one static archive.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/xash3d-fwgs"

git submodule update --init --recursive
rm -rf build
python3 ./waf configure --xros -d --disable-gl
# Compile-only; the final `xash` exec link will fail because filesystem
# is normally a dylib loaded at runtime. We bundle every .o into libxash.a
# below — the link failure is expected and ignored.
python3 ./waf build || true

OUT="$HERE/../LambdaVision/Vendor/libxash"
mkdir -p "$OUT"
mapfile -t OBJS < <(find build -type f -name '*.o' | sort)
echo "Bundling ${#OBJS[@]} object files into libxash.a"
xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/libxash.a" "${OBJS[@]}"
file "$OUT/libxash.a"
echo "Wrote $OUT/libxash.a ($(stat -f%z "$OUT/libxash.a") bytes)"
