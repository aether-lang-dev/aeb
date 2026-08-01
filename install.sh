#!/usr/bin/env sh
# aeb installer — fetch a pinned aeb source tarball and `make install`.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh | sh
#   AEB_REF=v0.042 sh install.sh
#   AEB_REF=v0.042 PREFIX="$HOME/.local" AETHER=/opt/ae/bin/ae sh install.sh
#
# Env knobs:
#   AEB_REF   tag (v0.NNN), branch, or commit SHA to install.
#             Default: the latest v0.NNN tag (falls back to `main`).
#   PREFIX    install prefix. Default: $HOME/.local  (no sudo).
#   AETHER    the Aether `ae` toolchain to build aeb with.
#             Default: `ae` on PATH. aeb is written in Aether, so this is
#             a hard prerequisite — install it first if absent (see
#             https://github.com/aether-lang-dev/aether).
#
# Note: aeb tags are pinnable markers, NOT sem-ver compatibility promises
# (a higher v0.NNN just means "later"). Pin AEB_REF for reproducible CI.
set -eu

REPO="aether-lang-dev/aeb"
PREFIX="${PREFIX:-$HOME/.local}"
AETHER="${AETHER:-ae}"

say()  { printf 'aeb-install: %s\n' "$*"; }
die()  { printf 'aeb-install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || die "curl is required."
have tar  || die "tar is required."
have make || die "GNU make is required."

# The Aether toolchain is required to build aeb (aeb is Aether source).
if ! have "$AETHER"; then
    die "the Aether toolchain '$AETHER' was not found.
     aeb is written in Aether and needs 'ae' to build. Install it first
     (https://github.com/aether-lang-dev/aether, docs/bootstrap-from-source.md)
     or point AETHER at an existing one: AETHER=/path/to/ae sh install.sh"
fi

# Resolve the ref to install. Default: highest v0.NNN tag on the remote.
REF="${AEB_REF:-}"
if [ -z "$REF" ]; then
    latest=$(curl -fsSL "https://api.github.com/repos/$REPO/tags?per_page=100" 2>/dev/null \
        | grep -o '"name"[[:space:]]*:[[:space:]]*"v0\.[0-9][0-9]*"' \
        | sed -n 's/.*"v0\.0*\([0-9][0-9]*\)".*/\1/p' \
        | sort -n | tail -1)
    if [ -n "$latest" ]; then
        REF=$(printf 'v0.%03d' "$latest")
    else
        REF="main"
        say "no v0.NNN tag found; falling back to 'main' (not pinned)."
    fi
fi

say "installing aeb @ $REF  ->  PREFIX=$PREFIX  (AETHER=$AETHER)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# GitHub serves a source tarball for any ref (tag/branch/sha) at this URL.
url="https://github.com/$REPO/archive/$REF.tar.gz"
say "fetching $url"
curl -fSL "$url" -o "$tmp/aeb.tar.gz" || die "download failed for ref '$REF'."
tar -xzf "$tmp/aeb.tar.gz" -C "$tmp" || die "extract failed."

# GitHub names the top dir <repo>-<ref> (leading 'v' stripped for tags).
src=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'aeb-*' | head -1)
[ -n "$src" ] && [ -d "$src" ] || die "could not locate extracted source dir."

say "building + installing (no tests run)"
make -C "$src" install PREFIX="$PREFIX" AETHER="$AETHER"

bin="$PREFIX/bin/aeb"
[ -x "$bin" ] || die "install finished but $bin is missing."
say "installed: $bin"
"$bin" --version || true

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) say "note: $PREFIX/bin is not on your PATH — add it to use 'aeb' directly." ;;
esac

say "done. Pin this in CI with: AEB_REF=$REF"
