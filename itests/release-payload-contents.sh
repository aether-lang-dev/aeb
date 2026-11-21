#!/usr/bin/env bash
# itests/release-payload-contents.sh — the staged release payload holds what aeb
# needs to run, and only that.
#
# release/stage-payload.sh makes the tree both the bootstrap tarball and every
# platform bundle are built from. It once deleted every executable file in
# tools/ that was not .ae or .md, to get rid of built helpers a developer's
# checkout holds, and so also deleted the scripts aeb itself runs from there:
# tools/aeb-cc.sh (aeb-link's parallel, cached compile: the object cache was
# off in every released aeb), tools/aeb-watch, tools/container/aeb-ctr and more.
# It also named a docs file by a path that does not exist and hid the failure.
#
# This test stages from a throwaway clone of this checkout with built-looking
# junk planted in it (a helper binary, its toolchain stamp, a .pdb, a built
# libaether_sandbox.so, the resolver jar) and has release/check-payload.sh judge
# the result: every tracked runtime file present with its executable bit, every
# tools/ name the runtime sources mention accounted for, and nothing untracked.
# It also feeds check-payload a payload with a script missing, one with a binary
# added and one with a .pdb added, and wants each refused (a check that cannot
# fail proves nothing).
#
# No compiler, no ae, no network. Usage: ./itests/release-payload-contents.sh
# Exit: 0 if every assertion passed; 1 otherwise. POSIX hosts only.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "  SKIP: Windows"; exit 0 ;; esac

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aeb_payload.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "[release-payload-contents]"

# A clone of the working tree's tracked files (the working tree, not HEAD, so a
# change under test is what is staged), as a git checkout, with junk planted.
CLONE="$WORK/clone"
mkdir -p "$CLONE"
( cd "$REPO_ROOT" && git ls-files -z -c -o --exclude-standard | tar --null -T - -cf - ) | tar -xf - -C "$CLONE"
( cd "$CLONE" && git init -q . && git add -A >/dev/null 2>&1 \
    && git -c user.email=t@example.invalid -c user.name=t commit -q -m snapshot ) \
    || { echo "error: could not snapshot the tree"; exit 1; }
for h in aeb-main aeb-link aeb-driver topo-sort; do
    printf '\177ELF not really\n' > "$CLONE/tools/$h"; chmod +x "$CLONE/tools/$h"
    printf '/some/aetherc (0.0.1)\n' > "$CLONE/tools/$h.toolchain"
done
printf 'debug symbols\n' > "$CLONE/tools/aeb-main.pdb"
printf '\177ELF so\n' > "$CLONE/tools/libaether_sandbox.so"; chmod +x "$CLONE/tools/libaether_sandbox.so"
printf 'PK jar\n' > "$CLONE/tools/aeb-resolve.jar"
printf 'int x;\n' > "$CLONE/tools/aeb-main.c"

echo
echo "1: stage from a tree that holds built files"
if ( cd "$CLONE" && release/stage-payload.sh v0.0.0-itest "$WORK/stage" ) > "$WORK/stage.log" 2>&1; then
    pass "stage-payload.sh ran"
else
    fail "stage-payload.sh failed"; sed 's/^/        /' "$WORK/stage.log"
fi
if "$CLONE/release/check-payload.sh" "$WORK/stage" "$CLONE" > "$WORK/check.log" 2>&1; then
    pass "the payload has every tracked runtime file and nothing untracked"
else
    fail "check-payload.sh refused the payload:"; sed 's/^/        /' "$WORK/check.log"
fi

echo
echo "2: the scripts aeb runs from tools/ are in the payload, executable"
for s in aeb-cc.sh aeb-watch resolve-imports.sh cargo-crate-to-ae.sh cargo-to-deps-ae.sh container/aeb-ctr; do
    if [ -x "$WORK/stage/tools/$s" ]; then pass "tools/$s"; else fail "tools/$s is missing or not executable"; fi
done
[ -f "$WORK/stage/tools/gh-release-fetch.sh" ] && pass "tools/gh-release-fetch.sh" || fail "tools/gh-release-fetch.sh is missing"
[ -f "$WORK/stage/docs/guides/aeb-host-vm-or-container-setup.md" ] && pass "the host setup guide" || fail "docs/guides/aeb-host-vm-or-container-setup.md is missing"

echo
echo "3: no built file came along"
extra="$(cd "$WORK/stage" && find . -type f \( -name '*.toolchain' -o -name '*.pdb' -o -name '*.so' -o -name '*.jar' -o -name '*.c' \) | sort)"
if [ -z "$extra" ]; then pass "no stamp, .pdb, .so, .jar or .c in the payload"; else fail "built files in the payload:"; echo "$extra" | sed 's/^/        /'; fi
bins=""
for h in aeb-main aeb-link aeb-driver topo-sort; do [ -e "$WORK/stage/tools/$h" ] && bins="$bins $h"; done
if [ -z "$bins" ]; then pass "no helper binary in the payload"; else fail "helper binaries in the payload:$bins"; fi

echo
echo "4: check-payload refuses a bad payload"
mutate_and_check() {  # mutate_and_check NAME COMMAND-in-$P
    local name="$1" P="$WORK/bad-$1"
    cp -R "$WORK/stage" "$P"
    ( cd "$P" && eval "$2" )
    if "$CLONE/release/check-payload.sh" "$P" "$CLONE" > "$WORK/bad-$name.log" 2>&1; then
        fail "$name: check-payload accepted it"
    else
        pass "$name: refused ($(sed -n 1p "$WORK/bad-$name.log" | cut -c1-90))"
    fi
}
mutate_and_check "script-missing"       'rm tools/aeb-cc.sh'
mutate_and_check "script-lost-its-bit"  'chmod -x tools/aeb-watch'
mutate_and_check "docs-missing"         'rm docs/guides/aeb-host-vm-or-container-setup.md'
mutate_and_check "binary-added"         'printf x > tools/topo-sort; chmod +x tools/topo-sort'
mutate_and_check "stamp-added"          'printf x > tools/aeb-main.toolchain'
mutate_and_check "pdb-added"            'printf x > tools/aeb-main.pdb'
mutate_and_check "version-missing"      'rm VERSION'

echo
echo "5: check-payload notices a runtime script nobody shipped"
# A new runtime script the staging does not know about: the sources name it,
# git tracks it, and a staging that skipped it must fail the check.
( cd "$CLONE" && printf '#!/bin/sh\necho hi\n' > tools/aeb-newthing.sh && chmod +x tools/aeb-newthing.sh \
    && printf '\nrunthing() { return os.system("sh tools/aeb-newthing.sh") }\n' >> tools/aeb-graph.ae \
    && git add -A && git -c user.email=t@example.invalid -c user.name=t commit -q -m newthing )
if "$CLONE/release/check-payload.sh" "$WORK/stage" "$CLONE" > "$WORK/new.log" 2>&1; then
    fail "a payload without the new runtime script was accepted"
else
    grep -q "aeb-newthing.sh" "$WORK/new.log" && pass "refused, naming tools/aeb-newthing.sh" || { fail "refused, but not by name"; sed 's/^/        /' "$WORK/new.log"; }
fi
( cd "$CLONE" && release/stage-payload.sh v0.0.0-itest "$WORK/stage2" >/dev/null 2>&1 )
if "$CLONE/release/check-payload.sh" "$WORK/stage2" "$CLONE" > "$WORK/new2.log" 2>&1; then
    pass "restaged, the new script is shipped and the payload passes"
else
    fail "a restage with the new script did not pass:"; sed 's/^/        /' "$WORK/new2.log"
fi

echo
if [ "$FAILURES" -eq 0 ]; then echo "release-payload-contents: all assertions passed"; exit 0; fi
echo "release-payload-contents: $FAILURES assertion(s) failed"
exit 1
