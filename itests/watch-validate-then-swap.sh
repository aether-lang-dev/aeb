#!/usr/bin/env bash
# itests/watch-validate-then-swap.sh — --watch's last-good guarantee (aeb#11).
#
# The watch loop's rebuild step is `aeb --changed-paths-from <file>` (see
# tools/aeb-watch run_rebuild). Its contract: a `.build.ae` that no longer
# compiles aborts at the orchestrator compile/link BEFORE any node executes and
# writes its target/, so the last-good DAG + artifacts stay intact (the prior
# binary still runs); fixing the edit recovers on the next rebuild with no manual
# re-invocation. We drive that rebuild path directly — deterministic, no async
# file-watcher needed (inotify/fswatch is just the trigger; the guarantee is in
# the rebuild).
#
# Assertions:
#   1. GOOD BUILD     — an initial build produces a runnable binary (v1).
#   2. BAD EDIT KEEPS — breaking the .build.ae → rebuild fails, but the v1 binary
#                       is still present AND still runs (last-good preserved).
#   3. RECOVERS       — fixing the edit → next rebuild is green, binary is v2.
#   4. BURST COHERENT — a rebuild after several rapid edits ends on a coherent
#                       state (the final good content), never a half-applied DAG.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/watch-validate-then-swap.sh
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
export AETHER_HOME="$WORK/h"; mkdir -p "$AETHER_HOME"

mkdir -p "$WORK/app"
GOOD_BUILD='import bldr
import aether
import aether (source, output)
aeb(cap) { bldr.build() { aether.program() { source("main.ae") output("app") } } }'
BAD_BUILD='import bldr
import aether
import aether (source, output)
aeb(cap) { bldr.build() { aether.program() { source("main.ae") output("app") INVALID(( } } }'

find_bin() { find "$WORK/target" -name app -type f -path '*bin*' 2>/dev/null | head -1; }

# --- 1. good initial build.
printf 'main() { println("v1") }\n' > "$WORK/app/main.ae"
printf '%s\n' "$GOOD_BUILD" > "$WORK/app/.build.ae"
( cd "$WORK" && "$AEB" app/.build.ae ) >/dev/null 2>&1
BIN="$(find_bin)"
if [ -n "$BIN" ] && [ "$("$BIN" 2>/dev/null)" = "v1" ]; then
  pass "initial build → runnable binary (v1)"
else
  fail "initial build produced no runnable binary"; echo; echo "watch-validate-then-swap: setup FAILED"; exit 1
fi

# --- 2. break the .build.ae → rebuild reports the compile error, but the v1
# binary survives and still runs (the last-good guarantee — the core of #11).
# NOTE: the rebuild currently exits 0 on this path (a separate exit-code bug,
# asks/changed-paths-from-swallows-compile-failure-rc.md), so assert on the
# ERROR OUTPUT + binary survival — the actual contract — not the exit code.
printf '%s\n' "$BAD_BUILD" > "$WORK/app/.build.ae"
printf 'app/.build.ae\n' > "$WORK/changed.txt"
RB="$( cd "$WORK" && "$AEB" --changed-paths-from "$WORK/changed.txt" 2>&1 )"
BIN2="$(find_bin)"
if echo "$RB" | grep -qE 'error\[E[0-9]+\]|aborting: [0-9]+ error' && [ -n "$BIN2" ] && [ "$("$BIN2" 2>/dev/null)" = "v1" ]; then
  pass "bad edit → compile error reported BUT last-good binary intact + still runs (v1)"
else
  fail "bad edit tore down the last-good build (bin='$BIN2', ran='$([ -n "$BIN2" ] && "$BIN2" 2>/dev/null)')"; echo "$RB" | tail -4 | sed 's/^/    /'
fi

# --- 3. fix → next rebuild green, binary is v2.
printf 'main() { println("v2") }\n' > "$WORK/app/main.ae"
printf '%s\n' "$GOOD_BUILD" > "$WORK/app/.build.ae"
printf 'app/.build.ae\napp/main.ae\n' > "$WORK/changed.txt"
( cd "$WORK" && "$AEB" --changed-paths-from "$WORK/changed.txt" ) >/dev/null 2>&1
BIN3="$(find_bin)"
if [ -n "$BIN3" ] && [ "$("$BIN3" 2>/dev/null)" = "v2" ]; then
  pass "fix on next rebuild recovers to green (v2), no manual re-invocation"
else
  fail "did not recover after the fix (bin='$BIN3' out='$([ -n "$BIN3" ] && "$BIN3" 2>/dev/null)')"
fi

# --- 4. rapid edits then one rebuild → coherent final state (the debounce shape:
#        several saves accumulate, one rebuild runs on the final content).
printf 'main() { println("bad-mid") }\n' > "$WORK/app/main.ae"
printf '%s\n' "$BAD_BUILD" > "$WORK/app/.build.ae"      # intermediate broken save
printf 'main() { println("v3") }\n' > "$WORK/app/main.ae"
printf '%s\n' "$GOOD_BUILD" > "$WORK/app/.build.ae"     # final good save
printf 'app/.build.ae\napp/main.ae\n' > "$WORK/changed.txt"
( cd "$WORK" && "$AEB" --changed-paths-from "$WORK/changed.txt" ) >/dev/null 2>&1
BIN4="$(find_bin)"
if [ -n "$BIN4" ] && [ "$("$BIN4" 2>/dev/null)" = "v3" ]; then
  pass "burst → one rebuild lands the coherent final state (v3), never half-applied"
else
  fail "burst left an incoherent state (bin='$BIN4')"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "watch-validate-then-swap: all assertions passed"
  exit 0
else
  echo "watch-validate-then-swap: $FAILURES assertion(s) FAILED"
  exit 1
fi
