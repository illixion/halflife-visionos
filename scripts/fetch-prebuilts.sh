#!/usr/bin/env bash
# Downloads the prebuilt engine archives (ANGLE, libxash, compiled-in game
# ports) from the GitHub Release matching the current sources, for whichever
# of them is missing locally. Called by scripts/pre-build.sh before it checks
# for libxash.a; also fine to run by hand.
#
# Release tags are content keys from scripts/prebuilt-keys.sh, so a tree with
# edited patches or build scripts finds no release and keeps the "build it
# yourself" path. Never fails the build and never overwrites a local file:
# offline, no release yet, or a bad download all just print why and fall
# through to pre-build.sh's own checks.
#
# Source repo: $LAMBDA_PREBUILT_REPO, else the GitHub repo of `origin`, then
# illixion/halflife-visionos. Uses `gh release download` when gh works, else
# curl against the public release URL.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0

ANGLE_DIR=LambdaVision/Vendor/angle
XASH_DIR=LambdaVision/Vendor/libxash
# Literal scratch path (gitignored) so cleanup never needs rm on a variable.
STAGE=LambdaVision/Vendor/.prebuilt-download
UPSTREAM=illixion/halflife-visionos

say() { echo "prebuilts: $*"; }

missing_angle=()
for f in libANGLE.a libANGLE-sim.a; do
    [[ -e "$ANGLE_DIR/$f" ]] || missing_angle+=("$f")
done
[[ -d "$ANGLE_DIR/include" ]] || missing_angle+=(angle-include.tar.gz)
missing_xash=()
for f in libxash.a libxash-sim.a; do
    [[ -e "$XASH_DIR/$f" ]] || missing_xash+=("$f")
done

if ! keys=$(./scripts/prebuilt-keys.sh 2>&1); then
    say "can't compute release keys ($keys); skipping"
    exit 0
fi
angle_key=$(printf '%s\n' "$keys" | sed -n 's/^angle=//p')
xash_key=$(printf '%s\n' "$keys" | sed -n 's/^xash=//p')

# A local archive that came from an older prebuilt is kept, but say so: it no
# longer matches the sources.
for pair in "$ANGLE_DIR:$angle_key" "$XASH_DIR:$xash_key"; do
    dir=${pair%%:*} want=${pair#*:}
    if [[ -f "$dir/.prebuilt-key" ]] && [[ "$(cat "$dir/.prebuilt-key")" != "$want" ]]; then
        say "note: $dir holds prebuilt $(cat "$dir/.prebuilt-key"), sources now match $want."
        say "      Delete its archives to fetch the matching release, or build locally."
    fi
done

if (( ${#missing_angle[@]} == 0 && ${#missing_xash[@]} == 0 )); then
    exit 0
fi

repos=()
[[ -n "${LAMBDA_PREBUILT_REPO:-}" ]] && repos+=("$LAMBDA_PREBUILT_REPO")
origin=$(git remote get-url origin 2>/dev/null || true)
if [[ "$origin" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    repos+=("${BASH_REMATCH[1]%.git}")
fi
repos+=("$UPSTREAM")

have_gh=0
command -v gh >/dev/null 2>&1 && have_gh=1

# download <repo> <tag> <asset> <dest-dir>
download() {
    if (( have_gh )) && gh release download "$2" --repo "$1" --pattern "$3" \
            --dir "$4" --clobber >/dev/null 2>&1; then
        return 0
    fi
    curl -fsSL --connect-timeout 10 --max-time 600 --retry 2 \
        -o "$4/$3" "https://github.com/$1/releases/download/$2/$3" 2>/dev/null
}

trap 'rm -rf LambdaVision/Vendor/.prebuilt-download' EXIT
rm -rf LambdaVision/Vendor/.prebuilt-download
mkdir -p "$STAGE"

# fetch_release <tag> <dest-dir> <asset>... — downloads the listed assets of
# one release into dest-dir, verified against its SHA256SUMS. Sets $got to the
# assets installed.
fetch_release() {
    local tag=$1 dest=$2; shift 2
    local repo='' r asset sum
    got=()
    for r in "${repos[@]}"; do
        if download "$r" "$tag" SHA256SUMS "$STAGE"; then repo=$r; break; fi
    done
    if [[ -z "$repo" ]]; then
        say "no release $tag found (offline, or not published for these sources yet)"
        return 0
    fi
    mkdir -p "$dest"
    for asset in "$@"; do
        sum=$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }' "$STAGE/SHA256SUMS")
        if [[ -z "$sum" ]]; then
            say "$repo $tag has no $asset"
            continue
        fi
        say "downloading $asset from $repo $tag"
        if ! download "$repo" "$tag" "$asset" "$STAGE"; then
            say "download of $asset failed"
            continue
        fi
        if [[ "$(shasum -a 256 < "$STAGE/$asset" | cut -c1-64)" != "$sum" ]]; then
            say "$asset failed its checksum; discarded"
            continue
        fi
        if [[ "$asset" == angle-include.tar.gz ]]; then
            mkdir -p "$STAGE/inc"
            tar -xzf "$STAGE/$asset" -C "$STAGE/inc" || continue
            [[ -e "$dest/include" ]] || mv "$STAGE/inc/include" "$dest/include"
        else
            mv -n "$STAGE/$asset" "$dest/$asset"
        fi
        got+=("$asset")
    done
    rm -f LambdaVision/Vendor/.prebuilt-download/SHA256SUMS
}

if (( ${#missing_angle[@]} )); then
    fetch_release "$angle_key" "$ANGLE_DIR" "${missing_angle[@]}"
    if [[ " ${got[*]:-} " == *" libANGLE.a "* ]]; then
        printf '%s\n' "$angle_key" > "$ANGLE_DIR/.prebuilt-key"
    fi
fi

if (( ${#missing_xash[@]} )); then
    fetch_release "$xash_key" "$XASH_DIR" "${missing_xash[@]}"
    if [[ " ${got[*]:-} " == *" libxash.a "* ]]; then
        printf '%s\n' "$xash_key" > "$XASH_DIR/.prebuilt-key"
        # Game ports are built against this exact engine, so they only come
        # along with a libxash.a from the same release, never next to a local
        # engine build. SHA256SUMS lists whichever ports built successfully.
        games=()
        for r in "${repos[@]}"; do
            download "$r" "$xash_key" SHA256SUMS "$STAGE" && break
        done
        if [[ -f "$STAGE/SHA256SUMS" ]]; then
            while IFS= read -r g; do
                [[ -e "$XASH_DIR/games/$g" ]] || games+=("$g")
            done < <(awk '{ sub(/^\*/, "", $2) } $2 ~ /^libgame-.*\.a$/ { print $2 }' "$STAGE/SHA256SUMS")
        fi
        if (( ${#games[@]} )); then
            fetch_release "$xash_key" "$XASH_DIR/games" "${games[@]}"
        fi
        # The release's libxash.a holds Half-Life only; fold the ports into
        # the archives the app force-loads and regenerate the compiled-games
        # table (pack_libxash.sh is a no-op for a missing archive).
        if compgen -G "$XASH_DIR/games/libgame-*.a" > /dev/null; then
            ./VisionPort/pack_libxash.sh || say "packing game ports into libxash.a failed"
            XR_SIM=1 ./VisionPort/pack_libxash.sh || say "packing game ports into libxash-sim.a failed"
        fi
    fi
fi
exit 0
