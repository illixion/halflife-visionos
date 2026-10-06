#!/usr/bin/env bash
# Checks the debug server's frame-capture image path on the Mac against the
# app's own source (FrameImage.swift, compiled verbatim): pixel-format decode,
# the foveation unwarp, resize, side-by-side and PNG encode.
#
#   ./build.sh           # run the checks
#   ./build.sh --serve   # also serve a synthetic stereo frame at
#                        # http://127.0.0.1:8651/screenshot, for testing
#                        # scripts/avp-screenshot.sh without a headset
#
# Exits non-zero on the first failed check.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app="$repo/LambdaVision/LambdaVision"
out="$repo/build/capture-probe"
mkdir -p "$out"

swiftc -O "$app/FrameImage.swift" "$here/main.swift" -o "$out/probe"
"$out/probe" "$@"
