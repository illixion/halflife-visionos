#!/usr/bin/env bash
# Applies LambdaVision's VR layer to an hlsdk-portable-based source tree.
#
#   apply.sh <hlsdk-dir>            copy the layer in and apply the hooks
#   apply.sh --check <hlsdk-dir>    only report whether the hooks apply
#   apply.sh --export <hlsdk-dir>   after editing VisionPort/hlsdk-portable
#                                   (Half-Life, the pinned upstream): write the
#                                   hook edits back to hooks.patch and the
#                                   layer's files back to this folder
#
# The VR logic lives in our own files (cl_dll/vr/*.cpp, dlls/vr/*), which
# hlsdk-portable's wscripts pick up by their **/*.cpp globs, so no build file
# changes. The edits to upstream files (hooks.patch) are only hook calls, each
# one hunk with its own declaration. On a mod branch they either merge
# (falling back to one line of context), or fail on a named file and line:
# that is the place to port the hook by hand.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

mode=apply
case "${1:-}" in
    --check) mode=check; shift ;;
    --export) mode="export"; shift ;;
esac
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir/cl_dll" ] || [ ! -d "$dir/dlls" ]; then
    echo "usage: $0 [--check|--export] <hlsdk-portable-dir>  (needs cl_dll/ and dlls/)" >&2
    exit 2
fi
dir="$(cd "$dir" && pwd)"

if [ "$mode" = export ]; then
    git -C "$dir" diff -- . ':(exclude)cl_dll/vr' ':(exclude)dlls/vr' > "$here/hooks.patch"
    cp -p "$dir"/cl_dll/vr/* "$here/cl_dll/vr/"
    cp -p "$dir"/dlls/vr/* "$here/dlls/vr/"
    echo "exported hooks.patch ($(wc -l < "$here/hooks.patch" | tr -d ' ') lines) and the layer's files"
    exit 0
fi

# Hooks already in? Either exactly as hooks.patch has them (re-running
# setup), or ported by hand into a mod: every file the patch touches already
# calls into the layer.
hooked_by_hand() {
    local f
    while read -r f; do
        [ -f "$dir/$f" ] && /usr/bin/grep -q 'VR_\|g_vr_\|vr/vr_' "$dir/$f" || return 1
    done < <(sed -n 's#^+++ b/##p' "$here/hooks.patch")
}
apply_args=()
if (cd "$dir" && git apply --reverse --check "$here/hooks.patch" 2>/dev/null) || hooked_by_hand; then
    hooks=applied
else
    hooks=missing
    if ! report=$(cd "$dir" && git apply --check "$here/hooks.patch" 2>&1); then
        # Mods move code around the hook sites; one line of context on each
        # side is usually still unique. Say which hunks needed it.
        if fuzzy=$(cd "$dir" && git apply --check -C1 "$here/hooks.patch" 2>&1); then
            apply_args=(-C1)
            echo "note: some VR hooks only matched with reduced context, check them:"
            echo "$report" | sed -n 's/^error: patch failed: /  /p'
        else
            echo "ERROR: the VR hooks don't apply to $dir." >&2
            echo "$fuzzy" | sed -n 's/^error: patch failed: /  conflict in: /p; s/^error: \(.*\): No such file or directory/  missing file: \1/p' >&2
            echo "Each hook is one small hunk in $here/hooks.patch (a call plus its" >&2
            echo "declaration). Add the conflicting ones to the file named above by hand," >&2
            echo "at the matching spot in this mod's code, and build from that edited" >&2
            echo "tree: a file that already calls into the layer counts as hooked." >&2
            exit 1
        fi
    fi
fi

if [ "$mode" = check ]; then
    echo "VR hooks: $hooks, and they apply cleanly"
    exit 0
fi

mkdir -p "$dir/cl_dll/vr" "$dir/dlls/vr"
cp -p "$here"/cl_dll/vr/* "$dir/cl_dll/vr/"
cp -p "$here"/dlls/vr/* "$dir/dlls/vr/"
if [ "$hooks" = missing ]; then
    (cd "$dir" && git apply ${apply_args[@]+"${apply_args[@]}"} "$here/hooks.patch")
fi
echo "VR layer applied to $dir"
