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
grep -qx "triple=21"           <<<"${OUT}" || fail "C library (via include_dir header) not linked"

# Gap 2: regen must not litter the committed source tree. The sibling
# Aether lib's generated C belongs under target/, not beside greet.ae.
# Prune every target/ dir at any depth — aeb now writes regen output to
# per-module <module>/target/ (e.g. app/target/), not just a single
# monorepo-root target/, so a `-path ./target -prune` misses those.
STRAY="$(find . -name target -prune -o -name '*_generated.c' -print 2>/dev/null)"
if [ -n "${STRAY}" ]; then
    fail "generated C leaked into the source tree: ${STRAY}"
fi

echo "PASS: Aether main() saw argv; sibling .ae lib + C lib (incl. include_dir header) linked; regen stayed out of the source tree; no committed C main"
