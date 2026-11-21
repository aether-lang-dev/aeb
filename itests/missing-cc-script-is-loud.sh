#!/usr/bin/env bash
# itests/missing-cc-script-is-loud.sh — an aeb install that lacks tools/aeb-cc.sh
# says so and stops; it does not carry on with the object cache off.
#
# aeb-link compiles the orchestrator's translation units through tools/aeb-cc.sh
# (in parallel, each cached by content). When that file was missing it fell back
# to one plain compile and said nothing: every released aeb, whose payload had
# lost the script, ran with no object cache and nobody could tell. A missing
# script is a broken install, so aeb-link now stops with a FATAL naming the file;
# AEB_NO_OBJ_CACHE=1 is the way to build without the cache on purpose.
#
# A copy of this tree with tools/aeb-cc.sh deleted, a trivial bash.test node:
#   1. the build fails, and the output names tools/aeb-cc.sh
#   2. the same build with AEB_NO_OBJ_CACHE=1 passes (the explicit opt-out)
#   3. with the script restored the build passes and the cache is in use
#      ("aeb-cc: miss/hit" lines)
#
# Needs a C compiler (aeb links its orchestrator). POSIX hosts only.
# Usage: AETHER=/path/to/ae ./itests/missing-cc-script-is-loud.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "  SKIP: Windows"; exit 0 ;; esac
AETHER="${AETHER:-ae}"
command -v "$AETHER" >/dev/null 2>&1 || { echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; }
export AETHER

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aeb_nocc.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT INT TERM
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
echo "[missing-cc-script-is-loud]"

# the working tree's sources, no built helpers
TREE="$WORK/aeb"
mkdir -p "$TREE"
( cd "$REPO_ROOT" && git ls-files -z -c -o --exclude-standard -- aeb AETHER_PIN AETHER_FETCH Makefile lib tools veto sandbox | tar --null -T - -cf - ) | tar -xf - -C "$TREE"
rm -f "$TREE/tools/aeb-cc.sh"

PROJ="$WORK/proj"
mkdir -p "$PROJ/app"
printf '#!/usr/bin/env bash\necho ok\n' > "$PROJ/app/t.sh"; chmod +x "$PROJ/app/t.sh"
cat > "$PROJ/app/.tests.ae" <<'AE'
import bldr
import bash
aeb(cap) {
    bldr.build() {
        bash.test() { script("t.sh") }
    }
}
AE
( cd "$PROJ" && git init -q . )
run() {  # run LOG [ENV=VAL...]
    local log="$1"; shift
    ( cd "$PROJ" && env "$@" AEB_CACHE_DIR="$WORK/cache" bash "$TREE/aeb" app/.tests.ae ) > "$WORK/$log" 2>&1
}

echo
echo "1: no tools/aeb-cc.sh"
if run missing.log; then
    fail "the build passed without tools/aeb-cc.sh, silently"
else
    if grep -q "aeb-link: FATAL.*aeb-cc.sh" "$WORK/missing.log"; then pass "the build stops and the output names tools/aeb-cc.sh"; else fail "the build failed but did not name tools/aeb-cc.sh"; tail -8 "$WORK/missing.log" | sed 's/^/        /'; fi
fi
if grep -q "AEB_NO_OBJ_CACHE" "$WORK/missing.log"; then pass "and says how to build without the cache on purpose"; else fail "the message does not mention AEB_NO_OBJ_CACHE"; fi

echo
echo "2: AEB_NO_OBJ_CACHE=1"
if run optout.log AEB_NO_OBJ_CACHE=1 && grep -q "1/1 PASS" "$WORK/optout.log"; then pass "the explicit opt-out builds without the script"; else fail "the build with AEB_NO_OBJ_CACHE=1 failed"; tail -8 "$WORK/optout.log" | sed 's/^/        /'; fi

echo
echo "3: the script restored"
cp "$REPO_ROOT/tools/aeb-cc.sh" "$TREE/tools/aeb-cc.sh"
if run ok.log && grep -q "1/1 PASS" "$WORK/ok.log"; then pass "the build passes"; else fail "the build failed with the script in place"; tail -8 "$WORK/ok.log" | sed 's/^/        /'; fi
if grep -q "^aeb-cc: \(miss\|hit\)" "$WORK/ok.log"; then pass "and the object cache is in use"; else fail "no 'aeb-cc: miss/hit' line: the object cache was not used"; fi

echo
if [ "$FAILURES" -eq 0 ]; then echo "missing-cc-script-is-loud: all assertions passed"; exit 0; fi
echo "missing-cc-script-is-loud: $FAILURES assertion(s) failed"
exit 1
