#!/usr/bin/env bash
# itests/test-counts-cargo-mocha.sh — rust.test and ts.mocha record the runners'
# own per-test counts, not a bare 1/0 or 0/1.
#
# rust.test recorded 1 passed on success and 0/1 on failure, whatever cargo
# reported; ts.mocha did the same with mocha's summary. Both now read the
# runner's output (cargo's `test result:` lines, summed over every test binary;
# mocha's "N passing / N failing / N pending") and record passed/failed/skipped.
#
# Needs real tools: cargo (part 1) and node + npm with network to fetch mocha
# (part 2). Each part prints SKIP when its tool is absent.
#
# Part 1 fixture: a cargo workspace with one lib crate: 3 passing unit tests,
#   1 ignored, and a tests/it.rs with 2 passing tests -> 5 passed, 1 ignored.
#   Then one unit test is made to fail -> 2 passed, 1 failed (cargo stops at
#   the first failing binary), node FAILED.
# Part 2 fixture: mocha 11 installed under libs/javascript/npm_vendored, a spec
#   with 3 passing, 1 pending -> 3 passed; then one failing -> 2 passed, 1 failed.
#
# Usage: AETHER=/path/to/ae ./itests/test-counts-cargo-mocha.sh
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

# telemetry row for the node: "  tests:   app   0.42s [n/a] 5/5 PASS"
row() { grep -E "^ +tests: +app +[0-9.]+s" "$WORK/out.txt" | tail -1; }

if command -v cargo >/dev/null 2>&1; then
    echo "1. rust.test: cargo test counts"
    P="$WORK/rs"; mkdir -p "$P/app/src" "$P/app/tests"
    (cd "$P" && git init -q .)
    printf '[workspace]\nmembers = ["app"]\nresolver = "2"\n' > "$P/Cargo.toml"
    printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n' > "$P/app/Cargo.toml"
    write_lib() { # expected-sum-for-bad
        cat > "$P/app/src/lib.rs" <<EOT
pub fn add(a: i32, b: i32) -> i32 { a + b }
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn a() { assert_eq!(add(1,2),3); }
    #[test] fn b() { assert_eq!(add(2,2),4); }
    #[test] fn bad() { assert_eq!(add(2,2),$1); }
    #[test] #[ignore] fn c() { }
}
EOT
    }
    printf '#[test] fn i1() {}\n#[test] fn i2() {}\n' > "$P/app/tests/it.rs"
    cat > "$P/app/.tests.ae" <<'EOT'
import bldr
import rust
main() {
    bldr.build() {
        rust.test() { crate_name("app") }
    }
}
EOT
    run_rs() { rm -rf "$P/target/tests"; (cd "$P" && "$AEB" app/.tests.ae >"$WORK/out.txt" 2>&1); }
    write_lib 4
    if run_rs; then pass "green run exits 0"; else fail "green run failed: $(tail -8 "$WORK/out.txt")"; fi
    row | grep -q "5/5" && pass "counts 5 passed (3 unit + 2 integration): $(row | tr -s ' ')" || fail "expected 5/5, row: $(row)"
    write_lib 5
    if run_rs; then fail "failing test exited 0"; else pass "failing run exits non-zero"; fi
    row | grep -q "2/3" && pass "counts 2 passed of 3 run: $(row | tr -s ' ')" || fail "expected 2/3, row: $(row)"
    grep -q "FAILED" "$WORK/out.txt" && pass "node reported FAILED" || fail "no FAILED"
else
    echo "1. SKIP: cargo not installed"
fi

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    echo "2. ts.mocha: mocha counts"
    P="$WORK/js"; mkdir -p "$P/app" "$P/libs/javascript/npm_vendored"
    (cd "$P" && git init -q .)
    if (cd "$P/libs/javascript/npm_vendored" && npm init -y >/dev/null 2>&1 && npm install mocha@11 >/dev/null 2>&1) \
        && [ -f "$P/libs/javascript/npm_vendored/node_modules/mocha/bin/mocha.js" ]; then
        write_spec() { # body-of-third-it
            cat > "$P/app/t.js" <<EOT
const assert = require("assert");
describe("x", () => { it("a", () => {}); it("b", () => {}); it("c", () => { $1 }); it.skip("d", () => {}); });
EOT
        }
        cat > "$P/app/.tests.ae" <<'EOT'
import bldr
import ts
main() {
    bldr.build() {
        ts.mocha("app/t.js")
    }
}
EOT
        run_js() { rm -rf "$P/target/tests"; (cd "$P" && "$AEB" app/.tests.ae >"$WORK/out.txt" 2>&1); }
        write_spec ""
        if run_js; then pass "green run exits 0"; else fail "green run failed: $(tail -8 "$WORK/out.txt")"; fi
        row | grep -q "3/3" && pass "counts 3 passed: $(row | tr -s ' ')" || fail "expected 3/3, row: $(row)"
        write_spec "assert.equal(1, 2);"
        if run_js; then fail "failing spec exited 0"; else pass "failing run exits non-zero"; fi
        row | grep -q "2/3" && pass "counts 2 passed of 3: $(row | tr -s ' ')" || fail "expected 2/3, row: $(row)"
    else
        echo "  SKIP: could not install mocha (no network?)"
    fi
else
    echo "2. SKIP: node/npm not installed"
fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
