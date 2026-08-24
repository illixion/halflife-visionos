#!/bin/bash
set -euo pipefail

# Push Half-Life assets to the app's Documents/GameData on the device.
#
# This replaces bundling the ~450MB asset tree into the app: assets go to
# the app's data container ONCE (and incrementally after — devicectl skips
# unmodified files), so code-only rebuilds install in seconds. The engine
# prefers Documents/GameData as -rodir when valve/liblist.gam is present
# there (see Renderer.ensureEngineInitialized), falling back to the bundled
# copy from `build-and-sign.sh --set BUNDLE_HL_ASSETS=1`.
#
# The app must already be installed (the data container has to exist).
#
# Usage:
#   ./scripts/push-assets.sh            # incremental push (skips unchanged)
#   ./scripts/push-assets.sh --delete   # also remove device files not in source
#
# Gamedir selection mirrors the old "Bundle HalfLifeAssets" build phase:
# every top-level dir with liblist.gam / gameinfo.txt, plus *_hd / *_addon
# SteamPipe overlays — mods stay loadable without shipping the macOS
# binaries Steam dropped at the top level.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$PROJECT_ROOT/HalfLifeAssets"

CONF_FILE="$SCRIPT_DIR/build-signing.conf"
[[ -f "$CONF_FILE" ]] || { echo "ERROR: $CONF_FILE not found" >&2; exit 1; }
# shellcheck source=build-signing.conf
source "$CONF_FILE"
: "${DEVICE_NAME:?DEVICE_NAME not set in build-signing.conf}"
: "${BUILD_BUNDLE_ID:?BUILD_BUNDLE_ID not set in build-signing.conf}"

REMOVE_EXISTING=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete) REMOVE_EXISTING=true; shift ;;
        -h|--help) sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -d "$SRC/valve" ]] || {
    echo "ERROR: $SRC/valve not found — see README.md (steam_legacy fetch)" >&2
    exit 1
}

# Resolve by pattern, never by column position: the Hostname column is empty
# while a device sits in the `connected` state, which shifts every later
# field left and makes `awk '{print $3}'` return the literal string
# "connected" instead of the identifier (see ~/bin/build-and-sign for the
# same fix). Simulator rows are skipped since devicectl only installs to
# physical devices.
DEVICE_LIST=$(xcrun devicectl list devices 2>/dev/null || true)
_device_uuid() {
    grep -v "simulated" \
        | grep -oiE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' \
        | head -1
}
DEVICE_ID=$(printf '%s\n' "$DEVICE_LIST" | grep -E "^${DEVICE_NAME}[[:space:]]" | _device_uuid || true)
[[ -n "$DEVICE_ID" ]] || {
    echo "ERROR: Device '$DEVICE_NAME' not found. Is it connected and paired?" >&2
    exit 1
}

# Collect the gamedirs to push.
SOURCES=()
shopt -s nullglob
for d in "$SRC"/*/; do
    name=$(basename "$d")
    case $name in *_hd|*_addon) overlay=1;; *) overlay=0;; esac
    if [[ -f "$d/liblist.gam" || -f "$d/gameinfo.txt" || "$overlay" = 1 ]]; then
        SOURCES+=(--source "${d%/}")
        echo "Will push: $name/"
    fi
done
[[ ${#SOURCES[@]} -gt 0 ]] || { echo "ERROR: no gamedirs found under $SRC" >&2; exit 1; }

echo "==> Pushing to $DEVICE_NAME ($BUILD_BUNDLE_ID) Documents/GameData ..."
xcrun devicectl device copy to \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUILD_BUNDLE_ID" \
    --destination "Documents/GameData" \
    --remove-existing-content "$REMOVE_EXISTING" \
    "${SOURCES[@]}"

# SteamPipe HD overlay (valve_hd) mounts via fs_mount_hd. vfs.cfg is exec'd
# by FS_LoadGameInfo BEFORE the gamedir mounts, so placing it in the rodir
# gamedir enables HD content with no engine changes. Skip if the assets
# tree ships its own.
#
# devicectl semantics gotcha: with a SINGLE --source, --destination is the
# literal target path, not a parent directory (multi-source copies treat it
# as a directory). Naming just ".../valve" here once replaced the whole
# valve/ directory on the device with a 16-byte file called "valve" — the
# destination must carry the full filename.
if [[ -d "$SRC/valve_hd" && ! -f "$SRC/valve/vfs.cfg" ]]; then
    TMP_CFG_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_CFG_DIR"' EXIT
    printf 'fs_mount_hd "1"\n' > "$TMP_CFG_DIR/vfs.cfg"
    xcrun devicectl device copy to \
        --device "$DEVICE_ID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUILD_BUNDLE_ID" \
        --destination "Documents/GameData/valve/vfs.cfg" \
        --source "$TMP_CFG_DIR/vfs.cfg"
    echo "Pushed valve/vfs.cfg (fs_mount_hd 1)"
fi

echo ""
echo "Done. The engine will use Documents/GameData on next launch."
