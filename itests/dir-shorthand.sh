#!/usr/bin/env bash
# A bare directory, as a target or in dep(), stands for the one build file in
# it, whatever that file is called. aeb keeps no list of preferred names
# (.build.ae, .tests.ae, .dist.ae): a directory with several build files is
# refused, naming them, so the caller says which.
#
# A real aeb driving a real build of a fixture made in a temp dir. The nodes
# are bash.test, so no language toolchain is needed.
#
#   lib/.compile.ae                     the only build file in lib/
#   app/.build.ae    dep("lib")         a directory dep on it
#   both/.build.ae, both/.tests.ae      two build files in one directory
#   user/.build.ae   dep("both")        a directory dep that cannot be decided
#
# Assertions:
#   1. `aeb lib` builds lib/.compile.ae
#   2. `aeb app` builds lib/.compile.ae first, through dep("lib")
#   3. `aeb both` is refused, naming both files; nothing is built
#   4. `aeb user` is refused, naming the dep, both files and the build file
#      that declared it; nothing is built
#   5. `aeb both/.tests.ae`, named in full, builds
#
# Usage:
#   cd itests && AETHER=/path/to/ae ./dir-shorthand.sh
#
# Exit code: 0 if every assertion passed; 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
export AETHER

if [ ! -x "$AEB" ]; then
    echo "error: aeb not found/executable at '$AEB' (set \$AEB)" >&2
    exit 1
fi
if ! command -v "$AETHER" >/dev/null 2>&1; then
    echo "error: '$AETHER' not found (set \$AETHER=/path/to/ae)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# node <dir> <file> <marker> [<dep>]: a bash.test node that echoes <marker>.
node() {
    mkdir -p "$WORK/$1"
    script="check-$3.sh"
    printf '#!/usr/bin/env bash\necho %s\nexit 0\n' "$3" > "$WORK/$1/$script"
    chmod +x "$WORK/$1/$script"
    {
        echo 'import bldr'
        echo 'import bash'
        echo 'import bash(script)'
        echo
        echo 'main() {'
        echo '    bldr.build() {'
        [ -n "${4:-}" ] && echo "        dep(\"$4\")"
        echo '        bash.test() {'
        echo "            script(\"$script\")"
        echo '        }'
        echo '    }'
        echo '}'
    } > "$WORK/$1/$2"
}

node lib  .compile.ae LIB-RAN
node app  .build.ae   APP-RAN lib
node both .build.ae   BOTH-BUILD-RAN
node both .tests.ae   BOTH-TESTS-RAN both/.build.ae
node user .build.ae   USER-RAN both

# run <out> <target>: a clean build of <target>; its output in $WORK/<out>.
run() {
    rm -rf "$WORK/target"
    ( cd "$WORK" && "$AEB" "$2" ) > "$WORK/$1" 2>&1
}
ran() { grep -rq "$1" "$WORK/target/.aeb/logs/" 2>/dev/null; }
show() { sed -e 's/^/    | /' "$WORK/$1" | head -30; }

echo "dir-shorthand: a directory with one build file"
run out1 lib; RC=$?
if [ "$RC" -eq 0 ] && ran LIB-RAN; then
    pass "aeb lib builds lib/.compile.ae"
else
    fail "aeb lib: exit $RC, or lib/.compile.ae did not run"; show out1
fi

run out2 app; RC=$?
SORTED="$WORK/target/_aeb/_sorted.txt"
L=$(grep -n 'lib/\.compile\.ae' "$SORTED" 2>/dev/null | head -1 | cut -d: -f1)
A=$(grep -n 'app/\.build\.ae' "$SORTED" 2>/dev/null | head -1 | cut -d: -f1)
if [ "$RC" -eq 0 ] && ran LIB-RAN && ran APP-RAN && [ -n "$L" ] && [ -n "$A" ] && [ "$A" -gt "$L" ]; then
    pass "dep(\"lib\") is lib/.compile.ae, built before app"
else
    fail "aeb app: exit $RC, lib=$L app=$A"; show out2
fi

echo "dir-shorthand: a directory with several build files"
run out3 both; RC=$?
if [ "$RC" -ne 0 ] && grep -q "both has several build files (.build.ae, .tests.ae)" "$WORK/out3" \
   && ! ran BOTH-BUILD-RAN && ! ran BOTH-TESTS-RAN; then
    pass "aeb both is refused, naming both files"
else
    fail "aeb both: exit $RC, expected a refusal naming .build.ae and .tests.ae"; show out3
fi

run out4 user; RC=$?
if [ "$RC" -ne 0 ] && grep -q 'dep("both"): both has several build files (.build.ae, .tests.ae)' "$WORK/out4" \
   && grep -q "in user/.build.ae" "$WORK/out4" && ! ran USER-RAN; then
    pass "dep(\"both\") is refused, naming the dep, both files and user/.build.ae"
else
    fail "aeb user: exit $RC, expected a refusal of dep(\"both\")"; show out4
fi

run out5 both/.tests.ae; RC=$?
if [ "$RC" -eq 0 ] && ran BOTH-TESTS-RAN && ran BOTH-BUILD-RAN; then
    pass "aeb both/.tests.ae, named in full, builds"
else
    fail "aeb both/.tests.ae: exit $RC"; show out5
fi

if [ "$FAILURES" -ne 0 ]; then
    echo "dir-shorthand: $FAILURES assertion(s) failed"
    exit 1
fi
echo "dir-shorthand: all assertions passed"
exit 0
