#!/usr/bin/env bash
# itests/lfe-test-builder.sh — lfe's documented grammar is the grammar that exists.
#
# lib/lfe's header documented `lfe.run_main() { ... }`, but the declared builder
# is `lfe.test` (run_main is a setter inside it). Fixture: stub `lfec` / `lfe` on
# PATH that log their argv (no LFE toolchain needed), a real aeb run.
#
# Assertions:
#   1. the header's builder example names lfe.test and never lfe.run_main()
#   2. lfe.test() { src, test_src, pa, run_main } compiles with lfec and runs
#      `lfe ... -eval '(ffi_test:main (list))'`
#   3. without run_main("...") the node fails and the message names lfe.test
#   4. lfe.run_main() is not a builder: a build file using it is refused
#
# Usage: AETHER=/path/to/ae ./itests/lfe-test-builder.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AEB_CACHE_DIR="$WORK/cache"

echo "1. header"
grep -q '^//   lfe\.test() {' "$REPO_ROOT/lib/lfe/module.ae" && pass "header example uses lfe.test()" || fail "header example does not use lfe.test()"
grep -q 'lfe\.run_main()' "$REPO_ROOT/lib/lfe/module.ae" && fail "lib/lfe still mentions lfe.run_main()" || pass "no phantom lfe.run_main()"

mkdir -p "$WORK/bin" "$WORK/proj/app/src" "$WORK/proj/app/test"
(cd "$WORK/proj" && git init -q .)
touch "$WORK/proj/app/src/a.lfe" "$WORK/proj/app/test/ffi_test.lfe"
for t in lfec lfe; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$t" "$WORK" > "$WORK/bin/$t"
    chmod +x "$WORK/bin/$t"
done
run() { # builder-name block
    rm -rf "$WORK/proj/target"; : > "$WORK/calls.log"
    cat > "$WORK/proj/app/.tests.ae" <<EOT
import bldr
import lfe
main() {
    bldr.build() {
        lfe.$1() { $2 }
    }
}
EOT
    (cd "$WORK/proj" && PATH="$WORK/bin:$PATH" "$AEB" app/.tests.ae >"$WORK/out.txt" 2>&1)
}

echo "2. lfe.test with run_main"
if run test 'src("src/a.lfe") test_src("test/ffi_test.lfe") pa("/x/ebin") run_main("ffi_test")'; then pass "build passed"; else fail "build failed: $(tail -5 "$WORK/out.txt")"; fi
grep -q "^lfec " "$WORK/calls.log" && pass "lfec ran" || fail "lfec did not run"
grep -q "ffi_test:main" "$WORK/calls.log" && pass "lfe ran ffi_test:main" || fail "lfe did not run ffi_test:main: $(cat "$WORK/calls.log")"

echo "3. lfe.test without run_main"
if run test 'src("src/a.lfe")'; then fail "passed without run_main"; else pass "failed"; fi
grep -q "lfe.test: run_main" "$WORK/out.txt" && pass "message names lfe.test" || fail "message does not name lfe.test: $(grep -i run_main "$WORK/out.txt" | head -2)"

echo "4. lfe.run_main() is not a builder"
if run run_main 'run_main("ffi_test")'; then fail "a nonexistent builder was accepted"; else pass "refused"; fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
