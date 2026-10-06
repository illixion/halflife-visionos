#!/usr/bin/env bash
# Grab what the player sees in a running LambdaVision over its debug server
# (DebugEndpoints.swift, GET /screenshot) and save it as a PNG.
#
#   scripts/avp-screenshot.sh [--eye left|right|both] [--source composited|engine]
#                             [--width N] [--physical] [--host host[:port]]
#                             [--out file.png] [--open]
#
#   --eye       both (default, side by side, left first), left or right
#   --source    composited (default): the drawable with the gun, body and
#               HEV holograms; engine: the engine's colour map alone
#   --width     cap on the PNG's width, both eyes together (default 1600;
#               0 = native logical resolution, several thousand pixels)
#   --physical  keep the drawable's foveated (centre-magnified) layout
#   --host      the device (host or host:port); default: $LAMBDA_HOST, else
#               the running `build-and-sign --mcp` session, else Bonjour
#   --out       where to save; default build/screenshots/<timestamp>-<eye>.png
#   --open      open the result in Preview
#
# Prints the saved path on success (so an agent can Read the image), or the
# server's error and hint on stderr with a non-zero exit. The app must be a
# development build (signed by build-and-sign, or Settings > Advanced >
# Debug server: On) with the immersive space open, on this network or tailnet.
set -eu

cd "$(dirname "$0")/.."

eye=both
source_name=composited
width=1600
unwarp=true
host=""
out=""
open_after=0

usage() { /usr/bin/sed -n '2,24p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; }
need() { [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
    case "$1" in
        --eye) need "$@"; eye="$2"; shift 2 ;;
        --eye=*) eye="${1#--eye=}"; shift ;;
        --source) need "$@"; source_name="$2"; shift 2 ;;
        --source=*) source_name="${1#--source=}"; shift ;;
        --width) need "$@"; width="$2"; shift 2 ;;
        --width=*) width="${1#--width=}"; shift ;;
        --physical) unwarp=false; shift ;;
        --host) need "$@"; host="$2"; shift 2 ;;
        --host=*) host="${1#--host=}"; shift ;;
        --out) need "$@"; out="$2"; shift 2 ;;
        --out=*) out="${1#--out=}"; shift ;;
        --open) open_after=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
done

case "$eye" in left|right|both) ;; *) echo "error: --eye must be left, right or both" >&2; exit 2 ;; esac
case "$source_name" in composited|engine) ;; *) echo "error: --source must be composited or engine" >&2; exit 2 ;; esac
case "$width" in ''|*[!0-9]*) echo "error: --width must be a whole number" >&2; exit 2 ;; esac

# shellcheck source-path=SCRIPTDIR source=debug-server-lib.sh
. scripts/debug-server-lib.sh

if ! lv_resolve_server "$host"; then
    echo "error: no LambdaVision debug server found: no running build-and-sign --mcp session and nothing on Bonjour" >&2
    echo "hint: launch with build-and-sign --mcp, or pass --host <device>[:port] (port from the app's 'listening on port' log line)" >&2
    exit 1
fi

mkdir -p build/screenshots
[ -n "$out" ] || out="build/screenshots/$(date +%Y%m%d-%H%M%S)-$eye.png"
mkdir -p "$(dirname "$out")"
# The response lands here first; only a PNG is moved to $out; curl's own
# complaint (refused vs unreachable) goes to the second file.
response=build/screenshots/.last-response
curl_err=build/screenshots/.last-curl-error

fetch() {
    curl_exit=0
    status="$(lv_curl "screenshot?eye=$eye&source=$source_name&width=$width&unwarp=$unwarp" \
        --connect-timeout 5 --max-time 30 -o "$response" -w '%{http_code}' 2>"$curl_err")" || curl_exit=$?
    status="${status:-000}"
}

# curl says only "Couldn't connect" for both a refusal (the device answered
# with a reset: nothing listens) and no route; nc names which. Prints
# "refused", "unreachable" or nothing.
connect_failure() {
    local hostport="${LV_URL#http://}" said
    said="$(/usr/bin/nc -vz -G 3 "${hostport%:*}" "${hostport##*:}" 2>&1 || true)"
    case "$said" in
        *[Rr]efused*) echo refused ;;
        *failed*|*timed\ out*|*[Nn]o\ route*|*[Uu]nreachable*) echo unreachable ;;
    esac
}

fetch
failure=""
[ "$curl_exit" = 7 ] && failure="$(connect_failure)"
# Refused at a recorded port: the app may have rebuilt its server on another
# port (it re-checks its listener every 5 s); ask Bonjour once.
if [ "$failure" = refused ] && [ "$LV_SOURCE" != bonjour ] && [ -z "$host" ]; then
    old_url="$LV_URL"
    LV_URL=""
    lv_discover
    if [ -n "$LV_URL" ] && [ "$LV_URL" != "$old_url" ]; then
        echo "note: $old_url refused; retrying at $LV_URL (Bonjour)" >&2
        fetch
        failure=""
        [ "$curl_exit" = 7 ] && failure="$(connect_failure)"
    else
        LV_URL="$old_url"
    fi
fi

if [ "$status" = 200 ] && [ "$(/usr/bin/head -c 4 "$response" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \n')" = 89504e47 ]; then
    mv "$response" "$out"
    size="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null | /usr/bin/awk '/pixel/ {printf "%s ", $2}')"
    echo "$out"
    echo "(${size% }px, $(/usr/bin/stat -f %z "$out") bytes, $eye/$source_name, from $LV_URL via $LV_SOURCE)" >&2
    [ "$open_after" = 1 ] && open "$out"
    exit 0
fi

case "$status" in
    000)
        why="$(/usr/bin/sed -n 's/^curl: ([0-9]*) //p' "$curl_err" | /usr/bin/head -1)"
        if [ "$failure" = refused ]; then
            echo "error: REFUSED: the device is reachable but nothing listens at $LV_URL (via $LV_SOURCE)" >&2
            echo "hint: the debug server's listener stopped or moved. The app rebuilds it within ~5 s (log: '[DebugServer] listener ... stopped answering' then 'listening on port N'); retry, or check the app is still running and Settings > Advanced > Debug server isn't Off" >&2
        elif [ "$curl_exit" = 6 ]; then
            echo "error: UNREACHABLE: can't resolve the host in $LV_URL (via $LV_SOURCE): $why" >&2
            echo "hint: pass --host <ip>[:port], or check the tailnet / local network" >&2
        elif [ "$curl_exit" = 28 ] || [ "$curl_exit" = 7 ]; then
            echo "error: UNREACHABLE: no connection to $LV_URL (via $LV_SOURCE): ${why:-curl exit $curl_exit}" >&2
            echo "hint: the headset is asleep, off this network/tailnet, or (No route to host while ping works) macOS Local Network privacy is blocking this terminal's curl; try /usr/bin/curl from Terminal.app" >&2
        else
            echo "error: no HTTP answer from $LV_URL (via $LV_SOURCE): ${why:-curl exit $curl_exit}" >&2
            echo "hint: the connection opened but broke; retry, and check build/device-console.log for a crash" >&2
        fi
        ;;
    401) echo "error: $LV_URL wants this build's bearer token; none was found (set DEBUGTRACE_TOKEN, or launch with build-and-sign --mcp)" >&2 ;;
    *)
        message="$(/usr/bin/plutil -extract error.message raw -o - "$response" 2>/dev/null || true)"
        hint="$(/usr/bin/plutil -extract error.hint raw -o - "$response" 2>/dev/null || true)"
        echo "error: $LV_URL/screenshot answered HTTP $status${message:+: $message}" >&2
        [ -n "$hint" ] && echo "hint: $hint" >&2
        ;;
esac
exit 1
