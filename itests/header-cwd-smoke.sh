#!/usr/bin/env bash
# Real consumer checkout with headers in its root: shell globs must not
# expand the header-search predicate used by aeb-link.
set -euo pipefail
AEB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEB_BIN="${AEB_BIN:-$AEB_ROOT/aeb}"
WORK="$(mktemp -d /tmp/aeb-header-cwd-smoke.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/.build.ae" <<'AE'
import bldr
import aether

aeb(cap) {
    bldr.build() {
        aether.program() {
            source("main.ae")
            output("smoke")
        }
        return 0
    }
}
AE
cat > "$WORK/main.ae" <<'AE'
main() { println("header-root smoke") }
AE
printf '/* first root header */\n' > "$WORK/first.h"
printf '/* second root header */\n' > "$WORK/second.h"
cd "$WORK"
"$AEB_BIN" .build.ae > "$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }
actual="$(./target/build/bin/smoke)"
[ "$actual" = 'header-root smoke' ] || { echo "unexpected output: $actual"; exit 1; }
echo 'PASS: aeb builds and runs a consumer with multiple headers in its root'
