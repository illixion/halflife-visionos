#!/usr/bin/env bash
# Checks the launcher's chapter lists and save-file sniffing on the Mac
# against the app's own source (Launcher/ChapterCatalog.swift), and, when the
# game files are beside the app, that every chapter map exists.
#
#   ./build.sh [--assets=/path/to/HalfLifeAssets]
#
# Exits non-zero on the first failed check.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app="$repo/LambdaVision/LambdaVision"
out="$repo/build/launcher-probe"
mkdir -p "$out"

swiftc -O "$app/Launcher/ChapterCatalog.swift" "$here/main.swift" -o "$out/probe"
assets="$repo/HalfLifeAssets"
for a in "$@"; do
    case "$a" in --assets=*) assets="${a#--assets=}" ;; esac
done
"$out/probe" "$assets"
