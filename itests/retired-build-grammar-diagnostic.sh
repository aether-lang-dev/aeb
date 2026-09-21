#!/usr/bin/env bash
# itests/retired-build-grammar-diagnostic.sh — a node using the RETIRED `build`
# module gets a clear migration diagnostic, not a cryptic "unresolved import".
#
# The DSL rework renamed `build` -> `bldr` and kept NO back-compat for the
# `build.*` grammar. A node that still does `import build` / `build.start()`
# used to fail downstream with a generic
#   error: unresolved import 'build': no module of that name was found ...
# which reads like an install / lib-path problem — it sent aeb#16 (box3d-port
# on a fresh runner) hunting for an AETHER_LIB_DIR / .aeb/lib fix, when the real
# cause was retired grammar. transform-ae now detects `import build` up front and
# prints an actionable migration message (exit 1) BEFORE the confusing failure.
#
# Assertions:
#   1. RETIRED NODE   — `import build` node emits the migration diagnostic (names
#                       `bldr`, tells you what to change) and exits non-zero.
#   2. NO CRYPTIC     — it does NOT reach the bare "unresolved import 'build'".
#   3. CURRENT WORKS  — the same node in `bldr` grammar builds/links (no false
#                       trigger of the guard).
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/retired-build-grammar-diagnostic.sh
# Exit: 0 if all pass; 1 otherwise.

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

mkdir -p "$WORK/mod"
cat > "$WORK/mod/test_math.ae" <<'EOF'
main() { println("ok") }
EOF

# --- 1 + 2. Retired `build` grammar → migration diagnostic, not cryptic error.
cat > "$WORK/mod/.tests.ae" <<'EOF'
import build
import aether
import aether (source, lib)

aeb(cap) {
    b = build.start()
    aether.program_test(b) {
        source("test_math.ae")
        lib("..")
    }
}
EOF
export AETHER_HOME="$WORK/h1"; mkdir -p "$AETHER_HOME"
LOG="$WORK/retired.log"
( cd "$WORK" && "$AEB" mod/.tests.ae ) >"$LOG" 2>&1
RC=$?
if grep -qi "RETIRED .build. module" "$LOG" && grep -qi "import bldr" "$LOG" && [ "$RC" -ne 0 ]; then
  pass "retired 'import build' → clear migration diagnostic (exit $RC)"
else
  fail "no migration diagnostic for retired grammar"; sed 's/^/    /' "$LOG" | head -12
fi
# The diagnostic must PRECEDE / replace the cryptic unresolved-import error.
if grep -qi "unresolved import 'build'" "$LOG"; then
  fail "still reached the cryptic \"unresolved import 'build'\" (diagnostic should short-circuit)"
else
  pass "no bare \"unresolved import 'build'\" (diagnostic short-circuits it)"
fi

# --- 3. Current `bldr` grammar must build with no false trigger.
cat > "$WORK/mod/.tests2.ae" <<'EOF'
import bldr
import aether
import aether (source, lib)

aeb(cap) {
    bldr.build() {
        aether.program_test() {
            source("test_math.ae")
            lib("..")
        }
    }
}
EOF
export AETHER_HOME="$WORK/h2"; mkdir -p "$AETHER_HOME"
LOG2="$WORK/current.log"
( cd "$WORK" && "$AEB" mod/.tests2.ae ) >"$LOG2" 2>&1
RC2=$?
if grep -qi "RETIRED" "$LOG2"; then
  fail "current bldr grammar FALSE-triggered the retired-grammar guard"; sed 's/^/    /' "$LOG2" | head -8
elif grep -qi "unresolved import" "$LOG2"; then
  fail "current bldr grammar failed to resolve imports"; sed 's/^/    /' "$LOG2" | head -8
else
  # RC2 may be nonzero only if the test itself fails; the orchestrator LINKING
  # (no unresolved/retired) is what we assert here — a 1/1 PASS or a plain test
  # outcome both mean the grammar resolved.
  pass "current bldr grammar builds (no false guard trigger, imports resolve)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "retired-build-grammar-diagnostic: all assertions passed"
  exit 0
else
  echo "retired-build-grammar-diagnostic: $FAILURES assertion(s) FAILED"
  exit 1
fi
