#!/usr/bin/env bash
# Downloads SteamCMD (if not already present) and fetches the archived
# pre-25th-anniversary Half-Life build into HalfLifeAssets/.
#
# Valve's 25th Anniversary Update (Nov 2023) broke shader/asset compat with
# Xash3D-FWGS; the mod ecosystem targets the build Valve archived on the
# `steam_legacy` beta branch of app 70. See README.md for background.
#
# This only prepares HalfLifeAssets/ locally — pushing it to the headset is
# a separate step (./scripts/push-assets.sh, macOS + devicectl only).
#
# Usage:
#   ./scripts/fetch-assets.sh YOUR_STEAM_USERNAME
#
# Needs a Steam account that owns Half-Life. steamcmd prompts for the
# password and any Steam Guard code interactively — this script never takes
# either as an argument or stores them.
set -euo pipefail
cd "$(dirname "$0")/.."   # project root

[[ $# -eq 1 ]] || { echo "Usage: $0 STEAM_USERNAME" >&2; exit 1; }
STEAM_USER="$1"

STEAMCMD_DIR="${STEAMCMD_DIR:-$HOME/bin/steamcmd}"
STEAMCMD_BIN="$STEAMCMD_DIR/steamcmd.sh"

case "$(uname -s)" in
    Darwin) ARCHIVE_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz" ;;
    Linux)  ARCHIVE_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" ;;
    *) echo "ERROR: unsupported platform '$(uname -s)' — on Windows use scripts/fetch-assets.ps1" >&2; exit 1 ;;
esac

if [[ ! -x "$STEAMCMD_BIN" ]]; then
    echo "==> SteamCMD not found at $STEAMCMD_BIN — downloading..."
    mkdir -p "$STEAMCMD_DIR"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    curl -sL "$ARCHIVE_URL" -o "$TMP/steamcmd.tar.gz"
    tar xzf "$TMP/steamcmd.tar.gz" -C "$STEAMCMD_DIR"
    chmod +x "$STEAMCMD_BIN"
fi

echo "==> Fetching Half-Life (app 70, steam_legacy beta) into $PWD/HalfLifeAssets ..."
echo "    steamcmd will prompt for your Steam password / Steam Guard code."
"$STEAMCMD_BIN" \
    +force_install_dir "$PWD/HalfLifeAssets" \
    +login "$STEAM_USER" \
    +app_update 70 -beta steam_legacy validate \
    +quit

[[ -f "HalfLifeAssets/valve/liblist.gam" ]] || {
    echo "ERROR: download finished but HalfLifeAssets/valve/liblist.gam is missing — check the steamcmd output above." >&2
    exit 1
}

echo ""
echo "Done. Next: install the app once, then run ./scripts/push-assets.sh to copy assets to the headset."
