#!/usr/bin/env bash
# Checks the settings preset format on the Mac against the app's own
# sources: the file format, schema and matching rules (SettingsPreset.swift),
# the presets that ship (BuiltInPresets.swift), and that SettingsBindings.swift
# binds exactly the settings the schema lists.
#
#   ./build.sh
#
# Exits non-zero on the first failed check.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app="$repo/LambdaVision/LambdaVision"
out="$repo/build/preset-probe"
mkdir -p "$out"

swiftc -O \
    "$app/Settings/Presets/SettingsPreset.swift" "$app/Settings/Presets/BuiltInPresets.swift" \
    "$here/main.swift" -o "$out/probe"
"$out/probe" "$app/Settings/Presets/SettingsBindings.swift" "$app/GameSettings.swift"
