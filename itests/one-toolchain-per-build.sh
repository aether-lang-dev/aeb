#!/usr/bin/env bash
# itests/one-toolchain-per-build.sh — one aeb invocation builds with ONE Aether
# toolchain: whatever `ae`/`aetherc` compiles a program, its runtime, stdlib
# and headers come from that same install.
#
# The bug this guards (2026-11-20, selaenium on ae-x64): with AETHER unset and
# aeb's private toolchain (AETHER_FETCH, in ~/.cache/aeb/toolchain) already
# fetched by an earlier run, the trampoline built the orchestrator with that
# private 0.898.0 aetherc even though a newer `ae` was on PATH, and the
# inherited AETHER_HOME (naming the newer install) made that aetherc compile
# the NEWER stdlib, which was then linked against 0.898.0's libaether.a:
#   undefined reference to `dir_list_error'
#
# Two real releases are used: OLD is aeb's private copy, NEW is a newer release
# ($AEB_ITEST_NEW_AETHER, default 0.939.0), both installed with aeb's own get.sh.
# OLD is the floor, AETHER_PIN (the oldest release aeb supports), not
# AETHER_FETCH: the fetched copy is normally the latest release, and the test
# needs a private copy OLDER than the one on PATH. The aeb copy the test builds
# gets AETHER_FETCH set to OLD, so the pinned toolchain is OLD there.
# So the test does not hang on which symbols a given pair of
# releases happens to differ by, NEW is staged with one addition: a stdlib
# module std.aebitest whose function calls a C symbol that only NEW's
# libaether.a defines. A build file and a program both call it. Built with NEW
# throughout, it links and prints 7; compiled against NEW's stdlib and linked
# with OLD's runtime, it is the original undefined reference.
#
#   A. AETHER unset, NEW on PATH, AETHER_HOME naming NEW, OLD in aeb's cache:
#      the build links and runs (it failed on aeb before this fix).
#   B. The same with no AETHER_HOME.
#   C. `aeb --toolchain` names NEW's aetherc in that default.
#   D. AEB_TOOLCHAIN=pinned with the same environment: the build is OLD's
#      throughout (OLD's stdlib has no std.aebitest, so the build file does
#      not compile; it never reaches a link against another runtime), and a
#      project that does not use it builds.
#   E. AETHER naming OLD's ae while AETHER_HOME names NEW: refused, exit 2,
#      the message naming both versions.
#   F. The helpers aeb builds for itself are stamped with the toolchain that
#      built them and rebuilt when it changes (D after A), and not rebuilt when
#      it does not (D again).
#
# Usage: ./itests/one-toolchain-per-build.sh
#   AEB_TREE=<aeb checkout>        the aeb to test (default: this one; it is
#                                  copied, so its own helpers are not touched)
#   AEB_ITEST_NEW_AETHER=<x.y.z>   the newer release (default 0.939.0)
#   AEB_ITEST_TOOLCHAINS=<dir>     keep the downloaded releases here between
#                                  runs (<dir>/<version>/bin/ae)
# Exit: 0 if every assertion passed or the test was skipped (no network, a
# platform with no published release); 1 otherwise. POSIX hosts only.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB_TREE="${AEB_TREE:-$REPO_ROOT}"
NEW_V="${AEB_ITEST_NEW_AETHER:-0.939.0}"
OLD_V="$(grep -v '^#' "$AEB_TREE/AETHER_PIN" 2>/dev/null | tr -d '[:space:]')"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "  SKIP: Windows"; exit 0 ;; esac
[ -n "$OLD_V" ] || { echo "error: cannot read $AEB_TREE/AETHER_PIN" >&2; exit 1; }
if [ "$OLD_V" = "$NEW_V" ]; then
    echo "  SKIP: AETHER_PIN is $OLD_V, the same as the newer release asked for; set AEB_ITEST_NEW_AETHER"
    exit 0
fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aeb_onetc.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT INT TERM
TCS="${AEB_ITEST_TOOLCHAINS:-$WORK/tc}"
mkdir -p "$TCS"

echo "[one-toolchain-per-build] OLD $OLD_V (AETHER_PIN), NEW $NEW_V"

# --- the two releases, from aeb's own get.sh ---------------------------------
install_ae() {
    [ -x "$TCS/$1/bin/ae" ] && return 0
    ( AEBGET_SOURCE_ONLY=1; . "$REPO_ROOT/get.sh"; PREFIX="$TCS/$1" aebget_install_ae_binary "$1" ) >"$WORK/get-$1.log" 2>&1
    [ -x "$TCS/$1/bin/ae" ]
}
for v in "$OLD_V" "$NEW_V"; do
    if ! install_ae "$v"; then
        echo "  SKIP: could not install aether $v (offline, or no release asset for this platform):"
        tail -3 "$WORK/get-$v.log" | sed 's/^/    /'
        exit 0
    fi
done
OLD="$TCS/$OLD_V"

# --- NEW, staged with a runtime symbol and a stdlib module only it has -------
NEW="$WORK/new"
cp -R "$TCS/$NEW_V" "$NEW"
LIBA="$(find "$NEW/lib" -name libaether.a | head -1)"
STD="$NEW/share/aether/std"
if [ -z "$LIBA" ] || [ ! -d "$STD" ]; then echo "error: unexpected layout in the $NEW_V release" >&2; exit 1; fi
printf 'int aeb_itest_new_runtime(void) { return 7; }\n' > "$WORK/marker.c"
CC_="${CC:-cc}"
( cd "$WORK" && $CC_ -c marker.c -o marker.o ) || { echo "error: no C compiler to stage the marker" >&2; exit 1; }
ar rs "$LIBA" "$WORK/marker.o" >/dev/null 2>&1 || { echo "error: ar failed" >&2; exit 1; }
mkdir -p "$STD/aebitest"
cat > "$STD/aebitest/module.ae" <<'EOF'
// Staged by aeb's itests/one-toolchain-per-build.sh: only this install's
// libaether.a defines aeb_itest_new_runtime.
extern aeb_itest_new_runtime() -> int
marker() -> int {
    return aeb_itest_new_runtime()
}
EOF

# --- a copy of aeb, no helpers built in it ------------------------------------
HOME_COPY="$WORK/aeb"
mkdir -p "$HOME_COPY/tools"
cp "$AEB_TREE/aeb" "$HOME_COPY/aeb"
cp -R "$AEB_TREE/lib" "$HOME_COPY/lib"
( cd "$AEB_TREE/tools" && for e in *; do
    if [ -d "$e" ]; then cp -R "$e" "$HOME_COPY/tools/$e"
    else case "$e" in *.ae|*.sh|*.py) cp "$e" "$HOME_COPY/tools/$e" ;; esac
    fi
  done )
for f in AETHER_PIN VERSION; do
    [ -f "$AEB_TREE/$f" ] && cp "$AEB_TREE/$f" "$HOME_COPY/$f"
done
# the private (pinned) toolchain of this copy is OLD, whatever AETHER_FETCH says
printf '%s\n' "$OLD_V" > "$HOME_COPY/AETHER_FETCH"
AEB="$HOME_COPY/aeb"
T="$HOME_COPY/tools"

# aeb's private copy of OLD, already "fetched" by an earlier run.
CACHE="$WORK/cache"
mkdir -p "$CACHE/toolchain"
cp -R "$OLD" "$CACHE/toolchain/aether-$OLD_V"

# --- the projects ---------------------------------------------------------------
mk_proj() {  # mk_proj DIR USES_MARKER
    mkdir -p "$1/app"
    ( cd "$1" && git init -q . 2>/dev/null )
    if [ "$2" = 1 ]; then
        cat > "$1/app/main.ae" <<'EOF'
import std.aebitest
main() {
    println("marker ${aebitest.marker()}")
    return 0
}
EOF
        cat > "$1/app/.build.ae" <<'EOF'
import bldr
import aether
import std.aebitest

aeb(cap) {
    if aebitest.marker() != 7 { println("build file: wrong marker") }
    bldr.build() {
        aether.program() {
            source("main.ae")
        }
    }
}
EOF
    else
        printf 'main() {\n    println("plain ok")\n    return 0\n}\n' > "$1/app/main.ae"
        cat > "$1/app/.build.ae" <<'EOF'
import bldr
import aether

aeb(cap) {
    bldr.build() {
        aether.program() {
            source("main.ae")
        }
    }
}
EOF
    fi
}
mk_proj "$WORK/marked" 1
mk_proj "$WORK/plain" 0

# aebrun DIR [VAR=value...] -- ARGS : aeb in DIR with a clean environment:
# NEW first on PATH, aeb's cache and Aether's cache under $WORK, AETHER unset
# unless given.
aebrun() {
    local dir="$1"; shift
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    ( cd "$dir" && env -i HOME="$HOME" PATH="$NEW/bin:/usr/bin:/bin" TMPDIR="$WORK" \
        AEB_CACHE_DIR="$CACHE" AETHER_CACHE_DIR="$WORK/aecache" XDG_CACHE_HOME="$WORK/xdg" \
        ${CC:+CC="$CC"} "${envs[@]+"${envs[@]}"}" bash "$AEB" "$@" )
}
# run_prog DIR — run the program aether.program built in DIR's app node.
run_prog() {
    local b
    b="$(find "$1/target/build/app/bin" -type f -perm -u+x 2>/dev/null | head -1)"
    [ -n "$b" ] && "$b"
}
mtime() { if stat -f %m "$1" >/dev/null 2>&1; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }

echo
echo "A: AETHER unset, NEW on PATH and in AETHER_HOME, OLD in aeb's cache"
aebrun "$WORK/marked" AETHER_HOME="$NEW" -- app/.build.ae > "$WORK/a.log" 2>&1; rc=$?
if grep -q "undefined reference to .*aeb_itest_new_runtime\|aeb_itest_new_runtime.*undefined\|Undefined symbols" "$WORK/a.log"; then
    fail "NEW's stdlib was linked against another runtime (the reported bug)"
    grep -m2 "aeb_itest_new_runtime\|Undefined" "$WORK/a.log" | sed 's/^/    /'
elif [ "$rc" -eq 0 ] && run_prog "$WORK/marked" | grep -q "^marker 7"; then
    pass "the build file and the program are both NEW's, compiled and linked"
else
    fail "unexpected outcome (rc=$rc)"; tail -8 "$WORK/a.log" | sed 's/^/    /'
fi
m_main_new=$(mtime "$T/aeb-main" 2>/dev/null || echo 0)
stamp_a="$(cat "$T/aeb-main.toolchain" 2>/dev/null)"

echo
echo "B: the same with no AETHER_HOME"
rm -rf "$WORK/marked/target"
aebrun "$WORK/marked" -- app/.build.ae > "$WORK/b.log" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
    pass "builds with the ae on PATH, not the cached private copy"
else
    fail "rc=$rc"; tail -6 "$WORK/b.log" | sed 's/^/    /'
fi

echo
echo "C: aeb --toolchain"
aebrun "$WORK/marked" AETHER_HOME="$NEW" -- --toolchain > "$WORK/c.log" 2>&1
if grep -q "^aetherc  $NEW/bin/aetherc ($NEW_V)" "$WORK/c.log" && grep -q "^aeb toolchain: the ae on PATH" "$WORK/c.log"; then
    pass "names the ae on PATH and NEW's aetherc"
else
    fail "does not name NEW"; sed 's/^/    /' "$WORK/c.log"
fi

echo
echo "D: AEB_TOOLCHAIN=pinned, same environment"
aebrun "$WORK/marked" AETHER_HOME="$NEW" AEB_TOOLCHAIN=pinned -- --toolchain > "$WORK/d0.log" 2>&1
if grep -q "^aetherc  $CACHE/toolchain/aether-$OLD_V/bin/aetherc ($OLD_V)" "$WORK/d0.log"; then
    pass "--toolchain names aeb's pinned $OLD_V, whatever AETHER_HOME says"
else
    fail "--toolchain does not name the pinned copy"; sed 's/^/    /' "$WORK/d0.log"
fi
rm -rf "$WORK/marked/target"
aebrun "$WORK/marked" AETHER_HOME="$NEW" AEB_TOOLCHAIN=pinned -- app/.build.ae > "$WORK/d1.log" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q "aeb_itest_new_runtime" "$WORK/d1.log" && grep -q "aebitest" "$WORK/d1.log"; then
    pass "OLD's stdlib throughout: std.aebitest is not found at compile time, no link against another runtime"
else
    fail "rc=$rc; expected a compile-time miss of std.aebitest"; grep -m4 "aebitest\|error" "$WORK/d1.log" | sed 's/^/    /'
fi
aebrun "$WORK/plain" AETHER_HOME="$NEW" AEB_TOOLCHAIN=pinned -- app/.build.ae > "$WORK/d2.log" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && run_prog "$WORK/plain" | grep -q "plain ok"; then
    pass "a project that does not need NEW builds and runs on the pinned $OLD_V"
else
    fail "pinned build of a plain project: rc=$rc"; tail -6 "$WORK/d2.log" | sed 's/^/    /'
fi

echo
echo "E: AETHER=OLD's ae while AETHER_HOME names NEW"
aebrun "$WORK/plain" AETHER="$OLD/bin/ae" AETHER_HOME="$NEW" -- app/.build.ae > "$WORK/e.log" 2>&1; rc=$?
if [ "$rc" -eq 2 ] && grep -q "$OLD_V" "$WORK/e.log" && grep -q "$NEW_V" "$WORK/e.log" && grep -q "refusing to mix" "$WORK/e.log"; then
    pass "refused, naming both $OLD_V and $NEW_V"
else
    fail "rc=$rc; expected exit 2 naming both versions"; tail -6 "$WORK/e.log" | sed 's/^/    /'
fi

echo
echo "F: helper stamps"
stamp_d="$(cat "$T/aeb-main.toolchain" 2>/dev/null)"
m_main_old=$(mtime "$T/aeb-main" 2>/dev/null || echo 0)
case "$stamp_a" in *"($NEW_V)") pass "built with NEW, aeb-main is stamped NEW: $stamp_a" ;;
    *) fail "aeb-main stamp after A: '${stamp_a}'" ;; esac
case "$stamp_d" in *"($OLD_V)") pass "pinned, aeb-main is rebuilt and stamped OLD: $stamp_d" ;;
    *) fail "aeb-main stamp after D: '${stamp_d}'" ;; esac
if [ "$m_main_old" != "$m_main_new" ]; then pass "aeb-main was rebuilt when the toolchain changed"; else fail "aeb-main was not rebuilt for the other toolchain"; fi
m_link=$(mtime "$T/aeb-link"); m_tr=$(mtime "$T/transform-ae")
sleep 1
aebrun "$WORK/plain" AETHER_HOME="$NEW" AEB_TOOLCHAIN=pinned -- app/.build.ae > "$WORK/f.log" 2>&1
if [ "$(mtime "$T/aeb-main")" = "$m_main_old" ] && [ "$(mtime "$T/aeb-link")" = "$m_link" ] \
   && [ "$(mtime "$T/transform-ae")" = "$m_tr" ]; then
    pass "the same toolchain again rebuilds no helper"
else
    fail "a helper was rebuilt with the toolchain unchanged"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "one-toolchain-per-build: all assertions passed"
    exit 0
fi
echo "one-toolchain-per-build: $FAILURES assertion(s) FAILED"
exit 1
