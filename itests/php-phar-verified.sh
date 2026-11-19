#!/usr/bin/env bash
# itests/php-phar-verified.sh — php.test only runs a downloaded phpunit phar
# whose sha256 matches the digest the build file pins.
#
# php.test used to `curl -fsSL` the phar and run it with no integrity check.
# Fixture: a local HTTP server (python3) serves a fake "phar"; a stub `php` on
# PATH logs its argv, so no PHP toolchain is needed; a real aeb run drives it.
#
# Assertions:
#   1. correct phpunit_phar_sha256 -> downloaded, php runs the phar, exit 0
#   2. a copy already on disk with the right digest is not downloaded again
#   3. wrong digest                -> node FAILS, php never runs, the bad file is removed
#   4. phpunit_phar_url with no phpunit_phar_sha256 -> refused, nothing downloaded, php never runs
#   5. a tampered phar already on disk is replaced by the verified download
#
# Needs python3 (HTTP server) and shasum/sha256sum.
# Usage: AETHER=/path/to/ae ./itests/php-phar-verified.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
export AEB_CACHE_DIR="$WORK/cache"
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi

mkdir -p "$WORK/www" "$WORK/bin" "$WORK/proj/app"
(cd "$WORK/proj" && git init -q .)
printf 'pretend phpunit phar\n' > "$WORK/www/phpunit-1.0.0.phar"
GOOD="$(sha "$WORK/www/phpunit-1.0.0.phar")"
BAD="0000000000000000000000000000000000000000000000000000000000000000"

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
(cd "$WORK/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$WORK/http.log" 2>&1) &
SRV_PID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do curl -fs "http://127.0.0.1:$PORT/phpunit-1.0.0.phar" -o /dev/null 2>/dev/null && break; sleep 0.5; done
: > "$WORK/http.log"

cat > "$WORK/bin/php" <<EOT
#!/bin/sh
echo "php \$*" >> "$WORK/calls.log"
exit 0
EOT
chmod +x "$WORK/bin/php"

run() { # sha-setter-line
    rm -rf "$WORK/proj/target"; : > "$WORK/calls.log"
    cat > "$WORK/proj/app/.tests.ae" <<EOT
import bldr
import php
main() {
    bldr.build() {
        php.test() {
            phpunit_phar_url("http://127.0.0.1:$PORT/phpunit-1.0.0.phar")
            $1
        }
    }
}
EOT
    (cd "$WORK/proj" && PATH="$WORK/bin:$PATH" "$AEB" app/.tests.ae >"$WORK/out.txt" 2>&1)
}
PHAR="$WORK/proj/app/phpunit.phar"

echo "1. correct digest"
rm -f "$PHAR"
if run "phpunit_phar_sha256(\"$GOOD\")"; then pass "build passed"; else fail "build failed: $(tail -5 "$WORK/out.txt")"; fi
grep -q "phpunit.phar" "$WORK/calls.log" && pass "php ran the phar" || fail "php did not run the phar"
[ -f "$PHAR" ] && [ "$(sha "$PHAR")" = "$GOOD" ] && pass "phar on disk has the pinned digest" || fail "phar missing or wrong"

echo "2. verified copy on disk is reused"
: > "$WORK/http.log"
if run "phpunit_phar_sha256(\"$GOOD\")"; then pass "build passed"; else fail "build failed"; fi
grep -q "GET" "$WORK/http.log" && fail "downloaded again" || pass "no second download"

echo "3. wrong digest"
rm -f "$PHAR"
if run "phpunit_phar_sha256(\"$BAD\")"; then fail "build passed with a wrong digest"; else pass "build failed"; fi
[ -s "$WORK/calls.log" ] && fail "php ran an unverified phar" || pass "php never ran"
[ -f "$PHAR" ] && fail "unverified phar left on disk" || pass "bad phar removed"

echo "4. url without digest"
rm -f "$PHAR"; : > "$WORK/http.log"
if run ""; then fail "build passed without a pinned digest"; else pass "build failed"; fi
grep -q "GET" "$WORK/http.log" && fail "phar was downloaded unverified" || pass "nothing downloaded"
[ -s "$WORK/calls.log" ] && fail "php ran" || pass "php never ran"
grep -q "phpunit_phar_sha256" "$WORK/out.txt" && pass "says what to declare" || fail "no explanation"

echo "5. tampered copy on disk"
printf 'tampered\n' > "$PHAR"
if run "phpunit_phar_sha256(\"$GOOD\")"; then pass "build passed"; else fail "build failed: $(tail -5 "$WORK/out.txt")"; fi
[ "$(sha "$PHAR")" = "$GOOD" ] && pass "tampered phar replaced by the verified one" || fail "tampered phar still on disk"

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
