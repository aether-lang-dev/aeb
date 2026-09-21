#!/usr/bin/env bash
# itests/config-precedence.sh — flag > env > default precedence for `jobs` (aeb#10).
#
# aeb has one documented precedence order (README § Configuration precedence):
# explicit CLI flag > environment variable > .ae-declared intent > built-in
# default. The one env-only gap this closed is `jobs`: `--jobs N` now exists and
# beats AEB_JOBS, which beats the nproc default. This smoke proves flag-beats-env
# for jobs (the acceptance criterion) via an observable engine difference:
# `--jobs 1` forces the SEQUENTIAL driver path (no target/.aeb/bldr.mk), while the
# parallel/make path GENERATES bldr.mk — so the presence/absence of bldr.mk tells
# us which `jobs` value the driver actually used.
#
# Assertions:
#   1. FLAG BEATS ENV  — `--jobs 1` with AEB_JOBS=8 → sequential (no bldr.mk).
#   2. ENV BEATS DEFAULT — AEB_JOBS=8 (no flag) → parallel/make (bldr.mk present).
#   3. VALIDATION      — `--jobs` with no/bad argument is rejected.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/config-precedence.sh
# Exit: 0 if all pass; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
export AETHER
if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi
if ! command -v "$AETHER" >/dev/null 2>&1; then echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; fi
if ! command -v make >/dev/null 2>&1; then echo "  SKIP: no make on PATH — the parallel-vs-sequential tell needs it"; echo; echo "config-precedence: skipped"; exit 0; fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Two independent leaves so the parallel engine has something to fan out.
mkdir -p "$WORK/n1" "$WORK/n2"
printf 'import bldr\nimport bash\naeb(cap) { bldr.build() { bash.test() { script("echo n1") } } }\n' > "$WORK/n1/.build.ae"
printf 'import bldr\nimport bash\naeb(cap) { bldr.build() { bash.test() { script("echo n2") } } }\n' > "$WORK/n2/.build.ae"

MK="$WORK/target/.aeb/bldr.mk"

# --- 1. flag beats env: --jobs 1 forces sequential even with AEB_JOBS=8.
rm -rf "$WORK/target"
( cd "$WORK" && env AETHER_HOME="$(mktemp -d)" AEB_JOBS=8 "$AEB" --jobs 1 --scan '.build.ae' ) >/dev/null 2>&1 || true
if [ ! -f "$MK" ]; then
  pass "--jobs 1 beats AEB_JOBS=8 → sequential path (no bldr.mk)"
else
  fail "--jobs 1 did NOT override AEB_JOBS=8 (bldr.mk present → make path used)"
fi

# --- 2. env beats default: AEB_JOBS=8 (no flag) → parallel/make path.
rm -rf "$WORK/target"
( cd "$WORK" && env AETHER_HOME="$(mktemp -d)" AEB_JOBS=8 "$AEB" --scan '.build.ae' ) >/dev/null 2>&1 || true
if [ -f "$MK" ]; then
  pass "AEB_JOBS=8 (no flag) → make/parallel path (bldr.mk present)"
else
  fail "AEB_JOBS=8 did not select the make path"
fi

# --- 3. validation.
V1="$( cd "$WORK" && "$AEB" --jobs 2>&1 || true )"
V2="$( cd "$WORK" && "$AEB" --jobs=abc --scan '.build.ae' 2>&1 || true )"
if echo "$V1" | grep -qi "requires a number" && echo "$V2" | grep -qi "positive integer"; then
  pass "--jobs validates its argument (no-arg + non-numeric rejected)"
else
  fail "--jobs validation missing"; echo "$V1" | head -1 | sed 's/^/    /'; echo "$V2" | head -1 | sed 's/^/    /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "config-precedence: all assertions passed"
  exit 0
else
  echo "config-precedence: $FAILURES assertion(s) FAILED"
  exit 1
fi
