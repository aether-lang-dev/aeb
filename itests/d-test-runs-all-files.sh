#!/usr/bin/env bash
# itests/d-test-runs-all-files.sh — d.test runs every test_file and counts each.
#
# d.test stopped at the first failing file (later files never ran and were not
# counted), and every file's run wrote its verdict to one shared test_exit.rc.
# Fixture: a stub compiler (declared with d_bin) that fails for files named
# fail_*.d and passes for the rest, so no D toolchain is needed; a real aeb run
# drives it. Files in order: fail_a.d, ok_b.d, fail_c.d, ok_d.d.
#
# Assertions:
#   1. aeb exits non-zero (some files failed)
#   2. all four files were run, in order, including the ones after a failure
#   3. the telemetry row counts 2 passed of 4 (2/4)
#   4. each file has its own exit marker in target/ (no shared test_exit.rc)
#   5. all-pass control: exit 0 and 4/4
#
# Usage: AETHER=/path/to/ae ./itests/d-test-runs-all-files.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/proj/app/tests"
(cd "$WORK/proj" && git init -q .)
for f in fail_a ok_b fail_c ok_d; do touch "$WORK/proj/app/tests/$f.d"; done
cat > "$WORK/stub-dmd" <<EOT
#!/bin/sh
echo "dmd \$*" >> "$WORK/calls.log"
case "\$*" in *fail_*) exit 1;; esac
exit 0
EOT
chmod +x "$WORK/stub-dmd"

run() { # block-extra
    rm -rf "$WORK/proj/target"; : > "$WORK/calls.log"
    cat > "$WORK/proj/app/.tests.ae" <<EOT
import bldr
import d
main() {
    bldr.build() {
        d.test() {
            d_bin("$WORK/stub-dmd")
            test_file("tests/$1_a.d")
            test_file("tests/ok_b.d")
            test_file("tests/$1_c.d")
            test_file("tests/ok_d.d")
        }
    }
}
EOT
    (cd "$WORK/proj" && "$AEB" app/.tests.ae >"$WORK/out.txt" 2>&1)
}

echo "1. mixed results"
if run fail; then fail "aeb exited 0 though two files failed"; else pass "aeb exited non-zero"; fi
for f in fail_a ok_b fail_c ok_d; do
    grep -q "$f.d" "$WORK/calls.log" && pass "$f.d was run" || fail "$f.d was never run (stopped at first failure)"
done
grep -qE "2/4" "$WORK/out.txt" && pass "telemetry counts 2/4" || fail "telemetry does not show 2/4: $(grep -E 'tests|/4|PASS|FAIL' "$WORK/out.txt" | tail -4 | tr '\n' '|')"
n=$(find "$WORK/proj/target" -name "test_exit_*.rc" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -ge 4 ] && pass "per-file exit markers ($n)" || fail "expected one exit marker per file, found $n"

echo "2. all pass (control)"
# 'ok' prefix: tests/ok_a.d etc. must exist
for f in ok_a ok_c; do touch "$WORK/proj/app/tests/$f.d"; done
if run ok; then pass "aeb exited 0"; else fail "aeb failed: $(tail -5 "$WORK/out.txt")"; fi
grep -qE "4/4" "$WORK/out.txt" && pass "telemetry counts 4/4" || fail "no 4/4"

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
