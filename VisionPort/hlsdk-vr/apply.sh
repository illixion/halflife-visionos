#!/usr/bin/env bash
# Applies LambdaVision's VR layer to an hlsdk-portable-based source tree.
#
#   apply.sh <hlsdk-dir>            copy the layer in and apply the hooks
#   apply.sh --check <hlsdk-dir>    only report whether the hooks apply
#   apply.sh --export <hlsdk-dir>   after editing in a clone: write the hook
#                                   edits back to hooks.patch and the layer's
#                                   files back to this folder
#
# The VR logic lives in our own files (cl_dll/vr/*.cpp, dlls/vr/*), which
# hlsdk-portable's wscripts pick up by their **/*.cpp globs, so no build file
# changes. The edits to upstream files (hooks.patch) are only hook calls, each
# one hunk with its own declaration. On a mod branch they either merge, or
# fail on a named file and line: that is the place to port the hook by hand.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

mode=apply
case "${1:-}" in
    --check) mode=check; shift ;;
    --export) mode=export; shift ;;
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

# Hooks already in? (re-running setup, or a tree built before)
if (cd "$dir" && git apply --reverse --check "$here/hooks.patch" 2>/dev/null); then
    hooks=applied
else
    hooks=missing
    if ! report=$(cd "$dir" && git apply --check "$here/hooks.patch" 2>&1); then
        echo "ERROR: the VR hooks don't apply to $dir." >&2
        echo "$report" | sed -n 's/^error: patch failed: /  conflict in: /p; s/^error: \(.*\): No such file or directory/  missing file: \1/p' >&2
        echo "Each hook is one small hunk in $here/hooks.patch: open the file above," >&2
        echo "find the matching spot in this mod's code and add the call by hand," >&2
        echo "then run: $0 --export $dir" >&2
        exit 1
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
    (cd "$dir" && git apply "$here/hooks.patch")
fi
echo "VR layer applied to $dir"
