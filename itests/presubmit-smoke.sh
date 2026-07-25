#!/usr/bin/env bash
# itests/presubmit-smoke.sh — end-to-end verification of the named-target-set
# convention (docs/presubmit-target-sets.md): a dot-prefixed `.ae` file whose
# body is nothing but `build.dep(...)` lines is a runnable set of targets.
#
# This is a Level-4 check the unit suite (tests/run.sh) can't do: the claim
# isn't about a command string, it's about DAG construction, scheduling,
# classification and exit-code propagation through a node that does no work
# of its own. It needs a real `aeb` driving a real build.
#
# No language toolchain is needed — the fixture's members are trivial
# `bash.test` nodes — so unlike cache-smoke.sh this runs anywhere a working
# `ae` can link a multi-module build (Linux today; see TODO.md "macOS link
# step"). The fixture is synthesised in a temp dir, so nothing is committed
# and no upstream fetch is required.
#
# Assertions:
#   1. MEMBERS RUN     — every dep of the set executes (its log exists,
#                        with the expected marker in it)
#   2. ORDER           — the aggregator topo-sorts AFTER its members
#   3. CLASSIFICATION  — the set self-classifies by filename ("presubmit"
#                        appears as a type in the summary line), with no
#                        runner-side special-casing
#   4. GREEN EXIT      — all members passing => exit 0
#   5. RED EXIT        — one member failing => NON-ZERO exit, and the
#                        passing sibling still records rc 0
#   6. META + GUARD    — meta.desc works on a node that builds nothing;
#                        an inline working-tree guard gates both ways
#   7. TOOL PROBE      — the SAFE guard shape (reproducible) gates both
#                        ways, and the os.exec form's silent-pass trap
#                        still holds
#
# Assertion 5 is the load-bearing one: a target set whose failures don't
# propagate is worse than no target set at all, because it reports green.
# Assertions 6-7 pin claims docs/presubmit-target-sets.md makes about
# guards — including two ways to write one that silently reports green.
#
# Usage:
#   cd itests && AETHER=/path/to/ae ./presubmit-smoke.sh
#   AEB=/path/to/aeb AETHER=/path/to/ae ./presubmit-smoke.sh
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

# ---------------------------------------------------------------------------
# Fixture: two member targets and one dep-only aggregator.
#
#   .presubmit.ae ---> alpha/.build.ae
#                 \--> beta/.tests.ae
#
# Members use bash.test (a real SDK builder) rather than raw os.system:
# os.system's exit code must be explicitly propagated, and a discarded one
# is exactly the booby trap the docs warn about. Using the SDK keeps this
# test about the SET, not about the escape hatch.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/alpha" "$WORK/beta"

# bash.test's `script(...)` names a script FILE (relative to the module
# dir), not an inline command — so each member gets a real .sh alongside
# its build file.
cat > "$WORK/alpha/check.sh" <<'EOF'
#!/usr/bin/env bash
echo ALPHA-RAN
exit 0
EOF
chmod +x "$WORK/alpha/check.sh"

cat > "$WORK/alpha/.build.ae" <<'EOF'
import build (start)
import bash (test, script)

aeb(cap) {
    b = build.start()
    bash.test(b) {
        script("check.sh")
    }
}
EOF

write_beta() {
    # $1: the exit code beta's test script returns (controls pass/fail).
    cat > "$WORK/beta/check.sh" <<EOF
#!/usr/bin/env bash
echo BETA-RAN
exit $1
EOF
    chmod +x "$WORK/beta/check.sh"
}

cat > "$WORK/beta/.tests.ae" <<'EOF'
import build (start)
import bash (test, script)

aeb(cap) {
    b = build.start()
    bash.test(b) {
        script("check.sh")
    }
}
EOF

cat > "$WORK/.presubmit.ae" <<'EOF'
import build (start, dep)

aeb(cap) {
    b = build.start()
    build.dep(b, "alpha/.build.ae")
    build.dep(b, "beta/.tests.ae")
}
EOF

# ---------------------------------------------------------------------------
# Round 1 — all members green.
# ---------------------------------------------------------------------------
echo "presubmit-smoke: round 1 (all members passing)"
write_beta 0
rm -rf "$WORK/target"
OUT1="$WORK/out1.txt"
( cd "$WORK" && "$AEB" .presubmit.ae ) > "$OUT1" 2>&1
RC1=$?

# 4. GREEN EXIT
if [ "$RC1" -eq 0 ]; then
    pass "all-green set exits 0"
else
    fail "all-green set exited $RC1, expected 0"
    sed -e 's/^/    | /' "$OUT1" | head -30
fi

# 1. MEMBERS RUN — both dep bodies executed. Node stdout goes to per-node
#    logs under target/.aeb/logs/, not the terminal.
if grep -rq "ALPHA-RAN" "$WORK/target/.aeb/logs/" 2>/dev/null; then
    pass "member alpha/.build.ae executed"
else
    fail "member alpha/.build.ae did not execute (no ALPHA-RAN in logs)"
fi
if grep -rq "BETA-RAN" "$WORK/target/.aeb/logs/" 2>/dev/null; then
    pass "member beta/.tests.ae executed"
else
    fail "member beta/.tests.ae did not execute (no BETA-RAN in logs)"
fi

# 2. ORDER — the aggregator sorts after both members.
SORTED="$WORK/target/_aeb/_sorted.txt"
if [ -f "$SORTED" ]; then
    A_LINE=$(grep -n 'alpha/\.build\.ae'  "$SORTED" | head -1 | cut -d: -f1)
    B_LINE=$(grep -n 'beta/\.tests\.ae'   "$SORTED" | head -1 | cut -d: -f1)
    P_LINE=$(grep -n '^\.presubmit\.ae$'  "$SORTED" | head -1 | cut -d: -f1)
    if [ -n "$A_LINE" ] && [ -n "$B_LINE" ] && [ -n "$P_LINE" ] \
       && [ "$P_LINE" -gt "$A_LINE" ] && [ "$P_LINE" -gt "$B_LINE" ]; then
        pass "aggregator topo-sorts after its members"
    else
        fail "topo order wrong (alpha=$A_LINE beta=$B_LINE presubmit=$P_LINE)"
        sed -e 's/^/    | /' "$SORTED"
    fi
else
    fail "no _sorted.txt produced"
fi

# 3. CLASSIFICATION — "presubmit" appears as a type, purely from the
#    filename. Matches the summary line, e.g.
#      aeb: 1 build + 1 tests + 1 presubmit
if grep -Eq '^aeb: .*[0-9]+ presubmit' "$OUT1"; then
    pass "set self-classifies as type 'presubmit' in the summary"
else
    fail "summary line lacks a 'presubmit' type count"
    grep -E '^aeb: ' "$OUT1" | sed -e 's/^/    | /'
fi

# ---------------------------------------------------------------------------
# Round 2 — one member red. The whole point: this must NOT report green.
# ---------------------------------------------------------------------------
echo "presubmit-smoke: round 2 (one member failing)"
write_beta 3
rm -rf "$WORK/target"
OUT2="$WORK/out2.txt"
( cd "$WORK" && "$AEB" .presubmit.ae ) > "$OUT2" 2>&1
RC2=$?

# 5. RED EXIT
if [ "$RC2" -ne 0 ]; then
    pass "set with a failing member exits non-zero ($RC2)"
else
    fail "set with a failing member exited 0 — a red set reported green"
    sed -e 's/^/    | /' "$OUT2" | head -30
fi

# ...and the failure is attributed, not just aggregated: the passing
# sibling still records rc 0 while the failing member records non-zero.
RC_DIR="$WORK/target/.aeb/rc"
ALPHA_RC_FILE=$(ls "$RC_DIR"/alpha_*.rc 2>/dev/null | head -1)
BETA_RC_FILE=$(ls "$RC_DIR"/beta_*.rc  2>/dev/null | head -1)
if [ -n "$ALPHA_RC_FILE" ] && [ "$(cat "$ALPHA_RC_FILE")" = "0" ]; then
    pass "passing sibling still records rc 0"
else
    fail "passing sibling's rc marker is not 0 (file='$ALPHA_RC_FILE')"
fi
if [ -n "$BETA_RC_FILE" ] && [ "$(cat "$BETA_RC_FILE")" != "0" ]; then
    pass "failing member records non-zero rc"
else
    fail "failing member's rc marker is not non-zero (file='$BETA_RC_FILE')"
fi

# ---------------------------------------------------------------------------
# Round 3 — meta.desc on a dep-only node, plus an inline working-tree guard
# (docs/presubmit-target-sets.md "Inline guards"). Both are claims the doc
# makes, so both get tested: meta.desc must not break a node that produces
# no artifact, and the guard must gate on tree cleanliness in BOTH
# directions.
#
# Note the fixture .gitignore: without it the guard self-trips on aeb's own
# `target/` output — the trap the doc warns about, and worth encoding here
# so nobody "fixes" the warning back out of the docs.
# ---------------------------------------------------------------------------
echo "presubmit-smoke: round 3 (meta.desc + inline git guard)"
GUARD="$WORK/guard"
mkdir -p "$GUARD/alpha"
cp "$WORK/alpha/check.sh" "$GUARD/alpha/check.sh"
cp "$WORK/alpha/.build.ae" "$GUARD/alpha/.build.ae"
printf 'target/\nout*.txt\n' > "$GUARD/.gitignore"

cat > "$GUARD/.presubmit.ae" <<'EOF'
import build (start, dep)
import meta (desc)
import std.os
import std.string

aeb(cap) {
    b = build.start()
    meta.desc(b, "Must be green before push")

    build.dep(b, "alpha/.build.ae")

    dirty, err = os.exec("git status --porcelain")
    if string.length(dirty) > 0 {
        build.fail(b, "working tree not clean:\n${dirty}")
    }
}
EOF

( cd "$GUARD" \
  && git init -q . \
  && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1

# 6. CLEAN TREE — meta.desc compiles on a dep-only node and the guard passes.
OUT3="$GUARD/out3.txt"
( cd "$GUARD" && "$AEB" .presubmit.ae ) > "$OUT3" 2>&1
RC3=$?
if [ "$RC3" -eq 0 ]; then
    pass "meta.desc + guard on a clean tree exits 0"
else
    fail "clean-tree guarded set exited $RC3, expected 0"
    grep -vE '^warning|^Type checking|^$' "$OUT3" | head -20 | sed -e 's/^/    | /'
fi

# 7. DIRTY TREE — a single untracked file must fail the set.
echo scratch > "$GUARD/stray.txt"
OUT4="$GUARD/out4.txt"
( cd "$GUARD" && "$AEB" .presubmit.ae ) > "$OUT4" 2>&1
RC4=$?
if [ "$RC4" -ne 0 ] && grep -q "working tree not clean" "$OUT4"; then
    pass "inline guard fails the set on an untracked file"
else
    fail "dirty tree exited $RC4 without the guard message"
    grep -vE '^warning|^Type checking|^$' "$OUT4" | head -20 | sed -e 's/^/    | /'
fi

# ---------------------------------------------------------------------------
# Round 4 — the SAFE guard shape (a reproducible tool probe), and the
# os.exec-vs-os.system trap the doc calls out.
#
# os.exec's second return is an EXECUTION error, not a non-zero exit
# status, so `if string.length(err) > 0` never fires for a command that
# runs and exits 1 — another silent-green trap in the same family as the
# discarded `_ = os.system(...)`. The doc's probe therefore uses
# os.system; this round pins both halves of that claim.
# ---------------------------------------------------------------------------
echo "presubmit-smoke: round 4 (tool probe; os.system vs os.exec)"
PROBE="$WORK/probe"
mkdir -p "$PROBE/alpha"
cp "$WORK/alpha/check.sh" "$PROBE/alpha/check.sh"
cp "$WORK/alpha/.build.ae" "$PROBE/alpha/.build.ae"

write_probe() {
    # $1: tool name to probe for. Uses os.system — the documented form.
    cat > "$PROBE/.presubmit.ae" <<EOF
import build (start, dep)
import std.os

aeb(cap) {
    b = build.start()
    build.dep(b, "alpha/.build.ae")

    if os.system("command -v $1 >/dev/null 2>&1") != 0 {
        build.fail(b, "presubmit needs $1 on PATH")
    }
}
EOF
}

# 8. ABSENT TOOL -> set fails.
write_probe "definitely-not-a-real-tool-xyz"
rm -rf "$PROBE/target"
OUT5="$PROBE/out5.txt"
( cd "$PROBE" && "$AEB" .presubmit.ae ) > "$OUT5" 2>&1
RC5=$?
if [ "$RC5" -ne 0 ] && grep -q "needs definitely-not-a-real-tool-xyz" "$OUT5"; then
    pass "tool probe fails the set when the tool is absent"
else
    fail "absent-tool probe exited $RC5 without the expected message"
fi

# 9. PRESENT TOOL -> set passes.
write_probe "bash"
rm -rf "$PROBE/target"
OUT6="$PROBE/out6.txt"
( cd "$PROBE" && "$AEB" .presubmit.ae ) > "$OUT6" 2>&1
RC6=$?
if [ "$RC6" -eq 0 ]; then
    pass "tool probe passes the set when the tool is present"
else
    fail "present-tool probe exited $RC6, expected 0"
    grep -vE '^warning|^Type checking|^$' "$OUT6" | head -20 | sed -e 's/^/    | /'
fi

# 10. THE TRAP — the os.exec form does NOT catch a missing tool. Pinned so
#     nobody "simplifies" the doc's probe back to os.exec.
cat > "$PROBE/.presubmit.ae" <<'EOF'
import build (start, dep)
import std.os
import std.string

aeb(cap) {
    b = build.start()
    build.dep(b, "alpha/.build.ae")

    _, probe_err = os.exec("command -v definitely-not-a-real-tool-xyz")
    if string.length(probe_err) > 0 {
        build.fail(b, "presubmit needs definitely-not-a-real-tool-xyz on PATH")
    }
}
EOF
rm -rf "$PROBE/target"
OUT7="$PROBE/out7.txt"
( cd "$PROBE" && "$AEB" .presubmit.ae ) > "$OUT7" 2>&1
RC7=$?
if [ "$RC7" -eq 0 ]; then
    pass "os.exec probe silently passes on a missing tool (trap confirmed)"
else
    fail "os.exec probe exited $RC7 — the documented trap no longer holds," \
         "so docs/presubmit-target-sets.md needs revisiting"
fi

# ---------------------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
    echo "presubmit-smoke: PASS"
    exit 0
fi
echo "presubmit-smoke: FAIL ($FAILURES assertion(s))"
exit 1
