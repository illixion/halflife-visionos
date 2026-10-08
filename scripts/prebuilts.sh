#!/usr/bin/env bash
# Packs and restores the compiled engine pieces (ANGLE, libxash, game ports) as
# release assets, so a build reuses what an earlier release already carries
# instead of recompiling (ANGLE alone is ~12 GiB of sources and hours).
#
#   scripts/prebuilts.sh pack <kind> <outdir>   writes <outdir>/<name>.tar.gz + <name>.sha256
#   scripts/prebuilts.sh fetch [kind...]        restores what's missing locally
#
# Kinds:  angle         libANGLE.a, libANGLE-sim.a, include/
#         xash          libxash.a, libxash-sim.a
#         game:<branch> one built-in port (branch column of VisionPort/games.list)
#         games         every port in games.list
# `fetch` with no kinds means angle, xash and games, then folds the ports into
# libxash (pack_libxash.sh) if any came down. The Build workflow packs a piece
# only when it compiled it, and a later run fetches it from the newest release
# that carries it, so the pieces outlive actions/cache's 7-day expiry.
#
# <name> is a content key from scripts/prebuilt-keys.sh (angle key, xash key,
# or <xash key>-game-<branch>), so only an archive built from exactly the
# sources in this checkout is ever restored. Fetching never fails and never
# replaces a local file: offline, no matching release, or a bad download all
# just say so and exit 0, leaving the "build it yourself" path.
#
# Source repos, in order: $LAMBDA_PREBUILT_REPO, $GITHUB_REPOSITORY, the GitHub
# repo of `origin`, then illixion/halflife-visionos. $GH_TOKEN (optional) lifts
# the API rate limit. $LAMBDA_API exists for testing.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0

VENDOR=LambdaVision/Vendor
API=${LAMBDA_API:-https://api.github.com}
UPSTREAM=illixion/halflife-visionos

say() { echo "prebuilts: $*"; }

keys=""
key() { # angle|xash
    [[ -n "$keys" ]] || keys=$(./scripts/prebuilt-keys.sh 2>&1) || { say "can't compute keys ($keys)"; exit 0; }
    printf '%s\n' "$keys" | sed -n "s/^$1=//p"
}

# Built-in ports: "<gamedir> <branch>" per line of games.list.
ports() { awk '$1 !~ /^#/ && NF >= 4 { print $1, $3 }' VisionPort/games.list; }

# name_of <kind>: the release asset base name.
name_of() {
    case $1 in
        angle) key angle ;;
        xash) key xash ;;
        game:*) echo "$(key xash)-game-${1#game:}" ;;
    esac
}

# required <kind>: files (relative to $VENDOR) that make the piece "present".
required() {
    local gd
    case $1 in
        angle) echo angle/libANGLE.a angle/libANGLE-sim.a angle/include ;;
        xash) echo libxash/libxash.a libxash/libxash-sim.a ;;
        game:*)
            gd=$(ports | awk -v b="${1#game:}" '$2 == b { print $1 }')
            [[ -n "$gd" ]] || { say "no port for branch ${1#game:} in games.list"; return 1; }
            echo "libxash/games/libgame-$gd.a libxash/games/libgame-$gd-sim.a" ;;
    esac
}

# What gets packed for a kind (paths relative to $VENDOR).
payload() {
    case $1 in
        game:*) echo libxash/games ;;
        *) required "$1" ;;
    esac
}

cmd_pack() {
    local kind=$1 out=$2 name
    name=$(name_of "$kind") || exit 1
    mkdir -p "$out"
    # shellcheck disable=SC2046
    tar -czf "$out/$name.tar.gz" -C "$VENDOR" $(payload "$kind") || exit 1
    shasum -a 256 "$out/$name.tar.gz" | cut -c1-64 > "$out/$name.sha256"
    say "packed $name.tar.gz ($(du -h "$out/$name.tar.gz" | cut -f1))"
}

curl_gh() {
    local auth=()
    [[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
    curl -fsSL --connect-timeout 10 --max-time 600 --retry 2 "${auth[@]}" "$@"
}

# resolve <repo> <name>...: appends "<name>\t<url>" to $urls for each asset the
# newest release (of the first 2000) that has it carries. Releases accumulate
# one per main build and a piece sits in the release that compiled it, so the
# search goes deep; the pages are read once for all the names.
resolve() {
    local repo=$1 page json
    shift
    rm -f "$stage"/page-*.json
    for page in $(seq 1 20); do
        json=$(curl_gh "$API/repos/$repo/releases?per_page=100&page=$page") || break
        [[ "${json//[[:space:]]/}" == "[]" ]] && break
        printf '%s' "$json" > "$stage/page-$page.json"
    done
    compgen -G "$stage/page-*.json" >/dev/null || return 0
    (cd "$stage" && python3 -I -c '
import glob, json, sys
want = set(sys.argv[1:])
seen = set()
for path in sorted(glob.glob("page-*.json"), key=lambda p: int(p[5:-5])):
    for rel in json.load(open(path)):
        for a in rel.get("assets", []):
            n = a["name"]
            if n in want and n not in seen:
                seen.add(n)
                print(n + "\t" + a["browser_download_url"])' "$@") >> "$urls"
}

cmd_fetch() {
    local kinds=("$@") explicit=1 kind k name req f repo
    if (( ${#kinds[@]} == 0 )); then
        explicit=0
        kinds=(angle xash games)
    fi
    local expanded=()
    for kind in "${kinds[@]}"; do
        if [[ "$kind" == games ]]; then
            while read -r _ k; do expanded+=("game:$k"); done < <(ports)
        else
            expanded+=("$kind")
        fi
    done

    local wanted=() names=()
    for kind in "${expanded[@]}"; do
        req=$(required "$kind") || continue
        local have=1
        for f in $req; do [[ -e "$VENDOR/$f" ]] || have=0; done
        (( have )) && continue
        wanted+=("$kind")
        name=$(name_of "$kind")
        names+=("$name.tar.gz" "$name.sha256")
    done
    (( ${#wanted[@]} )) || exit 0

    local repos=()
    [[ -n "${LAMBDA_PREBUILT_REPO:-}" ]] && repos+=("$LAMBDA_PREBUILT_REPO")
    [[ -n "${GITHUB_REPOSITORY:-}" ]] && repos+=("$GITHUB_REPOSITORY")
    local origin
    origin=$(git remote get-url origin 2>/dev/null || true)
    if [[ "$origin" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
        repos+=("${BASH_REMATCH[1]%.git}")
    fi
    repos+=("$UPSTREAM")

    stage=$(mktemp -d "$VENDOR/.prebuilts-fetch.XXXXXX") || exit 0
    trap 'rm -rf "$stage"' EXIT
    urls="$stage/urls.tsv"
    : > "$urls"

    for repo in "${repos[@]}"; do
        resolve "$repo" "${names[@]}"
        # Stop once every wanted archive has a URL.
        local missing=0
        for kind in "${wanted[@]}"; do
            grep -q "^$(name_of "$kind").tar.gz	" "$urls" || missing=1
        done
        (( missing )) || break
    done

    local fetched_games=0 got
    for kind in "${wanted[@]}"; do
        name=$(name_of "$kind")
        url=$(awk -F'\t' -v n="$name.tar.gz" '$1 == n { print $2; exit }' "$urls")
        if [[ -z "$url" ]]; then
            say "no release carries $name.tar.gz ($kind)"
            continue
        fi
        say "downloading $name.tar.gz"
        curl_gh -o "$stage/$name.tar.gz" "$url" || { say "download failed ($kind)"; continue; }
        sumurl=$(awk -F'\t' -v n="$name.sha256" '$1 == n { print $2; exit }' "$urls")
        if [[ -n "$sumurl" ]] && curl_gh -o "$stage/$name.sha256" "$sumurl"; then
            if [[ "$(shasum -a 256 < "$stage/$name.tar.gz" | cut -c1-64)" != "$(cut -c1-64 < "$stage/$name.sha256")" ]]; then
                say "checksum mismatch; discarded ($kind)"
                continue
            fi
        fi
        rm -rf "$stage/out"; mkdir "$stage/out"
        tar -xzf "$stage/$name.tar.gz" -C "$stage/out" || { say "bad archive; discarded ($kind)"; continue; }
        got=1
        for f in $(required "$kind"); do [[ -e "$stage/out/$f" ]] || got=0; done
        if (( ! got )); then
            say "archive lacks the expected files; discarded ($kind)"
            continue
        fi
        # Never overwrite what's already here.
        cp -Rn "$stage/out/." "$VENDOR/"
        say "restored $kind"
        [[ "$kind" == game:* ]] && fetched_games=1
    done

    # Ports fold into the archives the app force-loads. Only the no-argument
    # form (the Xcode pre-build hook) does it; CI packs in its own build job.
    if (( fetched_games && ! explicit )); then
        ./VisionPort/pack_libxash.sh || say "packing ports into libxash.a failed"
        XR_SIM=1 ./VisionPort/pack_libxash.sh || say "packing ports into libxash-sim.a failed"
    fi
    exit 0
}

case "${1:-}" in
    pack) [[ $# == 3 ]] || { echo "usage: $0 pack <kind> <outdir>" >&2; exit 2; }; cmd_pack "$2" "$3" ;;
    fetch) shift; cmd_fetch "$@" ;;
    *) echo "usage: $0 pack <kind> <outdir> | fetch [kind...]" >&2; exit 2 ;;
esac
