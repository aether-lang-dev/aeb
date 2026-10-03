#!/usr/bin/env bash
# itests/c-program-rebuild-smoke.sh — c.program relinks when it should.
#
# Two ways c.program used to keep a stale binary, both found building sae (a
# C + Aether program that links mquickjs-ae and aether-ui):
#
#   1. Its change check covered only the declared sources. An aether_source
#      whose IMPORTED project module was edited counted as unchanged, so the
#      binary kept the old module. lib/aether already hashes the transitive
#      import closure into its cache key for this reason; c.program now walks
#      the same closure.
#   2. The skip-stamp was one `.timestamp` per bin dir. A node whose
#      output_file() depends on the environment (a release build and a test
#      build of one program) shared it, so after one output linked the other
#      was "not changed" and kept whatever it was last linked from.
#
# Assertions:
#   1. COLD         — the program builds and prints the imported module's value.
#   2. IMPORT EDIT  — editing ONLY the imported module rebuilds: new value.
#   3. VARIANT      — the env-selected second output builds with the new value.
#   4. BOTH FRESH   — after another module edit, each output, built in turn,
#                     prints the newest value (neither is skipped as unchanged).
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/c-program-rebuild-smoke.sh
# Needs AETHER_HOME naming an Aether tree or install (libaether + headers).
# Exit code: 0 if every assertion passed; 1 otherwise.

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
export AETHER_CACHE_DIR="$WORK/aecache"; mkdir -p "$AETHER_CACHE_DIR"

APP="$WORK/app"; mkdir -p "$APP/helper"
cat > "$APP/main.c" <<'EOF'
#include <stdio.h>
int lib_value(void);
int main(void) { printf("%d\n", lib_value()); return 0; }
EOF
cat > "$APP/lib.ae" <<'EOF'
import helper
@c_callback
lib_value() -> int { return helper.value() }
EOF
set_value() {
    # The change check compares whole-second mtimes against the last link's
    # stamp, so keep each edit in a later second than the build before it.
    sleep 1
    cat > "$APP/helper/module.ae" <<EOF
exports (value)
value() -> int { return $1 }
EOF
    # mtime resolution on some filesystems is one second
    sleep 1
}
cat > "$APP/.build.ae" <<'EOF'
import bldr
import c
import c (sources, aether_source, output_file, aether_home)
import std.os
import std.string

out_name_() -> string {
    v = os.getenv("VARIANT")
    if string.length(v) > 0 { return "prog-b" }
    return "prog"
}

aeb(cap) {
    bldr.build() {
        c.program() {
            h = os.getenv("AETHER_HOME")
            if string.length(h) > 0 { aether_home(h) }
            sources("main.c")
            aether_source("lib.ae")
            output_file(out_name_())
        }
        return 0
    }
}
EOF

build() { (cd "$APP" && "$AEB" .build.ae) > "$WORK/build.log" 2>&1; }
run() { "$APP/target/build/bin/$1" 2>/dev/null; }

echo "c.program rebuild smoke"

set_value 1
build
if [ "$(run prog)" = "1" ]; then pass "cold build prints 1"; else fail "cold build (got '$(run prog)'; log: $WORK/build.log)"; cat "$WORK/build.log" | tail -20; fi

set_value 2
build
if [ "$(run prog)" = "2" ]; then pass "editing only the imported module rebuilds"; else fail "import edit kept a stale binary (got '$(run prog)', want 2)"; fi

(export VARIANT=b; build)
if [ "$(run prog-b)" = "2" ]; then pass "the env-selected second output builds"; else fail "second output (got '$(run prog-b)', want 2)"; fi

set_value 3
build
(export VARIANT=b; build)
a=$(run prog)
b=$(run prog-b)
if [ "$a" = "3" ] && [ "$b" = "3" ]; then pass "both outputs relink after an edit"; else fail "after edit: prog=$a prog-b=$b, want 3 and 3"; fi

if [ "$FAILURES" -eq 0 ]; then echo "c-program-rebuild-smoke: all passed"; exit 0; fi
echo "c-program-rebuild-smoke: $FAILURES failed"
exit 1
