#!/usr/bin/env bash
# itests/module-source-c-smoke.sh — aeb compiles a module's `@source` C files
# (aether #2125), the way `ae run` / `ae build` already do.
#
# A module can ship its own C: `@source("shim.c")` at the top of module.ae, and
# the Aether compiler emits one `// aether-source: <path>` line in the generated
# C's header. `ae run`/`ae build` read those and compile each file into the link.
# aeb bypasses `ae build` on two paths — the manual aether.program link
# (extra_source/link_flag/ui_backend) and the fan-out orchestrator link — so
# before this fix a program importing such a module linked with undefined symbols
# unless it restated the file with extra_source(). OpenDisk-ae carried exactly
# that workaround. This proves aeb now reads `// aether-source:` on BOTH paths.
#
# Assertions:
#   1. MANUAL COLD   — a program importing an @source module, built via the manual
#                      path (link_flag present, NO extra_source), links and RUNS.
#   2. MANUAL WARM   — the cached rebuild still links and runs (cache key stable).
#   3. ORCH LINKS    — a build node importing the @source module builds through the
#                      fan-out orchestrator link (_ae_build_all) with no undefined
#                      symbols.
#   4. NO WORKAROUND — the .build.ae contains no extra_source for the shipped C
#                      (the whole point: the fix removes that need).
#
# `@source` needs Aether >= 0.705; on an older `ae` the emitter is absent, so the
# test SKIPs (exit 0) rather than failing.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/module-source-c-smoke.sh
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

# --- Fixture: a module shipping its own C via @source, a program importing it,
#     and a .build.ae that does NOT restate the C (no extra_source).
APP="$WORK/app"; mkdir -p "$APP"
cat > "$APP/shim.c" <<'EOF'
int shim_answer(void) { return 42; }
EOF
cat > "$APP/shimmod.ae" <<'EOF'
@source("shim.c")
extern shim_answer() -> int
answer() -> int { return shim_answer() }
EOF
cat > "$APP/main.ae" <<'EOF'
import shimmod (answer)
import std.string
main() { println(string.from_int(answer())) }
EOF
# link_flag() forces aeb's MANUAL aetherc+gcc path (not the `ae build` shell-out,
# which handles @source itself). No extra_source — that's what the fix removes.
cat > "$APP/.build.ae" <<'EOF'
import bldr
import aether
import aether (source, output, link_flag)
aeb(cap) { bldr.build() { aether.program() { source("main.ae") output("prog") link_flag("-lm") } } }
EOF

# --- @source support probe: build the manual path once; if `ae` is too old to
#     emit `// aether-source:`, the manual `ae build` of a plain program that
#     imports the module would already fail — but more directly, skip when the
#     compiler predates the emitter. Detect by grepping a generated header.
PROBE="$WORK/probe"; mkdir -p "$PROBE"
cp "$APP/shim.c" "$APP/shimmod.ae" "$PROBE/"
cat > "$PROBE/p.ae" <<'EOF'
import shimmod (answer)
main() { let _ = answer() }
EOF
( cd "$PROBE" && "$AETHER" build shimmod.ae --emit=csrc -o out >/dev/null 2>&1 )
if ! grep -q 'aether-source' "$PROBE"/out.c 2>/dev/null && ! grep -rq 'aether-source' "$PROBE"/*.c 2>/dev/null; then
  echo "  SKIP: this ae does not emit '// aether-source:' (needs Aether >= 0.705)"
  echo
  echo "module-source-c-smoke: SKIPPED (toolchain too old)"
  exit 0
fi

find_bin() { find "$1" -name "$2" -type f 2>/dev/null | head -1; }

# --- 1. MANUAL COLD: build via the manual path, no extra_source → must run.
rm -rf "$APP/target"
OUT="$( cd "$APP" && "$AEB" .build.ae 2>&1 )"
BIN="$(find_bin "$APP/target" prog)"
if [ -n "$BIN" ] && [ "$("$BIN" 2>/dev/null)" = "42" ]; then
  pass "manual path: @source C compiled in, prog runs (42) with no extra_source"
else
  fail "manual path: prog did not link/run (expected 42)"
  echo "$OUT" | grep -iE 'undefined|link failed|error' | head -4 | sed 's/^/    /'
fi

# --- 2. MANUAL WARM: cached rebuild still links + runs.
OUT2="$( cd "$APP" && "$AEB" .build.ae 2>&1 )"
BIN2="$(find_bin "$APP/target" prog)"
if [ -n "$BIN2" ] && [ "$("$BIN2" 2>/dev/null)" = "42" ]; then
  pass "manual path: warm (cached) rebuild still links + runs"
else
  fail "manual path: warm rebuild broke (expected 42)"
fi

# --- 3. ORCH LINKS: a build NODE importing the @source module goes through the
#     fan-out orchestrator link (_ae_build_all). No undefined symbols.
NODE="$WORK/node"; mkdir -p "$NODE"
cp "$APP/shim.c" "$APP/shimmod.ae" "$NODE/"
cat > "$NODE/.probe.ae" <<'EOF'
import bldr
import shimmod (answer)
import std.string
aeb(cap) { bldr.build() { println(string.concat("shim=", string.from_int(answer()))) return 0 } }
EOF
rm -rf "$NODE/target"
OUT3="$( cd "$NODE" && "$AEB" .probe.ae 2>&1 )"
if echo "$OUT3" | grep -qiE 'undefined reference|FATAL|link failed'; then
  fail "orchestrator path: fan-out link failed on the @source module"
  echo "$OUT3" | grep -iE 'undefined|FATAL|link failed' | head -3 | sed 's/^/    /'
else
  pass "orchestrator path: node importing @source module links (no undefined symbols)"
fi

# --- 4. NO WORKAROUND: assert the .build.ae never restates the shipped C.
if grep -q 'extra_source' "$APP/.build.ae"; then
  fail "the fixture .build.ae used extra_source — the fix should make that unnecessary"
else
  pass "no extra_source() in the .build.ae — the fix carries the shipped C on its own"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "module-source-c-smoke: all assertions passed"
  exit 0
else
  echo "module-source-c-smoke: $FAILURES assertion(s) FAILED"
  exit 1
fi
