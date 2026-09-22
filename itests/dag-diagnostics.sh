#!/usr/bin/env bash
# itests/dag-diagnostics.sh — a malformed DAG must say what is wrong.
#
# Two ways to hand aeb a graph it cannot build, and the diagnostics both
# used to produce. They share a failure mode: aeb knew exactly what was
# wrong, said so once, then carried on far enough to bury the statement.
#
# --- 1. A dep() naming a file that is not there -----------------------------
#
# THE BUG THIS PREVENTS. The target-mode BFS in tools/aeb-main.ae enqueues
# "any unseen dep that exists on disk" and skips one that does not — but the
# dep stays in file_deps, so it was still written to target/_aeb/_edges.txt,
# still became a prerequisite of the referring node in target/.aeb/bldr.mk,
# and make stopped on it:
#
#   make: *** No rule to make target 'libs_shared_styles_.build.ae',
#             needed by 'apps_cart_.build.ae'.
#
# The referring node and everything downstream then never ran. How visible
# that was varied: a small graph at least rendered the node `FAILED`, but on
# nx-examples it rendered `0.00s [n/a]` — byte-identical to a node the
# visited set had deduped — with neither the summary, nor the FAILED
# roll-up, nor `_failures.jsonl` naming the missing file. Either way the only
# statement of the cause was that raw make line, carrying the MANGLED label
# rather than the source line that declared the dep, and scrolled off above
# whatever else the build printed.
#
# Found by the nx-examples itest, where apps/cart and apps/products both
# carried `dep("libs/shared/styles/.build.ae")` for an SCSS-only Nx library
# whose build file had never been written.
#
# WHY IT ERRORS RATHER THAN DROPPING THE EDGE. Dropping it would build the
# referrer as though it had no such dependency — a green build that skipped
# work, which is worse than a red one. Every word `extract-deps` emits is a
# repo-root-relative `.ae` path (maven and npm coordinates are filtered out
# there; `git:`/`npm:` forms resolve to real on-disk paths), so a word that
# is not on disk is never a legitimate shape — it is a typo, a moved file,
# or a node someone forgot to write.
#
# Needs no language toolchain and fetches nothing: the fixtures are three
# trivial nodes in a temp dir.
#
# --- 2. A dependency cycle --------------------------------------------------
#
# topo-sort detects a cycle, writes "error: circular dependency involving
# <file>" to stderr and exits 1. aeb-main ran it through bldr._sh_capture and
# checked only that call's SECOND return — which is an EXECUTION error ("could
# the process start"), not an exit status, the same os.exec trap AGENTS.md
# documents for probes. A topo-sort that ran and exited 1 therefore looked
# like success with empty output.
#
# That empty output became "0 targets". aeb then called gen-orchestrator with
# no file arguments, gen-orchestrator printed its USAGE LINE, the usage line
# was written out as the orchestrator's .ae source, and aetherc produced 19
# E0100 parse errors — beneath which aeb-link announced "the error above is
# the real cause". It was not. The one true line had scrolled off the top.
#
# Mutation-checked, and both mutations fail the SAME assertion class — the
# one about legibility, not about the exit code. Disable the missing-dep loop
# and round 1's naming assertion fails back to make's mangled-label error;
# disable the empty-sort guard and round 3 reports 19 E0100s again. Both
# times the exit-code assertions still pass, which is exactly why they are
# not the load-bearing ones: the exit code was already right, and what was
# missing was any way to tell WHAT was wrong.
#
# Usage:  ./dag-diagnostics.sh
# Exit:   0 all assertions pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="$REPO_ROOT/aeb"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[dag-diagnostics]"

if [ ! -x "$AEB" ]; then
    echo "  SKIP: no $AEB"
    exit 0
fi

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t aeb_dag_diag)"
trap 'rm -rf "$TMP"' EXIT INT TERM

W="$TMP/work"
mkdir -p "$W/a" "$W/b"
cat > "$W/b/.build.ae" <<'AE'
import bldr
aeb(cap) { bldr.build() { } }
AE

run_aeb() {   # run_aeb <target>
    ( cd "$W" && "$AEB" "$1" ) > "$TMP/out" 2>&1
    echo "$?" > "$TMP/rc"
}

# --- round 1: the dangling edge is named and fatal ---------------------------
echo
echo "round 1: a dep() naming a missing file"
cat > "$W/a/.build.ae" <<'AE'
import bldr
import bldr (dep)
aeb(cap) {
    bldr.build() {
        dep("b/.build.ae")
        dep("nope/.build.ae")
    }
}
AE

run_aeb "a/.build.ae"

if [ "$(cat "$TMP/rc")" != "0" ]; then
    pass "aeb exits non-zero"
else
    fail "a dangling dep() built green (exit 0)"
fi

# Both halves have to be named: which file declared it, and what it named.
# The make error this replaces gave the mangled label, not the source line.
if grep -q 'a/.build.ae' "$TMP/out" && grep -q 'nope/.build.ae' "$TMP/out"; then
    pass "the diagnostic names the referring file and the missing target"
else
    fail "diagnostic does not name both the referrer and the missing dep"
    sed 's/^/        /' "$TMP/out" | tail -10
fi

# --- round 2: a satisfied dep is untouched -----------------------------------
# The other direction, and the one that matters for not breaking every build:
# the check must be invisible when every edge resolves.
echo
echo "round 2: a graph whose deps all resolve"
cat > "$W/a/.build.ae" <<'AE'
import bldr
import bldr (dep)
aeb(cap) {
    bldr.build() {
        dep("b/.build.ae")
    }
}
AE
rm -rf "$W/target"

run_aeb "a/.build.ae"

if [ "$(cat "$TMP/rc")" = "0" ]; then
    pass "a fully-resolved graph still builds green"
else
    fail "a valid graph was rejected"
    sed 's/^/        /' "$TMP/out" | tail -10
fi

if ! grep -q "unresolved dep" "$TMP/out"; then
    pass "no spurious unresolved-dep diagnostic"
else
    fail "reported an unresolved dep in a graph that has none"
    sed 's/^/        /' "$TMP/out" | tail -10
fi

# Both nodes must have actually run — the edge is real, not merely tolerated.
if grep -q "build:   a" "$TMP/out" && grep -q "build:   b" "$TMP/out"; then
    pass "both nodes ran, in one graph"
else
    fail "the resolved graph did not run both nodes"
    sed 's/^/        /' "$TMP/out" | tail -10
fi

# --- round 3: a dependency cycle is reported, not buried ---------------------
# The cycle itself was always detected. What this pins is that aeb STOPS on
# it: an empty sort of a non-empty graph must not be mistaken for "nothing to
# do" and carried into the orchestrator compile.
echo
echo "round 3: a dependency cycle"
cat > "$W/a/.build.ae" <<'AE'
import bldr
import bldr (dep)
aeb(cap) { bldr.build() { dep("b/.build.ae") } }
AE
cat > "$W/b/.build.ae" <<'AE'
import bldr
import bldr (dep)
aeb(cap) { bldr.build() { dep("a/.build.ae") } }
AE
rm -rf "$W/target"

run_aeb "a/.build.ae"

if [ "$(cat "$TMP/rc")" != "0" ]; then
    pass "aeb exits non-zero on a cycle"
else
    fail "a dependency cycle built green (exit 0)"
fi

if grep -q "circular dependency" "$TMP/out"; then
    pass "the cycle is named"
else
    fail "no circular-dependency diagnostic"
    sed 's/^/        /' "$TMP/out" | tail -10
fi

# The load-bearing one: the build must not run on past the cycle into the
# orchestrator compile, where the real message is buried under parse errors
# from gen-orchestrator's own usage line.
if ! grep -q "E0100" "$TMP/out"; then
    pass "the build stops at the cycle, with no cascade of parse errors"
else
    fail "cycle cascaded into orchestrator parse errors"
    grep -c "E0100" "$TMP/out" | sed 's/^/        E0100 count: /'
fi

# --- result -----------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
    echo "[dag-diagnostics] OK"
    exit 0
fi
echo "[dag-diagnostics] $FAILURES assertion(s) failed"
exit 1
