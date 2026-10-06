#!/usr/bin/env bash
# Downloads SteamCMD (if not already present) and fetches the archived
# pre-25th-anniversary Half-Life build into HalfLifeAssets/, optionally with
# Opposing Force (app 50) and Blue Shift (app 130), and optionally zips each
# game for importing on the headset (AirDrop, Files).
#
# Valve's 25th Anniversary Update (Nov 2023) broke shader/asset compat with
# Xash3D-FWGS; the mod ecosystem targets the build Valve archived on the
# `steam_legacy` beta branch of app 70. See README.md for background.
#
# Usage:
#   ./scripts/fetch-assets.sh YOUR_STEAM_USERNAME            Half-Life
#   ./scripts/fetch-assets.sh YOUR_STEAM_USERNAME 50 130     + Opposing Force, Blue Shift
#   ./scripts/fetch-assets.sh --zip YOUR_STEAM_USERNAME 50   ... then zip each game
#   ./scripts/fetch-assets.sh --zip                          only zip what's in HalfLifeAssets/
#
# Opposing Force and Blue Shift have no steam_legacy branch (their public
# build is from 2020, before the anniversary update), but both pull Half-Life's
# depots from app 70's current, post-anniversary build. So they install into
# a staging folder (build/steam-mods/) and only their own gamedirs (gearbox*,
# bshift*) are copied into HalfLifeAssets/, never valve*.
#
# --zip writes build/asset-zips/<gamedir>.zip per game, its _hd/_addon
# overlays included: send one to the headset and open it in LambdaVision.
#
# Needs a Steam account that owns the games. steamcmd prompts for the
# password and any Steam Guard code interactively — this script never takes
# either as an argument or stores them.
set -euo pipefail
cd "$(dirname "$0")/.."   # project root

usage() { echo "Usage: $0 [--zip] [STEAM_USERNAME [50] [130]]" >&2; exit 1; }

ZIP=0
if [[ "${1:-}" == "--zip" ]]; then ZIP=1; shift; fi
STEAM_USER="${1:-}"
[[ -n "$STEAM_USER" || "$ZIP" == 1 ]] || usage
if [[ $# -gt 0 ]]; then shift; fi
EXTRA_APPS=()
for app in "$@"; do
    case "$app" in
        50|130) EXTRA_APPS+=("$app") ;;
        --zip) ZIP=1 ;;
        *) echo "ERROR: unsupported app '$app' — extra apps are 50 (Opposing Force) and 130 (Blue Shift)" >&2; usage ;;
    esac
done

# Each game's own gamedirs, the only ones taken from its staging install.
app_gamedir() {
    case "$1" in
        50) echo gearbox ;;
        130) echo bshift ;;
    esac
}

# Depot 96 (the official Gearbox "Half-Life High Definition" pack) ships as
# HalfLifeAssets/valve_hd/ alongside valve/ (app_update 70 pulls it; the
# expansions' HD packs come the same way as gearbox_hd/ and bshift_hd/). Its
# depot ships models/Hgrunt03.mdl with a capital H while the engine requests
# the lowercase name; harmless on Windows/steamcmd's usual case-insensitive
# volumes, a missing-model crash on a case-sensitive one (visionOS APFS,
# Linux ext4). Normalize it here so nobody has to hit that crash first.
fix_hd_case() {
    local hd
    for hd in HalfLifeAssets/*_hd/models/Hgrunt03.mdl; do
        [[ -f "$hd" ]] || continue
        mv "$hd" "$(dirname "$hd")/hgrunt03.mdl"
        echo "==> Renamed ${hd#HalfLifeAssets/} -> hgrunt03.mdl (case-sensitive filesystem fix)"
    done
}

if [[ -n "$STEAM_USER" ]]; then
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

    for app in ${EXTRA_APPS[@]+"${EXTRA_APPS[@]}"}; do
        gamedir="$(app_gamedir "$app")"
        stage="$PWD/build/steam-mods/app$app"
        mkdir -p "$stage"
        echo "==> Fetching app $app (public branch) into the staging folder $stage ..."
        "$STEAMCMD_BIN" \
            +force_install_dir "$stage" \
            +login "$STEAM_USER" \
            +app_update "$app" validate \
            +quit
        [[ -f "$stage/$gamedir/liblist.gam" ]] || {
            echo "ERROR: app $app finished but $stage/$gamedir/liblist.gam is missing — check the steamcmd output above." >&2
            exit 1
        }
        for dir in "$stage/$gamedir" "$stage/${gamedir}"_*; do
            [[ -d "$dir" ]] || continue
            echo "    copying $(basename "$dir")/ into HalfLifeAssets/"
            cp -R "$dir" HalfLifeAssets/
        done
    done

    fix_hd_case
fi

if [[ "$ZIP" == 1 ]]; then
    command -v zip >/dev/null || { echo "ERROR: --zip needs the zip command" >&2; exit 1; }
    out="$PWD/build/asset-zips"
    mkdir -p "$out"
    # A game is a folder with liblist.gam or gameinfo.txt; its overlays are
    # the <gamedir>_* folders without one (valve_hd, gearbox_addon, ...).
    zipped=0
    for base in HalfLifeAssets/*/; do
        base="$(basename "$base")"
        [[ -f "HalfLifeAssets/$base/liblist.gam" || -f "HalfLifeAssets/$base/gameinfo.txt" ]] || continue
        dirs=("$base")
        for overlay in HalfLifeAssets/"$base"_*/; do
            overlay="$(basename "$overlay")"
            [[ -d "HalfLifeAssets/$overlay" ]] || continue
            [[ -f "HalfLifeAssets/$overlay/liblist.gam" || -f "HalfLifeAssets/$overlay/gameinfo.txt" ]] && continue
            dirs+=("$overlay")
        done
        echo "==> Zipping ${dirs[*]} -> build/asset-zips/$base.zip"
        # -FS brings an existing zip from an earlier run in line with the folders.
        (cd HalfLifeAssets && zip -q -r -X -FS "$out/$base.zip" "${dirs[@]}" -x '*/.DS_Store')
        zipped=$((zipped + 1))
    done
    [[ "$zipped" -gt 0 ]] || { echo "ERROR: no games in HalfLifeAssets/ to zip" >&2; exit 1; }
    echo ""
    echo "Done. Send a zip from build/asset-zips/ to the headset (AirDrop, or Files) and open it in LambdaVision."
else
    echo ""
    echo "Done. Next: install the app once, then run ./scripts/push-assets.sh to copy assets to the headset,"
    echo "or rerun with --zip to import them on the headset instead."
fi
