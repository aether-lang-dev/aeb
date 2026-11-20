#!/usr/bin/env bash
# itests/prebuilt-bundle-no-rebuild.sh — an aeb installed from a release bundle
# keeps the helper tools the bundle ships, on a machine with no C compiler.
#
# A bundle (release/build-bundle.sh, the script the release workflow calls)
# carries five helpers cross-compiled on the release runner so that a node
# need not build them. Until their stamps existed, aeb treated a helper with no
# `tools/<name>.toolchain` as built by an unknown toolchain and rebuilt it on
# first use, which needs a C compiler (or aeb's zig fallback): the bundle's one
# purpose, undone. A shipped helper is now stamped `prebuilt <tag> <platform>`
# and kept when the tree's own VERSION and BUNDLE files say the same (the
# trampoline's aeb_fresh and tools/aebfresh; see release/build-bundle.sh for
# why that is sound).
#
# This test stages and builds a bundle for the host the way the release does
# (release/stage-payload.sh, release/build-bundle.sh; the cross-build when zig
# is on PATH, else the host compiler), installs it with its own install.sh into
# a scratch prefix, and then:
#
#   A. runs aeb with no C compiler reachable (a PATH without cc, gcc, clang,
#      zig and friends, an empty AEB_CACHE_DIR, AEB_NO_ZIG=1): none of the five
#      shipped helpers is rebuilt or removed, and aeb-main runs.
#      (The orchestrator of any build is compiled with the C compiler, so a
#      node without one still cannot finish a build; the helpers' rebuild was
#      the part that this change removes.) Before the change aeb removed
#      tools/aeb-main and died: "could not build tools/aeb-main from source".
#   B. runs a trivial build (a bash.test node) with a compiler: it passes, and
#      the five helpers and their stamps are exactly as installed.
#   C. keeps the helpers when the install's file times are scrambled (sources
#      newer than the binaries, as after a plain cp -R).
#   D. rebuilds a helper whose stamp or tree does not vouch for it, each case
#      on a fresh install, as the dev-tree rule always did: no stamp; a stamp
#      for another platform; a genuine stamp in a tree with no BUNDLE (a
#      development tree); a genuine stamp in a tree whose VERSION is another
#      release; the stamp of another toolchain.
#   E. with AEB_ITEST_OTHER_AETHER=<path to another ae that meets AETHER_PIN>:
#      the same bundle runs under that ae and keeps its helpers.
#
# Usage: AETHER=/path/to/ae ./itests/prebuilt-bundle-no-rebuild.sh
# Exit: 0 if every assertion passed; 1 otherwise. POSIX hosts only.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "  SKIP: Windows"; exit 0 ;; esac
AETHER="${AETHER:-ae}"
AE="$(command -v "$AETHER" 2>/dev/null || true)"
[ -n "$AE" ] || { echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; }
case "$AE" in /*) ;; *) AE="$(cd "$(dirname "$AE")" && pwd)/$(basename "$AE")" ;; esac

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aeb_prebuilt.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT INT TERM

TAG="v0.0.0-itest"
FIVE="aeb-main aeb-link aeb-graph affected-targets gcheckout"
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)            TRIPLE=x86_64-linux;   SUFFIX=linux-x86_64 ;;
    Linux-aarch64|Linux-arm64) TRIPLE=aarch64-linux; SUFFIX=linux-arm64 ;;
    Darwin-arm64)            TRIPLE=aarch64-macos;  SUFFIX=macos-arm64 ;;
    Darwin-x86_64)           TRIPLE=x86_64-macos;   SUFFIX=macos-x86_64 ;;
    FreeBSD-amd64|FreeBSD-x86_64) TRIPLE=x86_64-freebsd; SUFFIX=freebsd-x86_64 ;;
    *) echo "  SKIP: no bundle platform for $(uname -s)-$(uname -m)"; exit 0 ;;
esac
# A real release cross-builds with zig; where zig is not at hand the host
# compiler builds the same five for the host ("native").
# (FreeBSD's cross-link needs a sysroot asset, so it always builds natively.)
if command -v zig >/dev/null 2>&1 && [ "$(uname -s)" != FreeBSD ]; then BUILD_TARGET="$TRIPLE"; else BUILD_TARGET=native; fi

echo "[prebuilt-bundle-no-rebuild] $SUFFIX ($BUILD_TARGET), ae $("$AE" --version 2>/dev/null | sed -n 1p)"

# --- stage, build and install a bundle, as the release does ------------------
( cd "$REPO_ROOT" && release/stage-payload.sh "$TAG" "$WORK/stage" ) \
    || { echo "error: staging failed"; exit 1; }
if ! "$REPO_ROOT/release/build-bundle.sh" "$AE" "$WORK/stage" "$WORK/bundles" "$BUILD_TARGET" "$SUFFIX" "$TAG" > "$WORK/bundle.log" 2>&1; then
    echo "error: the bundle did not build:"; tail -20 "$WORK/bundle.log"; exit 1
fi
BUNDLE_DIR="$WORK/bundles/aeb-$SUFFIX"

install_bundle() {  # install_bundle PREFIX
    "$BUNDLE_DIR/install.sh" "$1" >/dev/null 2>&1
}
PREFIX="$WORK/prefix"
install_bundle "$PREFIX" || { echo "error: install.sh failed"; exit 1; }
SHARE="$PREFIX/share/aeb"
AEB="$PREFIX/bin/aeb"
T="$SHARE/tools"

# --- the projects, and an environment with no compiler in it -----------------
PROJ="$WORK/proj"
mkdir -p "$PROJ/app"
printf '#!/usr/bin/env bash\necho ok\n' > "$PROJ/app/t.sh"; chmod +x "$PROJ/app/t.sh"
cat > "$PROJ/app/.tests.ae" <<'AE'
import bldr
import bash
aeb(cap) {
    bldr.build() {
        bash.test() { script("t.sh") }
    }
}
AE
( cd "$PROJ" && git init -q . 2>/dev/null )

# A PATH of symlinks to ordinary tools, and no compiler: nothing named cc, gcc,
# clang, zig, c++, g++, tcc, or an "-cc"/"gcc-" variant gets in.
NOCC="$WORK/nocc"
mkdir -p "$NOCC"
for c in bash sh env ls cp mkdir rm cat grep egrep sed awk tr sort uniq date uname stat touch dirname \
         basename git readlink realpath mktemp tar gzip gunzip chmod find xargs head tail cut wc sleep id \
         ln mv sha256sum shasum openssl cmp diff tee kill ps printf test expr nproc hostname od curl \
         unzip zip true false ld ar; do
    p="$(command -v "$c" 2>/dev/null || true)"
    case "$p" in /*) ln -sf "$p" "$NOCC/$c" ;; esac
done
for bad in cc gcc clang zig c++ g++ tcc cpp; do
    [ -e "$NOCC/$bad" ] && { echo "error: $bad leaked into the compiler-free PATH"; exit 1; }
done

mtime() { if stat -f %m "$1" >/dev/null 2>&1; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }
snapshot() {  # snapshot DIR -> one line per shipped helper: name, mtime, stamp
    local t
    for t in $FIVE; do
        if [ -x "$1/$t" ]; then printf '%s %s %s\n' "$t" "$(mtime "$1/$t")" "$(cat "$1/$t.toolchain" 2>/dev/null)"
        else printf '%s MISSING\n' "$t"; fi
    done
}
GOOD_STAMP="prebuilt $TAG $SUFFIX"
# aebrun_nocc / aebrun_cc ARGS... : aeb on PROJ with a clean environment.
CACHE="$WORK/cache"
aebrun_nocc() {
    ( cd "$PROJ" && env -i HOME="$HOME" PATH="$NOCC" TMPDIR="$WORK" AETHER="$AE" AEB_NO_ZIG=1 \
        AEB_CACHE_DIR="$CACHE/empty" AETHER_CACHE_DIR="$WORK/aecache" bash "${AEB_RUN:-$AEB}" "$@" )
}
aebrun_cc() {
    ( cd "$PROJ" && env -i HOME="$HOME" PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$WORK" \
        AETHER="${USE_AE:-$AE}" AEB_CACHE_DIR="$CACHE/cc" AETHER_CACHE_DIR="$WORK/aecache" bash "${AEB_RUN:-$AEB}" "$@" )
}
mkdir -p "$CACHE/empty"

echo
echo "0: what the bundle carries"
bad=0
for t in $FIVE; do
    [ -x "$T/$t" ] || { fail "$t is not installed"; bad=1; continue; }
    [ "$(cat "$T/$t.toolchain" 2>/dev/null)" = "$GOOD_STAMP" ] || { fail "$t is stamped '$(cat "$T/$t.toolchain" 2>/dev/null)', not '$GOOD_STAMP'"; bad=1; }
done
[ "$(cat "$SHARE/BUNDLE" 2>/dev/null)" = "$SUFFIX" ] || { fail "BUNDLE is not '$SUFFIX'"; bad=1; }
[ "$bad" = 0 ] && pass "five helpers, each stamped '$GOOD_STAMP', and BUNDLE '$SUFFIX'"
BEFORE="$(snapshot "$T")"

echo
echo "A: no C compiler, no zig, empty aeb cache"
aebrun_nocc app/.tests.ae > "$WORK/a.log" 2>&1; rc_a=$?
AFTER="$(snapshot "$T")"
if [ "$AFTER" = "$BEFORE" ]; then pass "none of the five helpers was rebuilt, replaced or removed"; else fail "a shipped helper changed:"; diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/        /'; fi
if grep -q "could not build tools/aeb-main" "$WORK/a.log"; then
    fail "aeb tried to build aeb-main"
else
    pass "aeb went on with the prebuilt aeb-main (exit $rc_a: a build still needs a compiler for what is not shipped)"
fi

echo
echo "B: a trivial build with a compiler"
aebrun_cc app/.tests.ae > "$WORK/b.log" 2>&1; rc_b=$?
if [ "$rc_b" = 0 ] && grep -q "1/1 PASS" "$WORK/b.log"; then pass "the bash.test node passes"; else fail "the build failed (exit $rc_b)"; tail -8 "$WORK/b.log" | sed 's/^/        /'; fi
if [ "$(snapshot "$T")" = "$BEFORE" ]; then pass "the five helpers and their stamps are as installed"; else fail "a shipped helper changed:"; diff <(echo "$BEFORE") <(snapshot "$T") | sed 's/^/        /'; fi

echo
echo "C: file times scrambled"
P_C="$WORK/prefix-c"; install_bundle "$P_C"
# sources a minute ahead of every helper, as a copy that lost the times would have
when=$(( $(date +%s) + 60 ))
for f in "$P_C/share/aeb/tools/aeb-main.ae" "$P_C/share/aeb/tools/gcheckout.ae" "$P_C/share/aeb/tools/aeb-link.ae"; do
    touch -d "@$when" "$f" 2>/dev/null || touch -t "$(date -r "$when" +%Y%m%d%H%M.%S)" "$f"
done
BEFORE_C="$(snapshot "$P_C/share/aeb/tools")"
AEB_RUN="$P_C/bin/aeb" aebrun_nocc app/.tests.ae > "$WORK/c.log" 2>&1
if [ "$(snapshot "$P_C/share/aeb/tools")" = "$BEFORE_C" ]; then pass "sources newer than the helpers do not rebuild them"; else fail "a shipped helper changed:"; diff <(echo "$BEFORE_C") <(snapshot "$P_C/share/aeb/tools") | sed 's/^/        /'; fi

echo
echo "D: a helper the tree does not vouch for is rebuilt"
# gcheckout is the smallest of the five and the launcher builds it by itself.
case_rebuilds() {  # case_rebuilds NAME MUTATION-FUNCTION
    local name="$1" prefix="$WORK/prefix-d-$1" m_before m_after stamp
    install_bundle "$prefix"
    "$2" "$prefix/share/aeb"
    m_before=$(mtime "$prefix/share/aeb/tools/gcheckout")
    sleep 1
    AEB_RUN="$prefix/bin/aeb" aebrun_cc gcheckout add app/.tests.ae > "$WORK/d-$name.log" 2>&1
    m_after=$(mtime "$prefix/share/aeb/tools/gcheckout")
    stamp="$(cat "$prefix/share/aeb/tools/gcheckout.toolchain" 2>/dev/null)"
    if [ "$m_after" != "$m_before" ] && [ -x "$prefix/share/aeb/tools/gcheckout" ] && [ "${stamp#prebuilt}" = "$stamp" ] && [ -n "$stamp" ]; then
        pass "$name: rebuilt, and now stamped '$stamp'"
    else
        fail "$name: gcheckout was not rebuilt (stamp now '$stamp')"; tail -3 "$WORK/d-$name.log" | sed 's/^/        /'
    fi
}
mut_nostamp()   { rm -f "$1/tools/gcheckout.toolchain"; }
mut_otherplat() { printf 'prebuilt %s some-other-platform\n' "$TAG" > "$1/tools/gcheckout.toolchain"; }
mut_devtree()   { rm -f "$1/BUNDLE"; }
mut_otherrel()  { printf 'v9.9.9' > "$1/VERSION"; }
mut_othertc()   { printf '/nowhere/bin/aetherc (0.1.0)\n' > "$1/tools/gcheckout.toolchain"; }
case_rebuilds "no-stamp"        mut_nostamp
case_rebuilds "other-platform"  mut_otherplat
case_rebuilds "dev-tree"        mut_devtree
case_rebuilds "other-release"   mut_otherrel
case_rebuilds "other-toolchain" mut_othertc

if [ -n "${AEB_ITEST_OTHER_AETHER:-}" ]; then
    echo
    echo "E: the same bundle under another ae"
    OTHER="$(command -v "$AEB_ITEST_OTHER_AETHER")"
    P_E="$WORK/prefix-e"; install_bundle "$P_E"
    BEFORE_E="$(snapshot "$P_E/share/aeb/tools")"
    USE_AE="$OTHER" AEB_RUN="$P_E/bin/aeb" aebrun_cc app/.tests.ae > "$WORK/e.log" 2>&1; rc_e=$?
    if [ "$rc_e" = 0 ] && grep -q "1/1 PASS" "$WORK/e.log"; then pass "the build passes under $("$OTHER" --version 2>/dev/null | sed -n 1p)"; else fail "the build failed under $OTHER (exit $rc_e)"; tail -6 "$WORK/e.log" | sed 's/^/        /'; fi
    if [ "$(snapshot "$P_E/share/aeb/tools")" = "$BEFORE_E" ]; then pass "the five helpers are as installed"; else fail "a shipped helper changed"; fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "prebuilt-bundle-no-rebuild: all assertions passed"
    exit 0
fi
echo "prebuilt-bundle-no-rebuild: $FAILURES assertion(s) failed"
exit 1
