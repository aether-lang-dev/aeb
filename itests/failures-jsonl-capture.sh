#!/usr/bin/env bash
# itests/failures-jsonl-capture.sh — structured node-failure capture (aeb#9).
#
# On any node failure the driver appends a JSON object to
# target/_aeb/_failures.jsonl (label/node/tag/rc/phase/stderr_tail), reset at
# build start, one line per failed node, across all three engines (make -jN,
# AEB_SCHED=native, AEB_JOBS=1 sequential). A single machine-readable place for a
# CI system / dashboard / follow-up aeb to read "what failed and why".
#
# Assertions:
#   1. FAILURE CAPTURED  — a failing node writes one valid-JSON line with
#                          label/node/tag/rc and a non-empty stderr_tail.
#   2. RESET AT START    — a second run with a different failure set replaces the
#                          file (not appended to the prior run's lines).
#   3. AEB_JOBS=1         — the sequential engine writes the same record.
#   4. SUCCESS = EMPTY    — a clean build leaves the file empty (no stale lines).
#   5. TELEMETRY POINTS   — the run output references the file on failure.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/failures-jsonl-capture.sh
# Exit: 0 if all pass; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
export AETHER
if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi
if ! command -v "$AETHER" >/dev/null 2>&1; then echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; fi
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then echo "error: python3 needed to validate JSON" >&2; exit 1; fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A build node that FAILS to compile (invalid Aether) — deterministic, no
# language toolchain needed beyond ae/aetherc, and gives a real stderr_tail.
mk_bad() {
  local dir="$1"
  mkdir -p "$WORK/$dir"
  printf 'main() { NOT valid aether (( }\n' > "$WORK/$dir/main.ae"
  cat > "$WORK/$dir/.build.ae" <<'EOF'
import bldr
import aether
import aether (source, output)
aeb(cap) { bldr.build() { aether.program() { source("main.ae") output("x") } } }
EOF
}
mk_good() {
  local dir="$1"
  mkdir -p "$WORK/$dir"
  printf 'main() { println("ok") }\n' > "$WORK/$dir/main.ae"
  cat > "$WORK/$dir/.build.ae" <<'EOF'
import bldr
import aether
import aether (source, output)
aeb(cap) { bldr.build() { aether.program() { source("main.ae") output("ok") } } }
EOF
}

run() {  # run() <extra-env> ; scans WORK
  ( cd "$WORK" && env AETHER_HOME="$(mktemp -d)" $1 "$AEB" --scan '.build.ae' )
}

FJ="$WORK/target/_aeb/_failures.jsonl"

# --- 1 + 5. A failing node writes a valid record; telemetry points at the file.
mk_bad badA
OUT="$(run '' 2>&1 || true)"
if [ -f "$FJ" ] && "$PY" - "$FJ" <<'PY'
import sys,json
lines=[l for l in open(sys.argv[1]) if l.strip()]
assert lines, "empty"
d=json.loads(lines[0])
for k in ("label","node","tag","rc","phase","stderr_tail"): assert k in d, k
assert d["node"].endswith(".build.ae"), d["node"]
assert d["tag"]=="build", d["tag"]
assert str(d["rc"])!="0", d["rc"]
assert len(d["stderr_tail"])>0, "empty tail"
PY
then
  pass "failing node → valid JSON record (label/node/tag/rc/phase/stderr_tail)"
else
  fail "no valid _failures.jsonl record for a failing node"; echo "$OUT" | tail -6 | sed 's/^/    /'; [ -f "$FJ" ] && sed 's/^/    /' "$FJ"
fi
if echo "$OUT" | grep -q "_failures.jsonl"; then
  pass "telemetry output points at the failures file"
else
  fail "telemetry did not reference _failures.jsonl"; echo "$OUT" | tail -4 | sed 's/^/    /'
fi

# --- 2. Reset at build start: a run with a DIFFERENT single failure replaces it.
rm -rf "$WORK/badA"; mk_bad badB
run '' >/dev/null 2>&1 || true
N="$(grep -c . "$FJ" 2>/dev/null || echo 0)"
if [ "$N" = "1" ] && grep -q 'badB' "$FJ"; then
  pass "file reset at build start (1 line, the new failure only)"
else
  fail "file not reset: $N line(s)"; sed 's/^/    /' "$FJ" 2>/dev/null
fi

# --- 3. AEB_JOBS=1 sequential engine writes the same record.
rm -rf "$WORK/target"
run 'AEB_JOBS=1' >/dev/null 2>&1 || true
if [ -f "$FJ" ] && grep -q 'badB' "$FJ"; then
  pass "AEB_JOBS=1 sequential engine writes the record"
else
  fail "AEB_JOBS=1 wrote no failure record"; sed 's/^/    /' "$FJ" 2>/dev/null
fi

# --- 4. A clean build leaves the file empty.
rm -rf "$WORK/badB" "$WORK/target"; mk_good okA
run '' >/dev/null 2>&1 || true
if [ ! -s "$FJ" ]; then
  pass "clean build → empty failures file"
else
  fail "clean build left stale failure lines"; sed 's/^/    /' "$FJ"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "failures-jsonl-capture: all assertions passed"
  exit 0
else
  echo "failures-jsonl-capture: $FAILURES assertion(s) FAILED"
  exit 1
fi
