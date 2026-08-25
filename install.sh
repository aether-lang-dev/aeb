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

# Resolve GNU make specifically. The Makefile is GNU-make syntax (ifeq,
# $(shell), pattern rules), so bare `make` picks BSD make on FreeBSD/*BSD,
# which dies mid-build with "make: stopped making install" — while the old
# `have make` guard passes because *a* make exists, it is just the wrong one.
# Prefer `gmake` (the GNU make binary on every BSD; identical to `make` on
# Linux), honour an explicit $MAKE, and VERIFY the choice is GNU rather than
# trusting the name. Mirrors aether's installer + its
# install-sh-picks-bsd-make-on-freebsd.md.
# (asks/installer-bsd-make-and-204-dirty-tree.md)
if [ -n "${MAKE:-}" ] && have "$MAKE"; then
    MAKE_CMD="$MAKE"
elif have gmake; then
    MAKE_CMD="gmake"
elif have make; then
    MAKE_CMD="make"
elif have mingw32-make; then
    MAKE_CMD="mingw32-make"
else
    die "GNU make is required (install 'gmake' on FreeBSD/*BSD, 'make' on Linux)."
fi
if ! "$MAKE_CMD" --version 2>/dev/null | grep -qi 'gnu make'; then
    die "'$MAKE_CMD' is not GNU make — the aeb Makefile is GNU-make syntax.
     On FreeBSD/*BSD: pkg install gmake  (this script then prefers gmake).
     Or set MAKE=/path/to/gnu-make and re-run."
fi

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

# Loud warning when run from INSIDE an aeb checkout. This script always
# downloads a source tarball for $REF and builds THAT — it never builds the
# tree you are standing in. Both look identical afterwards: the version banner
# says "installed <today>", which reads as "my changes are in" when it actually
# means "a fresh install of released code".
#
# That cost a full round-trip of false results on the Windows line: three
# consecutive bug reports were measured against a binary that predated the
# fixes being tested, including one that "disproved" a hypothesis which was in
# fact correct. `make install` is what builds the working tree.
if [ -f ./Makefile ] && [ -f ./aeb ] && [ -d ./lib ] && [ -d ./tools ]; then
    echo "aeb: WARNING you are inside an aeb checkout, but this installer does NOT build it." >&2
    echo "aeb:   It downloads the '$REF' tarball from GitHub and installs that instead," >&2
    echo "aeb:   so any local edits (or a commit not yet in '$REF') will NOT be included." >&2
    echo "aeb:   To install THIS tree:  make install PREFIX=\"$PREFIX\" AETHER=\"$AETHER\"" >&2
    echo "aeb:   Verify what you got:   aeb --version   (the git describe must match your HEAD)" >&2
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

say "building + installing (no tests run) with $MAKE_CMD"
"$MAKE_CMD" -C "$src" install PREFIX="$PREFIX" AETHER="$AETHER"

bin="$PREFIX/bin/aeb"
[ -x "$bin" ] || die "install finished but $bin is missing."
say "installed: $bin"
"$bin" --version || true

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) say "note: $PREFIX/bin is not on your PATH — add it to use 'aeb' directly." ;;
esac

say "done. Pin this in CI with: AEB_REF=$REF"
