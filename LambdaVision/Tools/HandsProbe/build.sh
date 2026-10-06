#!/usr/bin/env bash
# Checks the hand-tracking gesture logic on the Mac against the app's own
# sources: the weapon wheel's layout and gesture (WeaponWheel.swift), the
# long-jump button timing (JumpSequencer.swift) and the HUD icons decoded
# from the real game sprites (HUDIcon.swift).
#
#   ./build.sh             run every check
#   ./build.sh --ascii     also draw each Half-Life icon as text
#   ./build.sh --assets=/path/to/HalfLifeAssets
#
# The sprite checks need the game files (HalfLifeAssets beside the app, by
# default); they are skipped when those are missing. Exits non-zero on the
# first failed check.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app="$repo/LambdaVision/LambdaVision"
out="$repo/build/hands-probe"
mkdir -p "$out"

swiftc -O \
    "$app/WeaponWheel.swift" "$app/JumpSequencer.swift" "$app/HUDIcon.swift" \
    "$here/main.swift" -o "$out/probe"

assets="$repo/HalfLifeAssets"
for a in "$@"; do
    case "$a" in --assets=*) assets="${a#--assets=}" ;; esac
done
"$out/probe" "$assets" "$@"
