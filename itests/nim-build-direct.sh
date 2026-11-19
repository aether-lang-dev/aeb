#!/usr/bin/env bash
# itests/nim-build-direct.sh — nim.build drives `nim c` itself when test_file(...)
# is declared, and falls back to `nimble build` otherwise.
#
# lib/nim documented that test_file/nim_flag make nim.build use `nim c`, but the
# code always ran `nimble build`. Fixture: stub `nim` and `nimble` on PATH that
# log their argv, so no Nim toolchain is needed; a real aeb run drives them.
#
# Assertions:
#   1. test_file + nim_flag -> `nim c --threads:on "<file>"` runs for each file,
#                              nimble is never invoked
#   2. no test_file         -> `nimble build` runs, nim is not invoked
#   3. a failing `nim c`    -> aeb exits non-zero and reports FAILED
#   4. nim_flag alone       -> aeb exits non-zero with an explanation
#
# Usage: AETHER=/path/to/ae ./itests/nim-build-direct.sh
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

mkdir -p "$WORK/bin" "$WORK/proj/app/src"
(cd "$WORK/proj" && git init -q .)
touch "$WORK/proj/app/src/a.nim" "$WORK/proj/app/src/b.nim"
cat > "$WORK/bin/nim" <<EOT
#!/bin/sh
echo "nim \$*" >> "$WORK/calls.log"
case "\$*" in *b.nim*) [ -n "\${NIM_FAIL_B:-}" ] && exit 4;; esac
exit 0
EOT
cat > "$WORK/bin/nimble" <<EOT
#!/bin/sh
echo "nimble \$*" >> "$WORK/calls.log"
exit 0
EOT
chmod +x "$WORK/bin/nim" "$WORK/bin/nimble"

run() { # body-of-nim.build-block
    rm -rf "$WORK/proj/target"; : > "$WORK/calls.log"
    cat > "$WORK/proj/app/.build.ae" <<EOT
import bldr
import nim
main() {
    bldr.build() {
        nim.build() { $1 }
    }
}
EOT
    (cd "$WORK/proj" && PATH="$WORK/bin:$PATH" "$AEB" app/.build.ae >"$WORK/out.txt" 2>&1)
}

echo "1. test_file + nim_flag -> nim c per file"
if run 'test_file("src/a.nim") test_file("src/b.nim") nim_flag("--threads:on")'; then pass "build passed"; else fail "build failed: $(tail -5 "$WORK/out.txt")"; fi
grep -q 'nim c --threads:on src/a.nim' "$WORK/calls.log" && grep -q 'nim c --threads:on src/b.nim' "$WORK/calls.log" \
    && pass "nim c ran for both files" || fail "nim c not run as declared: $(cat "$WORK/calls.log")"
grep -q '^nimble' "$WORK/calls.log" && fail "nimble was invoked" || pass "nimble not invoked"

echo "2. no test_file -> nimble build"
if run ''; then pass "build passed"; else fail "build failed"; fi
grep -q '^nimble build' "$WORK/calls.log" && pass "nimble build ran" || fail "nimble build not run: $(cat "$WORK/calls.log")"
grep -q '^nim ' "$WORK/calls.log" && fail "nim was invoked" || pass "nim not invoked"

echo "3. failing nim c"
export NIM_FAIL_B=1
if run 'test_file("src/a.nim") test_file("src/b.nim")'; then fail "aeb exited 0 though nim c failed"; else pass "aeb exited non-zero"; fi
grep -q FAILED "$WORK/out.txt" && pass "node reported FAILED" || fail "no FAILED in output"
unset NIM_FAIL_B

echo "4. nim_flag alone"
if run 'nim_flag("--threads:on")'; then fail "aeb exited 0 for nim_flag without test_file"; else pass "aeb exited non-zero"; fi
grep -q "needs at least one test_file" "$WORK/out.txt" && pass "explains why" || fail "no explanation"

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
