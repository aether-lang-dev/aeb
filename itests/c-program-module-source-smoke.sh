#!/usr/bin/env bash
# itests/c-program-module-source-smoke.sh — c.program follows the modules of
# its aether_source()s the way `ae build` does: the C they ship (`@source`,
# aether #2125), the headers they declare (`@c_include`, aether #1986) and
# the libraries they link (`@link`).
#
# aetherc writes all three into the generated C's header (`// aether-source:`,
# `// aether-include:`, `// aether-link:`). lib/aether's manual link already
# read the source and link lines (module-source-c-smoke.sh); c.program read
# none, so a C program whose Aether half imported such a module (sae with
# contrib.quickjs) linked with undefined symbols unless its .build.ae
# restated the module's C with sources().
#
# Assertions:
#   1. COLD     — a c.program importing a module that ships C, includes a
#                 header from its own dir and links a library builds with no
#                 sources() for that C, and runs.
#   2. WARM     — an unchanged rebuild does not relink; the binary still runs.
#   3. TOUCHED  — editing ONLY the module's shipped C (not any .ae) relinks,
#                 and the binary reflects the edit.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/c-program-module-source-smoke.sh
# Exit code: 0 if every assertion passed (or skipped); 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
export AETHER

if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi
if ! command -v "$AETHER" >/dev/null 2>&1; then echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AETHER_CACHE_DIR="$WORK/aecache"; mkdir -p "$AETHER_CACHE_DIR"

# --- Fixture: shim/ is a module shipping shim.c, which includes shim_k.h
#     (found through the module's @c_include) and calls shimk_two() from a
#     library the fixture builds (found through the module's @link; a
#     toolchain-managed library such as -lz would be filtered, as ae.c does).
APP="$WORK/app"; mkdir -p "$APP/shim" "$APP/lib"
CC_="${CC:-cc}"
cat > "$APP/lib/shimk.c" <<'EOF'
int shimk_two(void) { return 2; }
EOF
( cd "$APP/lib" && "$CC_" -c shimk.c -o shimk.o && ar rcs libshimk.a shimk.o ) || { echo "error: cannot build the fixture library" >&2; exit 1; }
cat > "$APP/shim/shim_k.h" <<'EOF'
#define SHIM_K 40
EOF
cat > "$APP/shim/shim.c" <<'EOF'
#include "shim_k.h"
int shimk_two(void);
int shim_answer(void) { return SHIM_K + shimk_two(); }
EOF
cat > "$APP/shim/module.ae" <<EOF
@source("shim.c")
@c_include("shim_k.h")
@link("-L$APP/lib -lshimk")
extern shim_answer() -> int
answer() -> int { return shim_answer() }
EOF
cat > "$APP/half.ae" <<'EOF'
import shim
import std.string
report() { println(string.from_int(shim.answer())) }
EOF
cat > "$APP/main.c" <<'EOF'
void report(void);
int main(void) { report(); return 0; }
EOF
# No sources("shim/shim.c"), no include("shim"), no link_flag("-lshimk"): the
# whole point is that the module says so itself.
cat > "$APP/.build.ae" <<'EOF'
import bldr
import c
import c (sources, aether_source, output_file)
aeb(cap) { bldr.build() { c.program() { aether_source("half.ae") sources("main.c") output_file("prog") } } }
EOF

# @c_include needs an Aether that emits `// aether-include:`; skip on older.
PROBE="$WORK/probe"; mkdir -p "$PROBE"
cp -R "$APP/shim" "$APP/half.ae" "$PROBE/"
AETHERC="${AETHERC:-$(dirname "$(command -v "$AETHER")")/aetherc}"
[ -x "$AETHERC" ] || AETHERC=aetherc
if ! ( cd "$PROBE" && "$AETHERC" --emit=lib half.ae out.c >/dev/null 2>&1 && grep -q '^// aether-include:' out.c && grep -q '^// aether-source:' out.c ); then
  echo "  SKIP: this toolchain does not emit '// aether-include:'/'// aether-source:'"
  echo
  echo "c-program-module-source-smoke: SKIPPED (toolchain too old)"
  exit 0
fi

find_bin() { find "$1" -name "$2" -type f -perm -u+x 2>/dev/null | head -1; }

# --- 1. COLD
OUT="$( cd "$APP" && "$AEB" .build.ae 2>&1 )"
BIN="$(find_bin "$APP/target" prog)"
if [ -n "$BIN" ] && [ "$("$BIN" 2>/dev/null)" = "42" ]; then
  pass "cold: shipped C, its header and its library followed; prog prints 42"
else
  fail "cold: prog did not build/run (expected 42)"
  echo "$OUT" | grep -iE 'undefined|failed|error|not found' | head -6 | sed 's/^/    /'
fi

# --- 2. WARM: nothing changed, so the binary is not relinked (aeb's node
#     cache or c.program's own check may be what skips it).
mt() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
sleep 1
M1="$(mt "$BIN")"
OUT2="$( cd "$APP" && "$AEB" .build.ae 2>&1 )"
if [ "$(mt "$BIN")" = "$M1" ] && [ "$("$BIN" 2>/dev/null)" = "42" ]; then
  pass "warm: unchanged rebuild did not relink, prog still prints 42"
else
  fail "warm: expected no relink and 42"
  echo "$OUT2" | tail -4 | sed 's/^/    /'
fi

# --- 3. TOUCHED: only the shipped C changes.
sleep 1
sed -i.bak 's/SHIM_K + /SHIM_K + 1 + /' "$APP/shim/shim.c" && rm -f "$APP/shim/shim.c.bak"
OUT3="$( cd "$APP" && "$AEB" .build.ae 2>&1 )"
if [ "$("$BIN" 2>/dev/null)" = "43" ]; then
  pass "touched: editing only the module's C relinked; prog prints 43"
else
  fail "touched: expected 43 after editing shim.c, got '$("$BIN" 2>/dev/null)'"
  echo "$OUT3" | tail -4 | sed 's/^/    /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "c-program-module-source-smoke: PASS"
  exit 0
fi
echo "c-program-module-source-smoke: $FAILURES FAILURE(S)"
exit 1
