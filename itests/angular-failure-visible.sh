#!/usr/bin/env bash
# itests/angular-failure-visible.sh — a failed `ngc` / `ng build` must redden the node.
#
# angular.ngc and angular.ng_build returned the tool's exit code without
# calling bldr.fail, unlike ts.tsc. A builder's return value is dropped when
# another builder follows it in the same bldr.build block, so a failed compile
# followed by anything left the node green.
#
# Fixture: stub `ngc` / `ng` binaries in <root>/.aeb/node_modules/.bin (what
# pnpm.resolve leaves there), so no node toolchain is needed. The stub fails or
# succeeds on demand; a second builder follows the first in each block.
#
# Assertions (for ngc, then for ng build):
#   1. failing tool  -> aeb exits non-zero and the node is reported FAILED
#   2. passing tool  -> aeb exits zero (control)
#
# Usage: AETHER=/path/to/ae ./itests/angular-failure-visible.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/app" "$WORK/.aeb/node_modules/.bin"
(cd "$WORK" && git init -q .)

stub() { # name exit-code
    printf '#!/bin/sh\nexit %s\n' "$2" > "$WORK/.aeb/node_modules/.bin/$1"
    chmod +x "$WORK/.aeb/node_modules/.bin/$1"
}
run() { # first-builder second-builder
    rm -rf "$WORK/target"
    cat > "$WORK/app/.build.ae" <<EOT
import bldr
import angular
main() {
    bldr.build() {
        angular.$1()
        angular.$2()
    }
}
EOT
    (cd "$WORK" && "$AEB" app/.build.ae >"$WORK/out.txt" 2>&1)
}

for first in ngc ng_build; do
    second=ngc; [ "$first" = ngc ] && second=ng_build
    tool=ng; [ "$first" = ngc ] && tool=ngc
    echo "angular.$first (followed by angular.$second)"
    stub ngc 0; stub ng 0
    stub "$tool" 3    # the other tool stays green, so only $first can redden the node
    if run "$first" "$second"; then fail "$first failed but aeb exited 0"; else pass "$first failed: aeb exited non-zero"; fi
    if grep -q "FAILED" "$WORK/out.txt"; then pass "$first failed: node reported FAILED"; else fail "$first failed: no FAILED in output"; fi
    stub ngc 0; stub ng 0
    if run "$first" "$second"; then pass "$first ok: aeb exited 0"; else fail "$first ok: aeb exited non-zero"; fi
done

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
