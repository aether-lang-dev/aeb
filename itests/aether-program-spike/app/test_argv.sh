#!/usr/bin/env bash
# Argv + link-direction assertion for the Aether-main() program.
#
# bash.test runs this from the monorepo root, so the binary is under
# target/. Run it with a known argument and assert that:
#   - argv reached the Aether main()      (argv1=script.js)
#   - the sibling Aether lib was linked    (greet=hi-script.js)
#   - the C library was linked             (triple=21)
set -euo pipefail

BIN="$(find target -type f -name app -perm -u+x 2>/dev/null | head -1)"
if [ -z "${BIN}" ]; then
    echo "FAIL: app binary not found under target/" >&2
    exit 1
fi

OUT="$("${BIN}" script.js)"
echo "${OUT}"

fail() { echo "FAIL: $1" >&2; exit 1; }
grep -qx "argv1=script.js"     <<<"${OUT}" || fail "argv did not reach main()"
grep -qx "greet=hi-script.js"  <<<"${OUT}" || fail "sibling Aether lib not linked"
grep -qx "triple=21"           <<<"${OUT}" || fail "C library not linked"

echo "PASS: Aether main() saw argv; linked sibling .ae lib + C lib; no committed C main"
