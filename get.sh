#!/usr/bin/env sh
# aeb remote installer + bootstrap library — ensures the Aether toolchain (`ae`)
# AND the aeb build runner (`aeb`), binary-first. ONE file, TWO modes:
#
#   EXECUTED (human, one line) — installs a pinned `ae` then `aeb`:
#     curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh | sh
#     curl -fsSL .../get.sh | sh -s -- v0.297        # pin the aeb release (positional)
#     AEB_REF=v0.297 AE_PIN=0.645.0 sh get.sh         # pin both, via env
#
#   SOURCED (a consumer repo's README two-liner / CI step) — same logic as fns.
#     Set AEBGET_SOURCE_ONLY=1 so sourcing DEFINES the functions without auto-
#     installing (otherwise a bare shell $0 makes it execute — see the guard):
#     AEBGET_SOURCE_ONLY=1 . <(curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/get.sh)
#     AE_PIN=0.645.0 aeb_bootstrap        # ensures ae (>= AE_PIN) THEN aeb
#     #   or the two steps yourself:  ae_ensure ; aeb_ensure
#
# Mirrors aether's get.sh in shape (say/die/have, positional-arg | env | latest
# resolution, prebuilt-first with source fallback, PATH note, "Pin in CI"
# footer) — but ensures BOTH tools, because aeb's installer needs an `ae` to
# target: any helper that ensures aeb must first ensure ae. This REPLACES the
# former aebboot.sh (same contract; folded in here).
#
# BINARY-FIRST. Precompiled release binaries over source builds:
#   * ae:  aether-<ver>-<os>-x86_64.tar.gz from aether's gh-releases (root
#          layout bin/ include/ lib/ share/ -> PREFIX/). aether ships no .sha256,
#          so the trust boundary is github-over-HTTPS. Source fallback: aether's
#          own get.sh (make install), e.g. for linux-arm64 which has no asset.
#   * aeb: aeb-<os>-x86_64.tar.gz + its .sha256 from aeb's gh-releases; the
#          checksum is VERIFIED (mismatch fatal; a missing sidecar or sha256 tool
#          falls back to source, never installs unverified). Then the bundle's
#          own install.sh (copies files — "no compiler", but runs `make install`,
#          so GNU make is needed). Source fallback: the repo install.sh.
# A cold box thus skips the ~1-2 min per-tool compile.
#
#   ARCH WORD: x86_64 across aether, aeo AND aeb (aeb aligned at v0.300; it used
#   amd64 through v0.299, for which the aeb fetch keeps a transitional fallback).
#
# TRUST MODEL (deliberate). The aeb .sha256 is fetched at RUNTIME and compared —
# it catches transit corruption, not a compromised release (a tamperer replacing
# the tarball could replace its sidecar). We do NOT bake a pinned
# {platform -> sha256} table in — the trust boundary is github + TLS, and a
# hardcoded table would need regenerating on every pin bump. Revisit if the
# threat model ever includes a compromised github release.
#
# Contract (env the CALLER may set — all optional in EXECUTED mode):
#   AE_PIN     FLOOR: oldest ae that can build the repo. REQUIRED for ae_ensure
#              in SOURCED mode; in executed mode, absent => install latest ae.
#   AE_FETCH   ae release to install when the floor is unmet. Default AE_PIN.
#   AETHER_REF explicit ae ref (tag => binary; branch/SHA => source). Overrides.
#   AEB_REF    aeb release tag (or positional arg #1). Default: latest.
#   AEB_MIN    FLOOR: oldest aeb the repo needs (SOURCED mode warns if older).
#   PREFIX     install prefix. Default $HOME/.local (no sudo). Shared by both.
#   AEB_FROM_SOURCE=1 / AEBBOOT_NO_BINARY=1  force source builds (skip binaries).
#
# ---------------------------------------------------------------------------
# AEBGET_REV: 3
# ^ PROPAGATION SNIFF MARKER. Bumped by hand on every change. raw.github lags a
# push by up to minutes; poll the raw URL for `AEBGET_REV: <n>` to know your push
# redeployed. (A file can't contain its own not-yet-existing commit hash.)
# ---------------------------------------------------------------------------

AEBGET_AETHER_GET_URL="${AEBGET_AETHER_GET_URL:-https://raw.githubusercontent.com/aether-lang-dev/aether/main/get.sh}"
AEBGET_AEB_INSTALL_URL="${AEBGET_AEB_INSTALL_URL:-https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh}"
AEBGET_AETHER_REPO="${AEBGET_AETHER_REPO:-aether-lang-dev/aether}"
AEBGET_AEB_REPO="${AEBGET_AEB_REPO:-aether-lang-dev/aeb}"

# --- shared primitives ------------------------------------------------------
say()  { printf 'aeb-get: %s\n' "$*"; }
die()  { printf 'aeb-get: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# version_ge A B : true if A >= B (semver-ish, via sort -V)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# ae_version : bare X.Y.Z of the ae on PATH, or nothing.
ae_version() { ae --version 2>/dev/null | head -n1 | sed -E 's/^ae ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'; }

# aeb_version : aeb's version normalized to X.Y.Z, or nothing. aeb prints a
# two-component tag "aeb v0.297"; a source build reports "aeb 0.0.0-dev+<sha>".
# Normalize X.Y -> X.Y.0 so sort -V doesn't order 0.297 before 0.297.0.
aeb_version() {
    v="$(aeb --version 2>/dev/null | head -n1 | sed -E 's/^aeb v?([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
    [ -n "$v" ] || return 0
    case "$v" in *.*.*) : ;; *.*) v="$v.0" ;; esac
    printf '%s' "$v"
}

# sha256_of FILE : print the file's sha256 hex, or nothing (tool-agnostic).
sha256_of() {
    if have sha256sum; then sha256sum "$1" | awk '{print $1}'
    elif have shasum;   then shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# aebget_platform : echo "os arch" normalized (os linux/macos/freebsd/windows,
# arch x86_64/arm64), or nothing if unrecognized. The arch is the NORMALIZED
# word; both aether and aeb assets are x86_64-worded (aeb from v0.300).
aebget_platform() {
    case "$(uname -s 2>/dev/null)" in
        Linux) _os=linux ;; Darwin) _os=macos ;; FreeBSD) _os=freebsd ;;
        MINGW*|MSYS*|CYGWIN*) _os=windows ;; *) return 0 ;;
    esac
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64) _arch=x86_64 ;; arm64|aarch64) _arch=arm64 ;; *) return 0 ;;
    esac
    printf '%s %s' "$_os" "$_arch"
}

# aebget_preflight_cc : a C compiler + make (SOURCE build only).
aebget_preflight_cc() {
    have cc || have gcc || have clang \
        || die "a C compiler (cc/gcc/clang) is required for a source build — install build-essential (Debian/Ubuntu) or the Xcode Command Line Tools (macOS)."
    have make || have gmake || die "GNU make is required for a source build (install 'gmake' on *BSD)."
}

# fetch_run URL [ENV...] : download an installer to a temp file and run it under
# sh. Downloading first (not curl|sh) means a fetch failure isn't masked by the
# pipe. The caller exports any env the installer reads.
fetch_run() {
    have curl || die "curl is required to install the toolchain."
    _tmp="$(mktemp)"; _rc=0
    if curl -fsSL "$1" -o "$_tmp"; then sh "$_tmp"; _rc=$?; else _rc=$?; fi
    rm -f "$_tmp"; return $_rc
}

# --- ae binary install ------------------------------------------------------
# aebget_install_ae_binary VER : download+extract the ae binary for VER (bare
# X.Y.Z). 0 on success; non-zero => "fall back to source". aether assets are
# x86_64-worded and have a root prefix layout (bin/ include/ lib/ share/).
aebget_install_ae_binary() {
    _ver="$1"; _prefix="${PREFIX:-$HOME/.local}"
    _plat="$(aebget_platform)"; [ -n "$_plat" ] || return 1
    _os="${_plat% *}"; _arch="${_plat#* }"      # aether arch word == normalized
    _url="https://github.com/$AEBGET_AETHER_REPO/releases/download/v$_ver/aether-$_ver-$_os-$_arch.tar.gz"
    _td="$(mktemp -d)"
    say "trying ae binary: aether-$_ver-$_os-$_arch.tar.gz (no .sha256 upstream; HTTPS-trust)"
    if ! curl -fsSL "$_url" -o "$_td/ae.tgz" 2>/dev/null; then
        rm -rf "$_td"; say "  no ae binary for $_os-$_arch @ $_ver — will build from source"; return 1
    fi
    mkdir -p "$_prefix"
    if ! tar -xzf "$_td/ae.tgz" -C "$_prefix" 2>/dev/null; then
        rm -rf "$_td"; say "  ae tarball extract failed — will build from source"; return 1
    fi
    rm -rf "$_td"
    [ -x "$_prefix/bin/ae" ] || { say "  ae tarball had no bin/ae — will build from source"; return 1; }
    return 0
}

# --- aeb binary install -----------------------------------------------------
# aebget_aeb_tag : resolve the aeb release tag. Explicit AEB_REF that looks like
# a tag wins; else AEB_FETCH/AEB_MIN mapped to vX.Y; else latest via /releases/latest.
aebget_aeb_tag() {
    _r="${AEB_REF:-${AEB_FETCH:-${AEB_MIN:-}}}"
    # aeb tags are TWO-part (v0.301). Accept a three-part spelling (v0.301.0 —
    # the ae tag shape, easy to copy by mistake) and normalize it down, rather
    # than returning it verbatim to resolve to a nonexistent tag.
    case "$_r" in
        v[0-9]*.[0-9]*.[0-9]*) printf 'v%s' "$(echo "${_r#v}" | cut -d. -f1,2)"; return 0 ;; # v0.301.0 -> v0.301
        v[0-9]*.[0-9]*) printf '%s' "$_r"; return 0 ;;            # v0.301 (canonical)
        [0-9]*.[0-9]*.[0-9]*) printf 'v%s' "$(echo "$_r" | cut -d. -f1,2)"; return 0 ;; # 0.301.0 -> v0.301
        [0-9]*.[0-9]*) printf 'v%s' "$_r"; return 0 ;;            # 0.301   -> v0.301
    esac
    # Latest via the plain /releases/latest redirect (no rate-limited JSON API).
    _loc=$(curl -fsSI "https://github.com/$AEBGET_AEB_REPO/releases/latest" 2>/dev/null \
        | tr -d '\r' | sed -n 's#^[Ll]ocation:[[:space:]]*.*/releases/tag/\(.*\)$#\1#p' | tail -1)
    [ -n "$_loc" ] && { printf '%s' "$_loc"; return 0; }
    curl -fsSL "https://api.github.com/repos/$AEBGET_AEB_REPO/tags?per_page=100" 2>/dev/null \
        | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(v0\.[0-9][0-9]*\)".*/\1/p' | sort -V | tail -1
}

# aebget_install_aeb_binary : download+verify+install the aeb binary. 0 on
# success; non-zero => source fallback. aeb assets live in a single top dir
# aeb-<os>-<arch>/ with a bundled install.sh.
#
# ARCH WORD: as of v0.300 aeb assets are x86_64-worded (matching aether + aeo);
# v0.299 and earlier shipped amd64-worded assets. So for an x86_64 host we try
# x86_64 FIRST, then fall back to amd64 for an old-tag pin. This fallback is
# transitional — it can be dropped once the amd64-named releases are pruned.
aebget_install_aeb_binary() {
    _prefix="${PREFIX:-$HOME/.local}"
    _plat="$(aebget_platform)"; [ -n "$_plat" ] || return 1
    _os="${_plat% *}"; _narch="${_plat#* }"
    # Candidate arch words, in preference order. arm64 is arm64 in both eras.
    case "$_narch" in
        x86_64) _arches="x86_64 amd64" ;;
        arm64)  _arches="arm64" ;;
        *) return 1 ;;
    esac
    _tag="$(aebget_aeb_tag)"
    [ -n "$_tag" ] || { say "  could not resolve an aeb release tag — will build from source"; return 1; }
    _td="$(mktemp -d)"
    # Try each candidate asset name until one downloads (x86_64 before amd64).
    _base=""
    for _a in $_arches; do
        _cand="aeb-$_os-$_a"
        say "trying aeb binary: $_cand.tar.gz @ $_tag (with .sha256 verify)"
        if curl -fsSL "https://github.com/$AEBGET_AEB_REPO/releases/download/$_tag/$_cand.tar.gz" -o "$_td/aeb.tgz" 2>/dev/null; then
            _base="$_cand"; break
        fi
        say "  no $_cand.tar.gz @ $_tag"
    done
    _url="https://github.com/$AEBGET_AEB_REPO/releases/download/$_tag/$_base.tar.gz"
    if [ -z "$_base" ]; then
        rm -rf "$_td"; say "  no aeb binary for $_os ($_arches) @ $_tag — will build from source"; return 1
    fi
    if curl -fsSL "$_url.sha256" -o "$_td/aeb.sha256" 2>/dev/null; then
        _want="$(awk '{print $1}' "$_td/aeb.sha256")"; _got="$(sha256_of "$_td/aeb.tgz")"
        if [ -z "$_got" ]; then
            rm -rf "$_td"; say "  no sha256 tool to verify — building from source instead"; return 1
        fi
        if [ "$_want" != "$_got" ]; then
            rm -rf "$_td"; die "aeb binary checksum MISMATCH ($_base.tar.gz @ $_tag): expected $_want, got $_got. Refusing a corrupt/tampered binary."
        fi
        say "  sha256 OK"
    else
        rm -rf "$_td"; say "  no .sha256 sidecar for $_base @ $_tag — building from source instead"; return 1
    fi
    if ! tar -xzf "$_td/aeb.tgz" -C "$_td" 2>/dev/null; then
        rm -rf "$_td"; say "  aeb tarball extract failed — will build from source"; return 1
    fi
    _here="$_td/$_base"
    [ -f "$_here/install.sh" ] || { rm -rf "$_td"; say "  aeb bundle had no install.sh — will build from source"; return 1; }
    # NB: the bundle's install.sh is COPY-ONLY as of v0.298 (no make, no compiler
    # — it just stages the prebuilt tree + writes the wrapper). A prior gate here
    # pre-checked for GNU make and bailed to source when absent; that made the
    # whole binary path require make on a bare box (the exact failure a prebuilt
    # bundle exists to avoid). Removed — just run install.sh; the check below
    # catches any real failure.
    if ! sh "$_here/install.sh" "$_prefix" >/dev/null 2>&1; then
        rm -rf "$_td"; say "  aeb bundle install.sh failed — will build from source"; return 1
    fi
    rm -rf "$_td"
    [ -x "$_prefix/bin/aeb" ] || { say "  aeb not at $_prefix/bin/aeb after install — will build from source"; return 1; }
    return 0
}

# --- ae_ensure : guarantee `ae` is on PATH ---------------------------------
# With AE_PIN set: ensure ae >= AE_PIN (the repo floor). Without AE_PIN (a bare
# human run): ensure SOME ae is present, installing the latest if absent.
ae_ensure() {
    _prefix="${PREFIX:-$HOME/.local}"; export PREFIX="$_prefix"
    export PATH="$_prefix/bin:$PATH"
    _pin="${AE_PIN:-}"; _fetch="${AE_FETCH:-${AE_PIN:-}}"

    if have ae; then
        _have="$(ae_version || true)"
        if [ -z "$_pin" ]; then say "ae ${_have:-(present)} already on PATH — skipping"; return 0; fi
        if [ -n "$_have" ] && version_ge "$_have" "$_pin"; then
            say "ae $_have already on PATH (>= $_pin) — skipping"; return 0
        fi
        say "ae ${_have:-present} is below the floor $_pin — upgrading"
    fi

    # Resolve the ref to install. AETHER_REF wins; else AE_FETCH/AE_PIN; else
    # latest ae from aether's /releases/latest.
    _ref="${AETHER_REF:-$_fetch}"
    if [ -z "$_ref" ]; then
        _ref=$(curl -fsSI "https://github.com/$AEBGET_AETHER_REPO/releases/latest" 2>/dev/null \
            | tr -d '\r' | sed -n 's#^[Ll]ocation:[[:space:]]*.*/releases/tag/\(.*\)$#\1#p' | tail -1)
        [ -n "$_ref" ] && say "latest ae release is $_ref"
    fi

    # BINARY first: only a bare/v X.Y.Z has an asset; branch/SHA forces source.
    _ver=""
    case "$_ref" in
        v[0-9]*.[0-9]*.[0-9]*) _ver="${_ref#v}" ;;
        [0-9]*.[0-9]*.[0-9]*)  _ver="$_ref" ;;
    esac
    if [ -z "${AEBBOOT_NO_BINARY:-${AEB_FROM_SOURCE:-}}" ] && [ -n "$_ver" ] && aebget_install_ae_binary "$_ver"; then
        _have="$(ae_version || true)"
        [ -z "$_pin" ] || { [ -n "$_have" ] && version_ge "$_have" "$_pin"; } \
            || die "installed ae binary ${_have:-?} is BELOW the floor $_pin — set AETHER_REF/AE_FETCH to >= $_pin."
        say "ae ${_have:-installed} ready (binary)"; return 0
    fi

    # SOURCE fallback: aether's get.sh.
    aebget_preflight_cc
    case "$_ref" in [0-9]*.[0-9]*.[0-9]*) _ref="v$_ref" ;; esac
    say "installing ae via aether get.sh from source (AETHER_REF=${_ref:-latest}, PREFIX=$_prefix)"
    AETHER_REF="$_ref" PREFIX="$_prefix" fetch_run "$AEBGET_AETHER_GET_URL" || die "ae install failed (get.sh)."
    have ae || die "ae installed but not on PATH — ensure $_prefix/bin is on PATH."
    _have="$(ae_version || true)"
    if [ -n "$_pin" ] && [ -n "$_have" ] && ! version_ge "$_have" "$_pin"; then
        die "installed ae $_have is BELOW the floor $_pin — set AETHER_REF to a tag >= $_pin."
    fi
    say "ae ${_have:-installed} ready (source)"
}

# --- aeb_ensure : guarantee `aeb` is on PATH (needs ae first) ---------------
aeb_ensure() {
    _prefix="${PREFIX:-$HOME/.local}"; export PREFIX="$_prefix"
    export PATH="$_prefix/bin:$PATH"

    if have aeb; then
        _have="$(aeb_version || true)"
        # An explicitly-set AEB_REF is a REQUEST for that exact version: honor it
        # even when some aeb is already present, instead of skipping on mere
        # presence (which silently no-ops "bump the pin, re-run bootstrap" — a
        # user re-running with a newer AEB_REF stayed on the old aeb). Normalize
        # AEB_REF's tag (v0.301 / 0.301 / 0.301.0) to the X.Y.0 aeb_version shape
        # so the compare is apples-to-apples. See
        # asks/get-sh-skips-on-presence-ignores-explicit-aeb-ref.md.
        _want=""
        case "${AEB_REF:-}" in
            "") : ;;                                        # no explicit pin
            v[0-9]*.[0-9]*.[0-9]*) _want="${AEB_REF#v}" ;;  # v0.301.0 -> 0.301.0
            v[0-9]*.[0-9]*)        _want="${AEB_REF#v}.0" ;; # v0.301   -> 0.301.0
            [0-9]*.[0-9]*.[0-9]*)  _want="$AEB_REF" ;;
            [0-9]*.[0-9]*)         _want="$AEB_REF.0" ;;
        esac
        if [ "$_have" = "0.0.0" ]; then
            say "aeb (source build, unversioned) already on PATH — skipping floor check"
            say "using aeb: $(command -v aeb)"; return 0
        fi
        if [ -n "$_want" ] && [ -n "$_have" ] && [ "$_want" != "$_have" ]; then
            # Requested != installed. Upgrade freely; gate only a DOWNGRADE behind
            # AEB_FORCE (an explicit newer pin is what the user asked for).
            if version_ge "$_have" "$_want" && [ -z "${AEB_FORCE:-}" ]; then
                say "aeb $_have on PATH is NEWER than requested AEB_REF ($_want) — keeping it; set AEB_FORCE=1 to downgrade."
                say "using aeb: $(command -v aeb)"; return 0
            fi
            say "aeb $_have on PATH != requested AEB_REF ($_want) — installing $_want"
            # fall through to the install below
        else
            if [ -n "${AEB_MIN:-}" ] && [ -n "$_have" ] && ! version_ge "$_have" "$AEB_MIN"; then
                say "WARNING: aeb $_have is older than this repo's floor $AEB_MIN — upgrade with AEB_REF=v$AEB_MIN"
            else
                say "aeb ${_have:-(version unknown)} already on PATH — skipping"
            fi
            say "using aeb: $(command -v aeb)"; return 0
        fi
    fi

    have ae || die "aeb_ensure: no \`ae\` on PATH — call ae_ensure first (or aeb_bootstrap); aeb's installer needs an ae to target."

    if [ -z "${AEBBOOT_NO_BINARY:-${AEB_FROM_SOURCE:-}}" ] && aebget_install_aeb_binary; then
        say "using aeb: $(command -v aeb) ($(aeb_version || echo version-unknown)) (binary)"
        _aebget_assert_ref; return 0
    fi

    # SOURCE fallback: repo install.sh (fetch source tarball, build with ae).
    _ref="${AEB_REF:-}"
    case "$_ref" in
        [0-9]*.[0-9]*.[0-9]*) _ref="v${_ref%.*}" ;;   # 0.297.0 -> v0.297
        [0-9]*.[0-9]*)        _ref="v$_ref" ;;         # 0.297   -> v0.297
    esac
    say "installing aeb via install.sh from source (AEB_REF=${_ref:-latest}, PREFIX=$_prefix)"
    AEB_REF="$_ref" PREFIX="$_prefix" AETHER="$(command -v ae)" fetch_run "$AEBGET_AEB_INSTALL_URL" || die "aeb install failed (install.sh) — is AEB_REF='${AEB_REF:-}' a real tag? aeb tags are two-part (v0.301)."
    have aeb || die "aeb installed but not on PATH — ensure $_prefix/bin is on PATH."
    say "using aeb: $(command -v aeb) ($(aeb_version || echo version-unknown)) (source)"
    _aebget_assert_ref
}

# _aebget_assert_ref : after an install driven by an explicit AEB_REF, verify we
# actually landed that version — a requested-but-unresolvable ref (e.g. a typo,
# or the old three-part spelling) must FAIL LOUDLY, not look like success. A
# source build reports 0.0.0 (unversioned), for which the check is a no-op.
_aebget_assert_ref() {
    [ -n "${AEB_REF:-}" ] || return 0
    _want=""
    case "$AEB_REF" in
        v[0-9]*.[0-9]*.[0-9]*) _want="${AEB_REF#v}" ;;
        v[0-9]*.[0-9]*)        _want="${AEB_REF#v}.0" ;;
        [0-9]*.[0-9]*.[0-9]*)  _want="$AEB_REF" ;;
        [0-9]*.[0-9]*)         _want="$AEB_REF.0" ;;
    esac
    [ -n "$_want" ] || return 0
    _got="$(aeb_version || true)"
    [ "$_got" = "0.0.0" ] && return 0           # source build: unversioned, can't check
    if [ "$_got" != "$_want" ]; then
        die "requested AEB_REF=$AEB_REF but installed aeb is ${_got:-unknown} — is $AEB_REF a real tag? aeb tags are two-part (e.g. v0.301, not v0.301.0)."
    fi
}

# --- aeb_bootstrap : the convenience entry point (ae THEN aeb) --------------
aeb_bootstrap() {
    ae_ensure
    aeb_ensure
    case ":$PATH:" in *":${PREFIX:-$HOME/.local}/bin:"*) : ;;
        *) say "tip: add '${PREFIX:-$HOME/.local}/bin' to your shell PATH permanently";; esac
}

# ===========================================================================
# EXECUTED-MODE entry point. Installs when this file is EXECUTED — as `sh get.sh`
# ($0 ends in get.sh) OR piped `curl … | sh` ($0 is the bare shell name, because
# the script arrives on stdin, NOT as a path arg). It must NOT auto-run when
# SOURCED as a library (`. get.sh` / `. <(curl …)`), so a consumer can define the
# functions and call aeb_bootstrap itself with its pins on the next line.
#
# WHY $0 ALONE CANNOT DECIDE. `curl | sh` and `. file` (sourced into an
# interactive/`sh -c` shell) can BOTH leave $0 = `sh`/`bash`/`-sh`/`dash` — so
# "the basename is a shell name" does not separate piped-execute from sourced.
# The earlier guard only matched `*/get.sh`, so `curl | sh` (the headline
# one-liner) silently did NOTHING. The fix: default to RUN, and let the sourced
# library path OPT OUT with AEBGET_SOURCE_ONLY=1 — which the documented sourced
# two-liner sets. A path-named $0 (`sh get.sh`) always runs; a shell-named $0
# runs UNLESS AEBGET_SOURCE_ONLY=1.
# ===========================================================================
_aebget_main() {
    # Positional arg #1 pins the aeb release (mirrors aether get.sh's `sh get.sh
    # v0.184.0`); AEB_REF is the env equivalent. The argument wins.
    [ -n "${1:-}" ] && AEB_REF="$1"
    export AEB_REF="${AEB_REF:-}"
    aeb_bootstrap
    say "done. Pin this in CI with: AE_PIN=${AE_PIN:-<x.y.z>} AEB_REF=${AEB_REF:-<vX.Y>}"
}

if [ -z "${AEBGET_SOURCE_ONLY:-}" ]; then
    case "$0" in
        # `sh get.sh [args]` — $0 is a path ending in get.sh: always execute.
        */get.sh|get.sh) set -eu; _aebget_main "$@" ;;
        # `curl … | sh` — the script is on stdin, so $0 is the bare shell name.
        # Execute (this is the headline one-liner). A caller who instead SOURCES
        # for the functions sets AEBGET_SOURCE_ONLY=1 to skip this.
        sh|-sh|bash|-bash|dash|-dash|ash|-ash|/bin/sh|/bin/bash|/bin/dash)
            set -eu; _aebget_main "$@" ;;
    esac
fi
