#!/usr/bin/env bash
# itests/libaether-floor-guard.sh — the Aether >= 0.681 floor is enforced on the
# libaether.a that aeb-link actually LINKS, not just the compiler version.
#
# The bug this guards (servirtium-vcr, 2026-09-19): a box had a current `ae`
# (0.695, has os_arch_raw) beside a STALE <prefix>/lib/aether/libaether.a (an
# older install's leftover, no os_arch_raw) shadowing the current
# <prefix>/lib/libaether.a. aeb-link probes lib/aether/ first (mirroring ae.c),
# so it linked the stale archive; any node using os.arch() (e.g.
# aether.emit_binary_package) then failed the whole fan-out orchestrator link
# with a cryptic `undefined reference to os_arch_raw`. aeb-link now checks the
# resolved archive for os_arch_raw (the 0.681 marker) and, if absent, fails early
# with a legible floor error naming the stale path — exit 2, before the link.
#
# This test synthesises that exact divergence from the installed toolchain: a
# full copy of the current ae install, with its lib/aether/libaether.a replaced
# by a pre-0.681 archive, and asserts (1) the floor error fires with the right
# text, and (2) a correct install does NOT false-trigger.
#
# Needs a pre-0.681 libaether.a to stage the stale copy; if none is installed
# under ~/.aether/versions, the "stale" leg SKIPs (the happy-path leg still runs).
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/libaether-floor-guard.sh
# Exit: 0 if the guard behaves correctly (or skipped), 1 otherwise.

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

# Resolve the real toolchain prefix from the ae on PATH.
AE_BIN="$(command -v "$AETHER")"
AE_DIR="$(dirname "$AE_BIN")"
PREFIX="$(cd "$AE_DIR/.." && pwd)"

# A node that uses os.arch() (via aether.emit_binary_package) so the orchestrator
# references os_arch_raw, plus one extra leaf to force a real fan-out.
mk_repo() {
  local d="$1"; mkdir -p "$d/core" "$d/leaf1"
  printf 'exports(hello)\nhello() -> string { return "x" }\n' > "$d/core/greet.ae"
  cat > "$d/core/.build.ae" <<'EOF'
import bldr
import aether
import aether (source, output, stem, release_tag)
aeb(cap) {
  bldr.build() {
    aether.shared_lib() { source("greet.ae") output("libgreet.so") }
    aether.emit_binary_package() { source("greet.ae") output("libgreet.so") stem("greet") release_tag("v0.1.0") }
  }
}
EOF
  printf 'import bldr\nimport bash\naeb(cap) { bldr.build() { bash.test() { script("echo ok") } } }\n' > "$d/leaf1/.build.ae"
}

# --- Locate a pre-0.681 libaether.a to serve as the stale copy. ---
STALE_A=""
for v in "$HOME"/.aether/versions/v0.6[0-7][0-9].0 "$HOME"/.aether/versions/v0.680.0; do
  cand="$v/lib/libaether.a"
  if [ -f "$cand" ] && ! grep -a -q os_arch_raw "$cand" 2>/dev/null; then STALE_A="$cand"; break; fi
done

# --- 1. Stale archive → clear floor error (the servirtium-vcr case). ---
if [ -z "$STALE_A" ]; then
  echo "  SKIP: no pre-0.681 libaether.a installed to stage the stale copy"
else
  FAKE="$WORK/prefix"
  cp -a "$PREFIX" "$FAKE"
  mkdir -p "$FAKE/lib/aether"
  cp "$STALE_A" "$FAKE/lib/aether/libaether.a"   # stale nested archive shadows the flat one
  mk_repo "$WORK/repo_stale"
  export AETHER_HOME="$WORK/h_stale"; mkdir -p "$AETHER_HOME"
  LOG="$WORK/stale.log"
  ( cd "$WORK/repo_stale" && AETHER="$FAKE/bin/ae" "$AEB" --scan '.build.ae' ) >"$LOG" 2>&1
  RC=$?
  if grep -qi "older than the 0.681 floor" "$LOG" && grep -qi "os_arch_raw" "$LOG" && [ "$RC" -ne 0 ]; then
    pass "stale libaether.a → clear 0.681-floor error (exit $RC), not a raw undefined-reference"
  elif grep -qi "undefined reference to .os_arch_raw" "$LOG"; then
    fail "stale archive reached the raw link error — the floor guard did not fire"; tail -6 "$LOG" | sed 's/^/    /'
  else
    fail "unexpected outcome for the stale-archive case (rc=$RC)"; tail -10 "$LOG" | sed 's/^/    /'
  fi
fi

# --- 2. A correct install must NOT false-trigger the floor error. ---
mk_repo "$WORK/repo_ok"
export AETHER_HOME="$WORK/h_ok"; mkdir -p "$AETHER_HOME"
LOG2="$WORK/ok.log"
( cd "$WORK/repo_ok" && "$AEB" --scan '.build.ae' ) >"$LOG2" 2>&1
if grep -qi "0.681 floor" "$LOG2"; then
  fail "correct install FALSE-triggered the floor error"; grep -i floor "$LOG2" | sed 's/^/    /'
elif [ -f "$WORK/repo_ok/target/_ae_build_all" ]; then
  pass "correct install links the orchestrator (no false floor trigger)"
else
  # If it failed for another reason (e.g. no os_arch_raw at all in this toolchain),
  # only fail if it was the floor path; otherwise the toolchain itself is < 0.681.
  if grep -qi "undefined reference to .os_arch_raw" "$LOG2"; then
    fail "correct-install leg hit os_arch_raw undefined — toolchain libaether.a itself is stale?"; tail -6 "$LOG2" | sed 's/^/    /'
  else
    pass "correct install did not false-trigger the floor error (orchestrator outcome aside)"
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "libaether-floor-guard: all assertions passed"
  exit 0
else
  echo "libaether-floor-guard: $FAILURES assertion(s) FAILED"
  exit 1
fi
