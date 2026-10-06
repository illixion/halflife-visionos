# shellcheck shell=bash disable=SC2034 # LV_* are read by the scripts that source this
# Sourced by the device-side debug scripts (avp-screenshot.sh) to find a
# running LambdaVision debug server (LambdaVision/LambdaVision/DebugEndpoints.swift).
#
# The server takes the first free port in 8651-8691 and wants that build's
# bearer token. Where to find both, in order:
#   1. LAMBDA_HOST (host or host:port) and DEBUGTRACE_TOKEN, if set;
#   2. a live `build-and-sign --mcp` session record under
#      ~/.local/state/debugtrace/sessions (url + token);
#   3. Bonjour, through DebugTrace's `debugtrace-mcp discover` (url + key id;
#      the token comes from this Mac's key ledger).
# A host without a port gets the one the app logged in
# build/device-console.log ("listening on port N"), else 8651.
#
# Works with macOS's bash 3.2 and system tools only (plutil reads the JSON).

lv_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/debugtrace"
lv_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lv_console_log="$lv_repo/build/device-console.log"
lv_client="${DEBUGTRACE_CLIENT_NAME:-An agent on $(hostname -s)}"

# Set by lv_resolve_server.
LV_URL=""
LV_TOKEN=""
LV_SOURCE=""

# One field of a JSON file ("url", "token", "0.bundleId", ...), or nothing.
lv_json_field() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

# Newest live LambdaVision session record (its console streamer's pid still
# running), or nothing.
lv_session_record() {
    local file pid
    # shellcheck disable=SC2045 # names are <bundle id>@<device>.json: no spaces, newest first needs ls -t
    for file in $(ls -t "$lv_state_dir"/sessions/*[Ll]ambda[Vv]ision*@*.json 2>/dev/null); do
        pid="$(lv_json_field "$file" pid)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$file"
            return 0
        fi
    done
    return 0
}

# The port the app last logged in build/device-console.log, or nothing.
lv_logged_port() {
    [ -f "$lv_console_log" ] || return 0
    /usr/bin/grep -Eo 'listening on port [0-9]+' "$lv_console_log" 2>/dev/null \
        | /usr/bin/tail -1 | /usr/bin/grep -Eo '[0-9]+$' || true
}

# One field of JSON text on stdin, or nothing.
lv_json_text_field() {
    /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null || true
}

# Bonjour discovery through debugtrace-mcp: sets LV_URL (and LV_TOKEN from
# the key ledger) for the first advertised LambdaVision.
lv_discover() {
    local tool="${DEBUGTRACE_MCP:-$HOME/Projects/DebugTrace/Tools/debugtrace-mcp}"
    [ -x "$tool" ] || return 0
    local json i url bundle key
    json="$("$tool" discover 2>/dev/null || true)"
    i=0
    while :; do
        url="$(printf '%s' "$json" | lv_json_text_field "$i.url")"
        [ -n "$url" ] || break
        bundle="$(printf '%s' "$json" | lv_json_text_field "$i.bundleId")"
        case "$bundle" in
            *[Ll]ambda[Vv]ision*)
                LV_URL="$url"
                key="$(printf '%s' "$json" | lv_json_text_field "$i.keyId")"
                if [ -n "$key" ] && [ -f "$lv_state_dir/keys/$key.json" ]; then
                    LV_TOKEN="$(lv_json_field "$lv_state_dir/keys/$key.json" commandToken)"
                fi
                LV_SOURCE="bonjour"
                return 0 ;;
        esac
        i=$((i + 1))
    done
    return 0
}

# Fills LV_URL (http://host:port), LV_TOKEN and LV_SOURCE. $1 overrides the
# host (host or host:port).
lv_resolve_server() {
    local host="${1:-${LAMBDA_HOST:-}}" record port
    LV_TOKEN="${DEBUGTRACE_TOKEN:-}"
    if [ -n "$host" ]; then
        LV_SOURCE="argument"
    else
        record="$(lv_session_record)"
        if [ -n "$record" ]; then
            host="$(lv_json_field "$record" url)"
            [ -z "$LV_TOKEN" ] && LV_TOKEN="$(lv_json_field "$record" token)"
            LV_SOURCE="session $(basename "$record")"
        else
            lv_discover
            host="$LV_URL"
        fi
    fi
    [ -n "$host" ] || return 1
    host="${host#http://}"
    host="${host%/}"
    case "$host" in
        *:*) ;;
        *) port="$(lv_logged_port)"; host="$host:${port:-8651}" ;;
    esac
    LV_URL="http://$host"
    return 0
}

# curl against the server with the token and client name. Usage:
#   lv_curl <path?query> [curl args...]
lv_curl() {
    local path="$1"
    shift
    if [ -n "$LV_TOKEN" ]; then
        /usr/bin/curl --silent --show-error -H "X-DebugTrace-Client: $lv_client" \
            -H "Authorization: Bearer $LV_TOKEN" "$@" "$LV_URL/$path"
    else
        /usr/bin/curl --silent --show-error -H "X-DebugTrace-Client: $lv_client" "$@" "$LV_URL/$path"
    fi
}
