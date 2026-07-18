#!/bin/bash
set -euo pipefail

# Lambda_VisionPro pre-build hook, run by build-and-sign.sh via
# PRE_BUILD_HOOK (build-signing.conf). Repo-specific pre-build logic lives
# HERE — scripts/build-and-sign.sh is a shared script kept byte-identical
# across repos and must not carry it.
#
# Repo-specific build knobs (passed as `--set KEY=VALUE`):
#   --set BUNDLE_HL_ASSETS=1   bake HL assets into the app bundle for a
#                              self-contained build; by default assets ship
#                              out of band via scripts/push-assets.sh.

cd "$(dirname "$0")/.."

# Vendored engine/game sources + MoltenVK (idempotent: clones and patches
# only on a fresh checkout, instant no-op otherwise).
./VisionPort/setup.sh

# The engine is prebuilt into libxash.a (gitignored) — Xcode only links it,
# so a missing archive would otherwise surface as a confusing link error
# (or, in Debug, a silently tiny binary).
LIBXASH="LambdaVision/Vendor/libxash/libxash.a"
if [[ ! -f "$LIBXASH" ]]; then
    echo "ERROR: $LIBXASH missing — build the engine first:" >&2
    echo "  ./VisionPort/build_xash_libxash.sh" >&2
    exit 1
fi
