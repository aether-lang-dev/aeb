#!/usr/bin/env bash
# itests/nested-builder-not-silently-dropped.sh — test builders that are
# never run, or fail where nobody records it, must not leave a node green.
#
# Found in nib-code (2026-11-15): one `aether.program_test() {` in its
# .tests.ae had lost its closing `}`. aetherc accepted the missing brace at
# EOF, so every program_test written after it ran INSIDE that block. A
# builder takes the innermost open block's map as its context, so those
# nested builders ran with the outer builder's config map, not the node's:
# no source dir, so their builds failed, and bldr.fail() on a map with no
# session returned quietly. The outer builder never ran at all (the node's
# `return 0` sat inside its block). `aeb .tests.ae` built 72 of 82 test
# programs and reported PASS. Each program_test also overwrote the node's
# test-result marker, so the telemetry count was 1/1 whatever the node held,
# and a shortfall could not show.
#
# Assertions:
#   1. UNCLOSED  — a builder block missing its `}`: aeb exits non-zero,
#                  names the line of the nested opener and of the open block,
#                  and builds none of the dropped tests as if all were well.
#   2. HELPER    — a builder reached through a helper function inside another
#                  builder's block (balanced braces, so no static check sees
#                  it) whose test program does not build: exit non-zero, the
#                  failure names the test source.
#   3. COUNT     — four program_tests in one node, all closed: all four run
#                  and telemetry counts 4/4 PASS (not 1/1).
#   4. COUNT RED — one of the four fails: exit non-zero, 3/4.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/nested-builder-not-silently-dropped.sh
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

# A project of four trivial test programs; $1 = the .tests.ae body.
make_proj() {
    rm -rf "$WORK/proj"
    mkdir -p "$WORK/proj/t"
    touch "$WORK/proj/.aeb"
    for n in a b c d; do
        printf 'main() {\n    println("test %s ran")\n    exit(0)\n}\n' "$n" > "$WORK/proj/t/${n}_test.ae"
    done
    printf '%s\n' "$1" > "$WORK/proj/.tests.ae"
}

run() {
    (cd "$WORK/proj" && "$AEB" .tests.ae >"$WORK/out.txt" 2>&1)
}

HEAD='import bldr
import aether
import aether (source)
'

echo "1. UNCLOSED: a program_test block missing its closing brace"
make_proj "${HEAD}
aeb(cap) {
    bldr.build() {
        aether.program_test() {
            source(\"t/a_test.ae\")
        }
        aether.program_test() {
            source(\"t/b_test.ae\")
        aether.program_test() {
            source(\"t/c_test.ae\")
        }
        aether.program_test() {
            source(\"t/d_test.ae\")
        }
        return 0
    }
}"
if run; then fail "build passed with an unclosed builder block"; else pass "exit non-zero"; fi
if grep -q '\.tests\.ae:12: `aether.program_test() {` opens inside the still-open `aether.program_test() {` block from line 10' "$WORK/out.txt"; then
    pass "names the nested opener (line 12) and the open block (line 10)"
else
    fail "diagnostic missing: $(grep -v -e warning -e '^ *|' -e '^ *-->' "$WORK/out.txt" | tail -5)"
fi
if grep -q 'PASS' "$WORK/out.txt"; then fail "still prints a PASS"; else pass "no PASS printed"; fi

echo "2. HELPER: a nested builder via a helper, whose test does not build"
make_proj "${HEAD}
more(n: string) {
    aether.program_test() {
        source(n)
    }
}

aeb(cap) {
    bldr.build() {
        aether.program_test() {
            source(\"t/a_test.ae\")
            more(\"t/missing_test.ae\")
        }
    }
}"
if run; then fail "build passed with a nested test that does not build"; else pass "exit non-zero"; fi
if grep -q 'FAILED — .*failed: .*missing_test\.ae' "$WORK/out.txt"; then
    pass "the failure names the test source"
else
    fail "failure not named: $(grep -v -e warning -e '^ *|' -e '^ *-->' "$WORK/out.txt" | tail -5)"
fi

FOUR="${HEAD}
aeb(cap) {
    bldr.build() {
        aether.program_test() {
            source(\"t/a_test.ae\")
        }
        aether.program_test() {
            source(\"t/b_test.ae\")
        }
        aether.program_test() {
            source(\"t/c_test.ae\")
        }
        aether.program_test() {
            source(\"t/d_test.ae\")
        }
    }
}"

echo "3. COUNT: four closed program_tests count 4/4"
make_proj "$FOUR"
if run; then pass "build passed"; else fail "build failed: $(tail -5 "$WORK/out.txt")"; fi
if grep -q '4/4 PASS' "$WORK/out.txt"; then
    pass "telemetry counts 4/4 PASS"
else
    fail "telemetry count wrong: $(grep -A2 telemetry "$WORK/out.txt")"
fi
nbin=$(ls "$WORK/proj/target/tests/bin" 2>/dev/null | wc -l | tr -d ' ')
if [ "$nbin" = "4" ]; then pass "four test binaries built"; else fail "$nbin test binaries built, want 4"; fi

echo "4. COUNT RED: one of four fails"
make_proj "$FOUR"
printf 'main() {\n    println("test c fails")\n    exit(1)\n}\n' > "$WORK/proj/t/c_test.ae"
if run; then fail "build passed with a failing test"; else pass "exit non-zero"; fi
if grep -q '3/4' "$WORK/out.txt"; then
    pass "telemetry counts 3/4"
else
    fail "telemetry count wrong: $(grep -A2 telemetry "$WORK/out.txt")"
fi

if [ "$FAILURES" -eq 0 ]; then
    echo "nested-builder-not-silently-dropped: all passed"
    exit 0
fi
echo "nested-builder-not-silently-dropped: $FAILURES failure(s)"
exit 1
