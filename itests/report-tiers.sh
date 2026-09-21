#!/usr/bin/env bash
# itests/report-tiers.sh — the inline [telemetry] verbosity dial (aeb#8).
#
# `aeb --report=<tier>` (counts|targets|per-rule|full) filters how much the inline
# [telemetry] block prints, so a caller pays only for the detail it needs — a
# FILTER on rendering, not on collection. Default (no flag) is unchanged (full).
#
# Assertions:
#   1. COUNTS      — aggregate only: total + verdict, NO per-node data rows.
#   2. TARGETS     — per-node rows (label/wall/cache), no per-test N/M trailer.
#   3. PER-RULE    — rows WITH the N/M PASS/FAIL trailer.
#   4. DEFAULT     — no flag == full: rows present (unchanged from today).
#   5. BAD TIER    — an unknown tier is rejected with a clear error.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/report-tiers.sh
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

# Two bash test nodes (deterministic, no language toolchain). One "passes"
# (well — bash.test runs the script; both give telemetry rows either way, which
# is all we need to see the tier cuts). A dep gives a 2-node DAG.
mkdir -p "$WORK/liba" "$WORK/app"
printf 'import bldr\nimport bash\naeb(cap) { bldr.build() { bash.test() { script("echo a") } } }\n' > "$WORK/liba/.build.ae"
cat > "$WORK/app/.build.ae" <<'EOF'
import bldr
import bash
aeb(cap) { bldr.build() { dep("liba/.build.ae") bash.test() { script("echo app") } } }
EOF

report() {  # report <tier-or-empty> ; prints the [telemetry] block
  local tier="$1"; local flag=""
  [ -n "$tier" ] && flag="--report=$tier"
  ( cd "$WORK" && env AETHER_HOME="$(mktemp -d)" "$AEB" $flag --scan '.build.ae' ) 2>&1 | sed -n '/\[telemetry\]/,$p'
}

# --- 1. counts: no per-node data rows (no cache marker), but total + verdict.
C="$(report counts)"
if echo "$C" | grep -q "total:" && ! echo "$C" | grep -qE '\[(hit|miss|n/a)\]'; then
  pass "counts: aggregate only (total present, no per-node [cache] rows)"
else
  fail "counts tier still shows per-node rows"; echo "$C" | sed 's/^/    /' | head -6
fi

# --- 2. targets: per-node rows present, no N/M PASS/FAIL count trailer.
T="$(report targets)"
if echo "$T" | grep -qE '\[(hit|miss|n/a)\]' && ! echo "$T" | grep -qE '[0-9]+/[0-9]+ (PASS|FAIL)'; then
  pass "targets: per-node rows, no N/M count trailer"
else
  fail "targets tier wrong (rows missing or trailer present)"; echo "$T" | sed 's/^/    /' | head -6
fi

# --- 3. per-rule: rows WITH the N/M PASS/FAIL trailer.
P="$(report per-rule)"
if echo "$P" | grep -qE '[0-9]+/[0-9]+ (PASS|FAIL)'; then
  pass "per-rule: rows carry the N/M PASS/FAIL trailer"
else
  fail "per-rule tier missing the count trailer"; echo "$P" | sed 's/^/    /' | head -6
fi

# --- 4. default (no flag) == full: per-node rows present.
D="$(report '')"
if echo "$D" | grep -qE '\[(hit|miss|n/a)\]'; then
  pass "default (no flag) shows per-node rows (== full, unchanged)"
else
  fail "default telemetry changed (no per-node rows)"; echo "$D" | sed 's/^/    /' | head -6
fi

# --- 5. bad tier rejected.
B="$( cd "$WORK" && "$AEB" --report=bogus --scan '.build.ae' 2>&1 || true )"
if echo "$B" | grep -qi "must be counts"; then
  pass "unknown tier rejected with a clear error"
else
  fail "bad tier not rejected"; echo "$B" | sed 's/^/    /' | head -4
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "report-tiers: all assertions passed"
  exit 0
else
  echo "report-tiers: $FAILURES assertion(s) FAILED"
  exit 1
fi
