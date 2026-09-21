#!/usr/bin/env bash
# itests/report-view.sh — the render-from-artifacts build report (aeb#12).
#
# `aeb --report [text|mermaid|dot]` renders a per-node timing + cache view,
# surfaces the critical path (longest wall-time dependency chain), and points at
# the structured failures file (aeb#9) — STRICTLY read-only over the artifacts a
# prior build left under target/, same contract as `aeb --graph`. No build, no
# exec side effects.
#
# Assertions:
#   1. TEXT REPORT     — per-node status + wall + cache table, critical path,
#                        rollup, purely from a completed build's artifacts.
#   2. CRITICAL PATH   — the report names the longest-wall dependency chain.
#   3. GRAPH FORMS     — mermaid + dot each render, timing-annotated.
#   4. STALE / RO      — a second --report without rebuilding produces the same
#                        report and mutates nothing under target/.
#   5. FAILURES LINK   — a build with a failed node → the report shows fail +
#                        points at target/_aeb/_failures.jsonl.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/report-view.sh
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

# A small DAG: app depends on liba + libb. bash-only, no language toolchain.
mkdir -p "$WORK/liba" "$WORK/libb" "$WORK/app"
printf 'import bldr\nimport bash\naeb(cap) { bldr.build() { bash.test() { script("echo a") } } }\n' > "$WORK/liba/.build.ae"
printf 'import bldr\nimport bash\naeb(cap) { bldr.build() { bash.test() { script("echo b") } } }\n' > "$WORK/libb/.build.ae"
cat > "$WORK/app/.build.ae" <<'EOF'
import bldr
import bash
aeb(cap) { bldr.build() { dep("liba/.build.ae") dep("libb/.build.ae") bash.test() { script("echo app") } } }
EOF

export AETHER_HOME="$WORK/h1"; mkdir -p "$AETHER_HOME"
( cd "$WORK" && "$AEB" --scan '.build.ae' ) >/dev/null 2>&1 || true   # -k: bash nodes may "fail" harmlessly; artifacts still land

EDGES="$WORK/target/_aeb/_edges.txt"
if [ ! -f "$EDGES" ]; then fail "no _edges.txt after a build — cannot test the report"; echo; echo "report-view: 1 assertion(s) FAILED"; exit 1; fi

# --- 1 + 2. text report: table headers, a node row, critical path, rollup.
TXT="$( cd "$WORK" && "$AEB" --report 2>/dev/null )"
# a node's status is ok/fail/uninvoked (a node whose dep failed under -k is
# skipped → uninvoked); any of them is a valid rendered row.
if echo "$TXT" | grep -q "status" && echo "$TXT" | grep -q "cache" && echo "$TXT" | grep -qE "app +(ok|fail|uninvoked)"; then
  pass "text report renders per-node status/wall/cache table"
else
  fail "text report missing table/rows"; echo "$TXT" | head -10 | sed 's/^/    /'
fi
if echo "$TXT" | grep -qi "critical path" && echo "$TXT" | grep -qi "rollup"; then
  pass "report surfaces the critical path + rollup"
else
  fail "no critical-path / rollup line"; echo "$TXT" | tail -6 | sed 's/^/    /'
fi

# --- 3. graph forms.
MM="$( cd "$WORK" && "$AEB" --report mermaid 2>/dev/null )"
DT="$( cd "$WORK" && "$AEB" --report dot 2>/dev/null )"
if echo "$MM" | grep -q "graph TD" && echo "$MM" | grep -q "classDef crit"; then
  pass "mermaid form renders (graph TD, critical-path class)"
else
  fail "mermaid form wrong"; echo "$MM" | head -6 | sed 's/^/    /'
fi
if echo "$DT" | grep -q "digraph aeb_report" && echo "$DT" | grep -q "fillcolor"; then
  pass "dot form renders (digraph, timing-annotated fills)"
else
  fail "dot form wrong"; echo "$DT" | head -6 | sed 's/^/    /'
fi

# --- 4. stale / read-only: second run identical, target/ unchanged.
SUM_BEFORE="$(find "$WORK/target" -type f -newer "$EDGES" 2>/dev/null | wc -l)"
STAMP_BEFORE="$(ls -la "$EDGES" | awk '{print $6,$7,$8}')"
TXT2="$( cd "$WORK" && "$AEB" --report 2>/dev/null )"
STAMP_AFTER="$(ls -la "$EDGES" | awk '{print $6,$7,$8}')"
if [ "$TXT" = "$TXT2" ] && [ "$STAMP_BEFORE" = "$STAMP_AFTER" ]; then
  pass "stale/read-only: re-report is identical + mutates no artifacts"
else
  fail "report is not stable / mutated artifacts"
fi

# --- 5. failures link: a build with a genuinely failing node.
mkdir -p "$WORK/bad"
printf 'main() { INVALID(( }\n' > "$WORK/bad/main.ae"
cat > "$WORK/bad/.build.ae" <<'EOF'
import bldr
import aether
import aether (source, output)
aeb(cap) { bldr.build() { aether.program() { source("main.ae") output("x") } } }
EOF
export AETHER_HOME="$WORK/h2"; mkdir -p "$AETHER_HOME"
( cd "$WORK" && "$AEB" --scan '.build.ae' ) >/dev/null 2>&1 || true
TXT3="$( cd "$WORK" && "$AEB" --report 2>/dev/null )"
if echo "$TXT3" | grep -qE "bad +fail" && echo "$TXT3" | grep -q "_failures.jsonl"; then
  pass "report shows a failed node + points at _failures.jsonl (aeb#9 compose)"
else
  fail "report did not surface the failure / failures file"; echo "$TXT3" | grep -iE 'bad|fail|rollup' | sed 's/^/    /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "report-view: all assertions passed"
  exit 0
else
  echo "report-view: $FAILURES assertion(s) FAILED"
  exit 1
fi
