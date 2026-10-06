#!/usr/bin/env bash
# Content keys for the prebuilt engine archives published as GitHub Releases.
# The single source of truth shared by the prebuilt-* workflows (which tag the
# release with the key) and scripts/fetch-prebuilts.sh (which downloads the
# release matching the current tree), so the two can never disagree.
#
#   scripts/prebuilt-keys.sh          prints  angle=<tag>  and  xash=<tag>
#   scripts/prebuilt-keys.sh angle    prints the ANGLE release tag only
#   scripts/prebuilt-keys.sh xash     prints the libxash release tag only
#
# A key changes whenever anything that shapes the archive changes:
#   angle  pinned ANGLE revision + angle-visionos.patch + build_angle_visionos.sh
#          + the workflow that builds it (it picks the Xcode)
#   xash   pinned xash3d-fwgs + hlsdk-portable revisions (from setup.sh) + every
#          git-tracked file under VisionPort/ except the ANGLE, macOS and
#          simulator-only scripts (patches, build scripts, stubs, VR hook
#          sources, build_game.sh) + the workflow (Xcode, mod-port list)
# Hashes are over git-tracked paths with working-tree contents, so a local
# edit yields a key no release has, and the fetch falls through to "build it
# yourself" instead of downloading archives that don't match the sources.
# Needs git, shasum and sed; runs on macOS and Linux (the key job is Ubuntu).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "prebuilt-keys: not a git checkout; keys need git-tracked sources" >&2
    exit 1
fi

# Short sha256 over a list of paths (one per line on stdin): each path and its
# content hash, in byte order, so renames and edits both change the result.
hash_files() {
    local path
    LC_ALL=C sort | while IFS= read -r path; do
        [[ -f "$path" ]] || continue
        printf '%s %s\n' "$path" "$(shasum -a 256 < "$path" | cut -c1-64)"
    done | shasum -a 256 | cut -c1-12
}

# Value of a NAME=<40-hex> constant in a script.
pinned_commit() {
    sed -n "s/^$2=\([0-9a-f]\{40\}\)\$/\1/p" "$1" | head -n 1
}

angle_key() {
    local rev
    rev=$(pinned_commit VisionPort/build_angle_visionos.sh ANGLE_COMMIT)
    [[ -n "$rev" ]] || { echo "prebuilt-keys: no ANGLE_COMMIT pin" >&2; exit 1; }
    printf 'angle-%s-%s\n' "$(printf '%s' "$rev" | cut -c1-10)" "$(
        printf '%s\n' VisionPort/angle-visionos.patch \
            VisionPort/build_angle_visionos.sh \
            .github/workflows/prebuilt-angle.yml | hash_files)"
}

xash_key() {
    local xash hlsdk
    xash=$(pinned_commit VisionPort/setup.sh XASH3D_FWGS_COMMIT)
    hlsdk=$(pinned_commit VisionPort/setup.sh HLSDK_PORTABLE_COMMIT)
    [[ -n "$xash" && -n "$hlsdk" ]] || { echo "prebuilt-keys: no xash/hlsdk pin in setup.sh" >&2; exit 1; }
    printf 'xash-%s-%s-%s\n' "$(printf '%s' "$xash" | cut -c1-8)" \
        "$(printf '%s' "$hlsdk" | cut -c1-8)" "$(
        { git ls-files -- VisionPort \
            | grep -vxE 'VisionPort/(angle-visionos\.patch|build_angle_visionos\.sh|build_xash_macos\.sh|build_xash_xrsim\.sh)'
          echo .github/workflows/prebuilt-xash.yml
        } | hash_files)"
}

case "${1:-all}" in
    angle) angle_key ;;
    xash) xash_key ;;
    all)
        angle=$(angle_key)
        xash=$(xash_key)
        printf 'angle=%s\nxash=%s\n' "$angle" "$xash" ;;
    *) echo "usage: $0 [angle|xash]" >&2; exit 2 ;;
esac
