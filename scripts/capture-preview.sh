#!/usr/bin/env bash
# Takes the pictures the Settings window's preview column wants (see
# docs/settings-previews.md) from the running game: one screenshot per value
# of a setting, from where the player is looking, then puts the setting back.
#
#   scripts/capture-preview.sh <setting> <asset-base> [<value> ...]
#   scripts/capture-preview.sh glassReflections glassReflections
#   scripts/capture-preview.sh aimReticle aimReticle off dot beam
#   scripts/capture-preview.sh waterMirrorMethod waterMirrorMethod screenSpace rendered rayTraced
#
# <setting> is a key of POST /setting; <asset-base> the preview's name
# (a switch gives <base>-off.jpg and <base>-on.jpg; a choice <base>-<value>.jpg).
# With no values, a switch is captured off and then on. Stand where the
# setting shows (looking at water for the reflections), hold still, and run it;
# the headset asks you to allow each screenshot. The pictures are one eye's
# view, cropped to 16:10 and written to LambdaVision/LambdaVision/Previews/.
#
#   --eye left|right      which eye (default left)
#   --settle SECONDS      wait after each change (default 3)
#   --out-dir DIR         where to write (default LambdaVision/LambdaVision/Previews)
set -eu
cd "$(dirname "$0")/.."

eye=left
settle=3
out_dir=LambdaVision/LambdaVision/Previews
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --eye) eye="$2"; shift 2 ;;
        --settle) settle="$2"; shift 2 ;;
        --out-dir) out_dir="$2"; shift 2 ;;
        -h|--help) /usr/bin/sed -n '2,19p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
        *) args+=("$1"); shift ;;
    esac
done
[ "${#args[@]}" -ge 2 ] || { echo "usage: capture-preview.sh <setting> <asset-base> [values...]" >&2; exit 2; }
setting="${args[0]}"
base="${args[1]}"
values=("${args[@]:2}")

# shellcheck source-path=SCRIPTDIR source=debug-server-lib.sh
. scripts/debug-server-lib.sh
lv_resolve_server "" || { echo "error: no LambdaVision debug server found" >&2; exit 1; }

# The setting's present value, from GET /settings (data.values, keyed by setting).
current() {
    lv_curl "settings" | /usr/bin/python3 -c "
import json,sys
v=json.load(sys.stdin)['data']['values']['$setting']
print(str(v).lower() if isinstance(v,bool) else v)"
}
set_value() {
    lv_curl "setting" -X POST -H 'Content-Type: application/json' \
        -d "{\"key\":\"$setting\",\"value\":\"$1\"}" >/dev/null
}

original="$(current)"
case "$original" in true|false) is_switch=1 ;; *) is_switch=0 ;; esac
if [ "${#values[@]}" -eq 0 ]; then
    [ "$is_switch" = 1 ] || { echo "error: $setting isn't a switch; list the values to capture" >&2; exit 2; }
    values=(off on)
fi
mkdir -p "$out_dir"

restore() { set_value "$original" || true; }
trap restore EXIT

for v in "${values[@]}"; do
    case "$v" in on) send=true ;; off) send=false ;; *) send="$v" ;; esac
    set_value "$send"
    sleep "$settle"
    png="$(scripts/avp-screenshot.sh --eye "$eye" --width 2400 --out "build/screenshots/preview-$base-$v.png")"
    # 16:10 centre crop, JPEG.
    w="$(/usr/bin/sips -g pixelWidth "$png" | /usr/bin/awk '/pixelWidth/ {print $2}')"
    h=$(( w * 10 / 16 ))
    out="$out_dir/$base-$v.jpg"
    /usr/bin/sips -c "$h" "$w" -s format jpeg -s formatOptions 85 "$png" --out "$out" >/dev/null
    echo "$out"
done
