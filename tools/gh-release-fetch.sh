#!/bin/sh
# gh-release-fetch.sh REPO TAG ASSET DEST — download one GitHub release asset,
# trying the plain release URL and then the REST API.
#
#   sh gh-release-fetch.sh aether-lang-dev/aeb v0.330 aeb-resolve.jar /tmp/x.jar
#
# Exit 0 with DEST written, or 1 with the reason on stderr. POSIX sh, curl or
# wget, no jq. This is the file aeb's own scripts (the `aeb` trampoline, lib/bldr)
# call; get.sh, which arrives over a pipe and so cannot rely on a sibling file,
# carries the same function inline. Deliberately not executable: release.yml
# strips executable non-.ae files from tools/, and it is always run as `sh FILE`.
#
# release assets: web URL first, REST API second. See the block below.
say()  { printf 'gh-release-fetch: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# >>> gh-release-download (the same text is in tools/gh-release-fetch.sh; itests/gh-release-fallback.sh checks they match)
# https://github.com/<repo>/releases/download/<tag>/<asset> is served by a
# different backend from api.github.com, and it can fail alone (a repo-specific
# HTTP 504 on it was seen on 2026-11-09). The API serves the same bytes: find
# the asset's id in /releases/tags/<tag>, then GET /releases/assets/<id> with
# Accept: application/octet-stream (a redirect to the CDN). Unauthenticated use
# is allowed; GITHUB_TOKEN or GH_TOKEN, when set, is sent as a Bearer token.
# The API lists a sha256 `digest` per asset; the fallback verifies against it.
# AE_GITHUB_WEB_BASE / AE_GITHUB_API_BASE move the two endpoints (for tests).
GH_WEB="${AE_GITHUB_WEB_BASE:-https://github.com}"
GH_API="${AE_GITHUB_API_BASE:-https://api.github.com}"

# gh_http URL DEST [octet] [auth] : one GET with curl, else wget; non-zero on failure.
# The token goes in a mode-600 file, never on the command line.
gh_http() {
    _ghh_u="$1"; _ghh_d="$2"; _ghh_o="${3:-}"; _ghh_tok=""
    # The token is for the API only; the plain release URL is tried without it.
    [ -z "${4:-}" ] || _ghh_tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    case "$_ghh_tok" in *[!A-Za-z0-9_.-]*) _ghh_tok="" ;; esac
    _ghh_cfg=""
    if [ -n "$_ghh_tok" ]; then
        _ghh_cfg="$(umask 077; mktemp)" || return 1
        if have curl; then printf 'header = "Authorization: Bearer %s"\n' "$_ghh_tok" > "$_ghh_cfg"
        else printf 'header = Authorization: Bearer %s\n' "$_ghh_tok" > "$_ghh_cfg"; fi
    fi
    if have curl; then
        set -- -fsSL --connect-timeout 10
        [ -z "$_ghh_o" ] || set -- "$@" -H "Accept: application/octet-stream"
        [ -z "$_ghh_cfg" ] || set -- "$@" -K "$_ghh_cfg"
        _ghh_rc=0; curl "$@" -o "$_ghh_d" "$_ghh_u" 2>/dev/null || _ghh_rc=$?
    elif have wget; then
        set -- -q --timeout=10 --tries=2
        [ -z "$_ghh_o" ] || set -- "$@" --header="Accept: application/octet-stream"
        [ -z "$_ghh_cfg" ] || set -- "$@" --config="$_ghh_cfg"
        _ghh_rc=0; wget "$@" -O "$_ghh_d" "$_ghh_u" 2>/dev/null || _ghh_rc=$?
    else
        _ghh_rc=1
    fi
    [ -z "$_ghh_cfg" ] || rm -f "$_ghh_cfg"
    return $_ghh_rc
}

gh_sha256() {
    if have sha256sum; then sha256sum "$1" | awk '{print $1}'
    elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# gh_release_download REPO TAG ASSET DEST : fetch a release asset, trying the
# normal URL and then the API. 0 on success; on failure says that both failed.
gh_release_download() {
    _ghd_r="$1"; _ghd_t="$2"; _ghd_a="$3"; _ghd_d="$4"
    gh_http "$GH_WEB/$_ghd_r/releases/download/$_ghd_t/$_ghd_a" "$_ghd_d" && return 0
    rm -f "$_ghd_d"
    say "  $GH_WEB/$_ghd_r/releases/download/$_ghd_t/$_ghd_a failed; trying the GitHub API"
    _ghd_j="$_ghd_d.release.json"
    if ! gh_http "$GH_API/repos/$_ghd_r/releases/tags/$_ghd_t" "$_ghd_j" "" auth; then
        rm -f "$_ghd_j"
        say "  both the release URL and the GitHub API failed for $_ghd_a ($_ghd_t): the API could not be read (no network, no such release, or its rate limit)"
        return 1
    fi
    # No jq: split the JSON at commas, one field per line, and take the id of
    # the asset whose "name" is exactly $_ghd_a, plus its sha256 digest if listed.
    _ghd_l="$(tr ',' '\n' < "$_ghd_j" | awk -v f="$_ghd_a" '
        /"id"[[:space:]]*:/ && !hit { s=$0; sub(/.*"id"[[:space:]]*:[[:space:]]*/,"",s); sub(/[^0-9].*/,"",s); lastid=s }
        /"name"[[:space:]]*:/ { if (hit) exit
            n=$0; sub(/.*"name"[[:space:]]*:[[:space:]]*"/,"",n); sub(/".*/,"",n)
            if (n==f) { hit=1; id=lastid } }
        hit && /"digest"[[:space:]]*:/ { d=$0; sub(/.*sha256:/,"",d); sub(/[^0-9a-f].*/,"",d); dig=d }
        END { if (hit) print id, dig }')"
    rm -f "$_ghd_j"
    _ghd_id="${_ghd_l%% *}"; _ghd_dig=""
    case "$_ghd_l" in *" "*) _ghd_dig="${_ghd_l#* }" ;; esac
    if [ -z "$_ghd_id" ]; then
        say "  both the release URL and the GitHub API failed for $_ghd_a ($_ghd_t): the release lists no asset by that name"
        return 1
    fi
    if ! gh_http "$GH_API/repos/$_ghd_r/releases/assets/$_ghd_id" "$_ghd_d" octet auth; then
        rm -f "$_ghd_d"
        say "  both the release URL and the GitHub API failed for $_ghd_a ($_ghd_t): the API asset download failed"
        return 1
    fi
    if [ "${#_ghd_dig}" = 64 ]; then
        _ghd_got="$(gh_sha256 "$_ghd_d")"
        if [ -n "$_ghd_got" ] && [ "$_ghd_got" != "$_ghd_dig" ]; then
            rm -f "$_ghd_d"
            say "  the API download of $_ghd_a does not match the sha256 digest GitHub lists (expected $_ghd_dig, got $_ghd_got)"
            return 1
        fi
    fi
    say "  fetched $_ghd_a through the GitHub API"
    return 0
}
# <<< gh-release-download

[ $# -eq 4 ] || { echo "usage: sh gh-release-fetch.sh REPO TAG ASSET DEST" >&2; exit 2; }
gh_release_download "$@"
