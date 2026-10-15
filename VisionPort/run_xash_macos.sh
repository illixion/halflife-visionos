#!/usr/bin/env bash
# Runs the native Mac engine build (build_xash_macos.sh) the way automated
# runs need it: behind the active app, muted, from build/mac-run. Like the
# Oneiros Mac harness, background is the default and an opt-out exists for
# playing by hand.
#
#   ./run_xash_macos.sh -game valve +exec dump.cfg
#   LAMBDA_MAC_TIMEOUT=150 ./run_xash_macos.sh -game valve -width 960 -height 960 +exec dump.cfg
#   LAMBDA_MAC_BACKGROUND=0 LAMBDA_MAC_SOUND=1 ./run_xash_macos.sh -game gearbox +map of1a1
#
# Environment:
#   LAMBDA_MAC_BACKGROUND  1 (default): no Dock entry, never takes focus or the
#                          mouse (SDL_MAC_BACKGROUND_APP, -noenginemouse,
#                          m_ignore), no modal error dialogs (-nomsgbox).
#                          0: an ordinary focused window with mouse look.
#   LAMBDA_MAC_SOUND       0 (default): -nosound. 1: audio on.
#   LAMBDA_MAC_TIMEOUT     seconds before the run is stopped (default: none).
#   LAMBDA_MAC_RO          1: run build/mac-run-ro against HalfLifeAssets via
#                          -rodir (the device's layout).
#
# Arguments go to xash3d as they are; -dev 1 and -windowed are added.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

run="$root/build/mac-run"
extra=()
if [ "${LAMBDA_MAC_RO:-0}" = 1 ]; then
    run="$root/build/mac-run-ro"
    extra+=(-rodir "$root/HalfLifeAssets")
    export XASH_FS_RAMCACHE=1
fi
[ -x "$run/xash3d" ] || { echo "no $run/xash3d: run VisionPort/build_xash_macos.sh first" >&2; exit 1; }

if [ "${LAMBDA_MAC_BACKGROUND:-1}" = 1 ]; then
    # BackgroundOnly to LaunchServices: the engine's SDL_RaiseWindow cannot
    # activate it, so the user's app keeps focus (checked with lsappinfo).
    export SDL_MAC_BACKGROUND_APP=1
    extra+=(-noenginemouse -nomsgbox +m_ignore 1)
fi
[ "${LAMBDA_MAC_SOUND:-0}" = 1 ] || extra+=(-nosound)

cd "$run"
cmd=(./xash3d -dev 1 -windowed ${extra[@]+"${extra[@]}"} "$@")
if [ -n "${LAMBDA_MAC_TIMEOUT:-}" ]; then
    # perl's alarm survives exec (macOS has no timeout(1) without coreutils)
    exec /usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$LAMBDA_MAC_TIMEOUT" "${cmd[@]}"
fi
exec "${cmd[@]}"
