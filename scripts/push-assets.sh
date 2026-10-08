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
#   ./scripts/push-assets.sh --wifi <host:port>
#                                       # over Wi-Fi, no cable or devicectl:
#                                       # open Manage over Wi-Fi in the app,
#                                       # pass the address it shows, type its PIN
#
# Gamedir selection mirrors the old "Bundle HalfLifeAssets" build phase:
# every top-level dir with liblist.gam / gameinfo.txt, plus *_hd / *_addon
# SteamPipe overlays — mods stay loadable without shipping the macOS
# binaries Steam dropped at the top level.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${LV_ASSETS_DIR:-$PROJECT_ROOT/HalfLifeAssets}"

REMOVE_EXISTING=false
WIFI_HOST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete) REMOVE_EXISTING=true; shift ;;
        --wifi)
            [[ $# -ge 2 ]] || { echo "ERROR: --wifi needs <host:port> (shown in Manage over Wi-Fi)" >&2; exit 1; }
            WIFI_HOST="$2"; shift 2 ;;
        -h|--help) sed -n '4,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -d "$SRC/valve" ]] || {
    echo "ERROR: $SRC/valve not found — see README.md (steam_legacy fetch)" >&2
    exit 1
}

# Collect the gamedirs to push.
GAMEDIRS=()
shopt -s nullglob
for d in "$SRC"/*/; do
    name=$(basename "$d")
    case $name in *_hd|*_addon) overlay=1;; *) overlay=0;; esac
    if [[ -f "$d/liblist.gam" || -f "$d/gameinfo.txt" || "$overlay" = 1 ]]; then
        GAMEDIRS+=("${d%/}")
        echo "Will push: $name/"
    fi
done
[[ ${#GAMEDIRS[@]} -gt 0 ]] || { echo "ERROR: no gamedirs found under $SRC" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --wifi: the same API the browser page uses. Only files whose size and
# mtime (or, failing that, SHA-256) differ from the headset's manifest are
# sent; they wait in a staging area until the final commit, so an
# interrupted run resumes where it stopped when run again.
# ---------------------------------------------------------------------------

urlencode() {
    local s="$1" out="" c v i
    local LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) v=$(printf '%d' "'$c"); (( v < 0 )) && v=$(( v + 256 )); out+=$(printf '%%%02X' "$v") ;;
        esac
    done
    printf '%s' "$out"
}

json_field() {   # json_field <name> <json>: a top-level string value
    printf '%s' "$2" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"
}

wifi_push() {
    local base="http://$WIFI_HOST" pin resp token auth code
    curl -fsS -o /dev/null --max-time 5 "$base/" 2>/dev/null || {
        echo "ERROR: can't reach $base — is Manage over Wi-Fi open in LambdaVision, on the same network?" >&2
        exit 1
    }
    pin="${LV_PIN:-}"
    if [[ -z "$pin" ]]; then
        printf 'PIN shown in LambdaVision: ' >&2
        read -r pin </dev/tty
    fi
    resp=$(curl -sS -X POST -H 'Content-Type: application/json' -d "{\"pin\":\"${pin//[^0-9]/}\"}" "$base/api/pair")
    token=$(json_field token "$resp")
    [[ -n "$token" ]] || { echo "ERROR: $(json_field error "$resp")" >&2; exit 1; }
    auth="Authorization: Bearer $token"

    local total_sent=0 d name todo n count kind path mtime hashes sum
    for d in "${GAMEDIRS[@]}"; do
        name=$(basename "$d")
        echo "==> $name: comparing with the headset..."
        # Join the headset's manifest (installed + staged) with the local
        # tree. Output: SEND <size> <mtime> <path>, or CHECK <hashes> <path>
        # for same-size files whose mtime differs (hash decides).
        todo=$(awk -F'\t' '
            FILENAME == ARGV[1] {   # not FNR == NR: the manifest may be empty
                p = $5; for (i = 6; i <= NF; i++) p = p "\t" $i
                k = tolower(p)
                sizes[k] = sizes[k] " " $2; mtimes[k] = mtimes[k] " " $3; shas[k] = shas[k] " " $4
                next
            }
            {
                p = $3; for (i = 4; i <= NF; i++) p = p "\t" $i
                sub(/^\.\//, "", p)
                n = split(p, parts, "/"); junk = 0
                for (i = 1; i <= n; i++) if (parts[i] == ".DS_Store" || parts[i] == "__MACOSX" || substr(parts[i], 1, 2) == "._") junk = 1
                if (junk) next
                k = tolower(p)
                if (!(k in sizes)) { print "SEND\t" $1 "\t" $2 "\t" p; next }
                ns = split(sizes[k], s, " "); split(mtimes[k], m, " "); split(shas[k], h, " ")
                same = 0; hs = ""
                for (i = 1; i <= ns; i++) if (s[i] == $1) {
                    dt = m[i] - $2; if (dt < 0) dt = -dt
                    if (dt < 2) same = 1; else hs = hs (hs == "" ? "" : ",") h[i]
                }
                if (same) next
                if (hs != "") print "CHECK\t" hs "\t" $2 "\t" p
                else print "SEND\t" $1 "\t" $2 "\t" p
            }' \
            <(curl -fsS -H "$auth" "$base/api/manifest?gamedir=$(urlencode "$name")&format=tsv") \
            <(cd "$d" && find . -type f -exec stat -f '%z%t%m%t%N' {} +))

        count=$(printf '%s' "$todo" | grep -c . || true)
        if [[ "$count" -eq 0 ]]; then echo "    up to date"; continue; fi
        n=0
        while IFS=$'\t' read -r kind hashes mtime path; do
            [[ -n "$kind" ]] || continue
            n=$(( n + 1 ))
            if [[ "$kind" == CHECK ]]; then
                sum=$(shasum -a 256 "$d/$path" | cut -d' ' -f1)
                [[ ",$hashes," == *",$sum,"* ]] && continue
            fi
            printf '    [%d/%d] %s\n' "$n" "$count" "$path"
            send_file "$base" "$auth" "$d/$path" "$name/$path" "$mtime" || true
            total_sent=$(( total_sent + 1 ))
        done <<< "$todo"
    done

    resp=$(curl -fsS -H "$auth" "$base/api/status")
    if [[ "$total_sent" -eq 0 && "$resp" == *'"staged":{"bytes":0,"files":0'* ]]; then
        echo ""
        echo "Done. Everything was already on the headset."
        return
    fi
    echo "==> Installing on the headset..."
    curl -sS -N -X POST -H "$auth" "$base/api/commit?stream=text"
    echo ""
    echo "Done."
}

# send_file <base> <auth> <local file> <upload path> <mtime>: retries while
# the connection drops; gives up on anything the server refused.
send_file() {
    local attempt=0 code
    while :; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT --upload-file "$3" -H "$2" \
            "$1/api/upload?path=$(urlencode "$4")&mtime=$5" 2>/dev/null || true)
        case "$code" in
            2??) return 0 ;;
            000)
                attempt=$(( attempt + 1 ))
                if (( attempt >= 30 )); then
                    echo "ERROR: lost the connection. Run again to resume; sent files are kept." >&2
                    exit 1
                fi
                sleep 2 ;;
            401)
                echo "ERROR: the session ended (Manage over Wi-Fi was closed). Reopen it and run again to resume." >&2
                exit 1 ;;
            409) echo "      skipped: in use by the running game (reopen LambdaVision first)" >&2; return 1 ;;
            507) echo "ERROR: the headset is out of space." >&2; exit 1 ;;
            *) echo "      failed (HTTP $code)" >&2; return 1 ;;
        esac
    done
}

if [[ -n "$WIFI_HOST" ]]; then
    [[ "$REMOVE_EXISTING" == false ]] || { echo "ERROR: --delete isn't supported with --wifi; delete games from the page instead" >&2; exit 1; }
    wifi_push
    exit 0
fi

CONF_FILE="$SCRIPT_DIR/build-signing.conf"
[[ -f "$CONF_FILE" ]] || { echo "ERROR: $CONF_FILE not found" >&2; exit 1; }
# shellcheck source=build-signing.conf
source "$CONF_FILE"
: "${DEVICE_NAME:?DEVICE_NAME not set in build-signing.conf}"
: "${BUILD_BUNDLE_ID:?BUILD_BUNDLE_ID not set in build-signing.conf}"

# Resolve by pattern, never by column position: the Hostname column is empty
# while a device sits in the `connected` state, which shifts every later
# field left and makes `awk '{print $3}'` return the literal string
# "connected" instead of the identifier (see ~/bin/build-and-sign for the
# same fix). Simulator rows are skipped since devicectl only installs to
# physical devices.
DEVICE_LIST=$(xcrun devicectl list devices 2>/dev/null || true)
_device_uuid() {
    grep -v "simulated" \
        | grep -oiE '[0-9A-F]{8}-[0-9A-F]{16}|[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' \
        | head -1
}
DEVICE_ID=$(printf '%s\n' "$DEVICE_LIST" | grep -E "^${DEVICE_NAME}[[:space:]]" | _device_uuid || true)
[[ -n "$DEVICE_ID" ]] || {
    echo "ERROR: Device '$DEVICE_NAME' not found. Is it connected and paired?" >&2
    exit 1
}

SOURCES=()
for d in "${GAMEDIRS[@]}"; do SOURCES+=(--source "$d"); done

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

# Tell the running app that the upload is complete. It watches Documents/GameData
# and rescans as soon as this marker lands; the Wi-Fi path notifies it at commit.
touch "$SCRIPT_DIR/assets-upload-marker"
xcrun devicectl device copy to \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUILD_BUNDLE_ID" \
    --destination "Documents/GameData/.lambda-assets-upload" \
    --source "$SCRIPT_DIR/assets-upload-marker"

echo ""
echo "Done. The engine will use Documents/GameData on next launch."
