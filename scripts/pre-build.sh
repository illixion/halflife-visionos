#!/bin/bash
set -euo pipefail

# Lambda_VisionPro pre-build hook: fetches vendored deps and checks the
# prebuilt engine archive before a real build starts. Runs two ways —
# automatically as an Xcode Run Script build phase (LambdaVision target,
# first phase, before Compile Sources), and via PRE_BUILD_HOOK
# (build-signing.conf) for anyone driving builds through their own
# external build-and-sign-style script instead of Xcode directly. Both
# paths are safe to run redundantly since every step here is idempotent.
#
# Repo-specific build knobs (passed as `--set KEY=VALUE`):
#   --set BUNDLE_HL_ASSETS=1   bake HL assets into the app bundle for a
#                              self-contained build; by default assets ship
#                              out of band via scripts/push-assets.sh.

cd "$(dirname "$0")/.."

# Vendored engine/game sources + MoltenVK (idempotent: clones and patches
# only on a fresh checkout, instant no-op otherwise).
./VisionPort/setup.sh

# Prebuilt ANGLE / libxash / game-port archives from the GitHub Release that
# matches these sources, for whichever is missing locally. Never overwrites a
# local build and never fails: offline or no release falls through to the
# checks below.
./scripts/fetch-prebuilts.sh || true

# The engine is prebuilt into libxash.a (gitignored) — Xcode only links it,
# so a missing archive would otherwise surface as a confusing link error
# (or, in Debug, a silently tiny binary).
LIBXASH="LambdaVision/Vendor/libxash/libxash.a"
if [[ ! -f "$LIBXASH" ]]; then
    echo "ERROR: $LIBXASH missing — build the engine first:" >&2
    echo "  ./VisionPort/build_xash_libxash.sh" >&2
    exit 1
fi

# Same for ANGLE: without it the link fails on missing EGL/GLES symbols.
LIBANGLE="LambdaVision/Vendor/angle/libANGLE.a"
if [[ ! -f "$LIBANGLE" ]]; then
    echo "ERROR: $LIBANGLE missing — build ANGLE first (~12 GiB, slow once):" >&2
    echo "  ./VisionPort/build_angle_visionos.sh" >&2
    exit 1
fi
