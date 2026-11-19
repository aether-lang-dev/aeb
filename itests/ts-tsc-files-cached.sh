#!/usr/bin/env bash
# itests/ts-tsc-files-cached.sh — ts.tsc_files goes through the content-addressed
# cache like ts.tsc.
#
# tsc_files ran `tsc` on every rebuild with no cache. (It is live: the
# google-monorepo-sim consumer builds its TypeScript modules with it.) Fixture: a
# stub `tsc` on PATH that logs each run and writes a .js for the .ts in source_dir
# into --outDir, and a stub generate-typescript-base-tsconfig script; the real
# aeb and lib/cache do the rest.
#
# Assertions:
#   1. first build runs tsc and emits the output
#   2. after deleting target/ and the output, the same inputs are a cache HIT:
#      tsc is not run again and the output is restored
#   3. changing a .ts source misses the cache: tsc runs again
#
# Usage: AETHER=/path/to/ae ./itests/ts-tsc-files-cached.sh
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

P="$WORK/proj"; OUT="$WORK/out"
mkdir -p "$WORK/bin" "$P/shared-build-scripts" "$P/app"
(cd "$P" && git init -q .)
cat > "$P/shared-build-scripts/generate-typescript-base-tsconfig-json.sh" <<'EOT'
#!/bin/sh
echo '{"compilerOptions":{"paths":{}}}' > "$3/base-tsconfig.json"
EOT
chmod +x "$P/shared-build-scripts/generate-typescript-base-tsconfig-json.sh"
echo '{}' > "$P/app/tsconfig.json"
echo 'export const x: number = 1;' > "$P/app/a.ts"
cat > "$WORK/bin/tsc" <<EOT
#!/bin/sh
case "\$1" in --version) echo "Version 5.0.0-stub"; exit 0;; esac
echo run >> "$WORK/tsc.log"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = "--outDir" ] && out="\$2"; shift; done
mkdir -p "\$out"; echo "// compiled" > "\$out/a.js"
EOT
chmod +x "$WORK/bin/tsc"
cat > "$P/app/.build.ae" <<EOT
import bldr
import ts
main() {
    bldr.build() {
        ts.tsc_files() { out_dir("$OUT") }
    }
}
EOT
run() { (cd "$P" && PATH="$WORK/bin:$PATH" "$AEB" app/.build.ae >"$WORK/out.txt" 2>&1); }
runs() { [ -f "$WORK/tsc.log" ] && wc -l < "$WORK/tsc.log" | tr -d ' ' || echo 0; }

echo "1. first build"
if run; then pass "build passed"; else fail "build failed: $(tail -6 "$WORK/out.txt")"; fi
[ "$(runs)" = 1 ] && pass "tsc ran once" || fail "tsc ran $(runs) times"
[ -f "$OUT/a.js" ] && pass "output emitted" || fail "no output"

echo "2. same inputs, fresh target/ and no output: cache hit"
rm -rf "$P/target" "$OUT"
if run; then pass "build passed"; else fail "build failed: $(tail -6 "$WORK/out.txt")"; fi
[ "$(runs)" = 1 ] && pass "tsc not run again" || fail "tsc ran $(runs) times (expected still 1)"
[ -f "$OUT/a.js" ] && pass "output restored from cache" || fail "output not restored"
grep -q '\[hit\]' "$WORK/out.txt" && pass "telemetry row says [hit]" || fail "no [hit] in the telemetry"

echo "3. source changed: cache miss"
rm -rf "$P/target" "$OUT"
echo 'export const x: number = 2;' > "$P/app/a.ts"
if run; then pass "build passed"; else fail "build failed"; fi
[ "$(runs)" = 2 ] && pass "tsc ran again" || fail "tsc ran $(runs) times (expected 2)"

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
