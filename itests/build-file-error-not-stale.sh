#!/usr/bin/env bash
# itests/build-file-error-not-stale.sh — a .build.ae that stops compiling
# fails the build.
#
# aeb-link compiles each build file to target/_aeb/<name>.c and links them
# into the orchestrator. It ignored that compile's exit code, so once a build
# file had compiled ONCE, breaking it printed the type error and then linked
# the previous run's .c: the old graph ran and aeb exited 0. Found building
# sae, where an edit to .build.ae "succeeded" with its type error on screen.
#
# Assertions:
#   1. a valid build file builds (exit 0)
#   2. the same file, broken, fails (non-zero exit) after a good build
#   3. fixed again, it builds (exit 0)
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/build-file-error-not-stale.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
export AETHER

if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AETHER_CACHE_DIR="$WORK/aecache"; mkdir -p "$AETHER_CACHE_DIR"
APP="$WORK/app"; mkdir -p "$APP"
echo 'int main(void) { return 0; }' > "$APP/main.c"

write_build() {
    # $1: the if-condition. "flag_() == 1" compiles; "flag_()" does not (an
    # int used as a condition is a type error).
    cat > "$APP/.build.ae" <<BUILD
import bldr
import c
import c (sources, output_file)

flag_() -> int {
    return 1
}

aeb(cap) {
    bldr.build() {
        c.program() {
            if $1 { sources("main.c") }
            output_file("prog")
        }
        return 0
    }
}
BUILD
    sleep 1
}

build() { (cd "$APP" && "$AEB" .build.ae) > "$WORK/build.log" 2>&1; }

echo "build file error is not stale"
write_build "flag_() == 1"
if build; then pass "valid build file builds"; else fail "valid build failed: $(tail -5 "$WORK/build.log")"; fi
write_build "flag_()"
if build; then fail "broken build file exited 0 (ran the previous graph)"; else pass "broken build file fails"; fi
write_build "flag_() == 1"
if build; then pass "fixed build file builds again"; else fail "fixed build failed"; fi

if [ "$FAILURES" -eq 0 ]; then echo "build-file-error-not-stale: all passed"; exit 0; fi
echo "build-file-error-not-stale: $FAILURES failed"
exit 1
