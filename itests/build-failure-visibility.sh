#!/usr/bin/env bash
# itests/build-failure-visibility.sh — a failed build must LOOK failed.
#
# Regression harness for issue #13: "gcc/link failures print a
# success-shaped summary". A node whose gcc/link step died rendered the
# byte-identical telemetry row a successful build renders — same `[miss]`,
# same timing, no verdict — because only TEST rows had a verdict channel
# (their pass/fail counts). Build rows had none, so the human-facing
# output on failure was indistinguishable from success.
#
# The exit code was always correct, and that is precisely why this needs
# an integration test rather than trust in `$?`. Two real incidents (from
# the issue, aether-ui on macOS) both happened WITH the honest exit code:
#
#   1. Stale artifacts from a previous good build were on disk. The build
#      "succeeded" per its output, the test matrix then ran STALE
#      BINARIES, and the wrong-but-plausible results read as a build-cache
#      mystery.
#   2. After `rm -rf target`, the same success-shaped build produced no
#      binaries at all and 50+ suites reported NO BINARY — a cascade
#      instead of one pointed compile error.
#
# Interactive use pipes aeb through `tail`/`grep` (which REPLACES the exit
# code with the pipe's) or just reads the screen. So the assertions below
# are deliberately about BYTES ON STDOUT, not about `$?`.
#
# Why not a unit test: tests/test_telemetry_render.ae already covers the
# renderer against synthetic records, and it would NOT have caught the
# original bug — the record carried the right status all along; the
# renderer dropped it on the floor. What has to be proven end-to-end is
# that a real gcc failure reaches a real summary line as a failure. That
# needs a real aeb driving a real broken build.
#
# Assertions:
#   1. ROW VERDICT   — the failing node's telemetry row says FAILED
#   2. TAIL SURVIVES — the LAST lines of the summary block still state
#                      the verdict (the roll-up), which is the exact
#                      interactive path from the issue
#   3. NO BINARY     — the build genuinely produced nothing (so we are
#                      testing a real failure, not a mislabelled success)
#   4. LOG POINTER   — the gcc stderr log is named in the output
#   5. GREEN QUIET   — a passing build says nothing extra: no FAILED
#                      anywhere, and no roll-up block. Silence stays the
#                      success signal.
#   6. BOTH PATHS    — parallel (make -jN) and sequential (AEB_JOBS=1)
#                      drivers agree, since they build the telemetry
#                      records through completely separate code (the
#                      driver reads on-disk .rc markers, the in-process
#                      orchestrator reads build.status_of).
#
# Assertion 6 is load-bearing beyond tidiness: the two paths write
# DIFFERENT status vocabularies ("fail" vs "failed"), so a renderer that
# matched only one would under-report on the other.
#
# Usage:
#   cd itests && AETHER=/path/to/ae ./build-failure-visibility.sh
#   AEB=/path/to/aeb AETHER=/path/to/ae ./build-failure-visibility.sh
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

echo "[build-failure-visibility]"

# ---------------------------------------------------------------------------
# Fixture: an aether.program with an extra_source .c file.
#
# extra_source is what routes the build down lib/aether's MANUAL
# aetherc+gcc path (_compile_and_link) instead of the default `ae build`
# shell-out — and that manual gcc step is exactly where the issue's
# failures happened. A broken .c fails at gcc while the Aether source
# compiles fine, which is the reported shape: aetherc green, link red.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/app"

cat > "$WORK/app/app.ae" <<'EOF'
main() {
    println("ok")
    return 0
}
EOF

cat > "$WORK/app/.build.ae" <<'EOF'
import build (start)
import aether (program, source, output, extra_source)

aeb(cap) {
    b = build.start()
    aether.program(b) {
        source("app.ae")
        output("app")
        extra_source("helper.c")
    }
}
EOF

# The two states of helper.c: one that compiles, one that does not.
write_helper_broken() {
    cat > "$WORK/app/helper.c" <<'EOF'
THIS IS A SYNTAX ERROR
EOF
}
write_helper_ok() {
    # A translation unit with no symbols aeb's link needs — it only has
    # to COMPILE. `helper_marker` keeps it from being an empty TU (which
    # is technically invalid C).
    cat > "$WORK/app/helper.c" <<'EOF'
int helper_marker(void) { return 0; }
EOF
}

# run_build <mode> — build the fixture, echo combined output.
# mode "par" = default make -jN driver; "seq" = AEB_JOBS=1.
run_build() {
    rm -rf "$WORK/target"
    if [ "$1" = "seq" ]; then
        ( cd "$WORK" && AEB_JOBS=1 "$AEB" app/.build.ae 2>&1 )
    else
        ( cd "$WORK" && "$AEB" app/.build.ae 2>&1 )
    fi
}

# --- The failing build, on both driver paths -------------------------------
for MODE in par seq; do
    write_helper_broken
    OUT="$(run_build "$MODE")"

    # 1. ROW VERDICT — the telemetry row itself must carry the verdict.
    #    Matching the row (not just the word "FAILED" anywhere in the
    #    output) is the point: the gcc stderr replay already contained
    #    "error", and the pre-fix output still had a green-shaped row.
    if printf '%s\n' "$OUT" | grep -qE '^  build: +app +[0-9]+\.[0-9]+s \[[a-z/]+\] FAILED$'; then
        pass "$MODE: telemetry row for the failed node says FAILED"
    else
        fail "$MODE: telemetry row does not say FAILED"
        printf '%s\n' "$OUT" | sed -n '/\[telemetry\]/,$p' | sed 's/^/        /'
    fi

    # 2. TAIL SURVIVES — the issue's actual usage.
    #
    #    Scoped to the [telemetry] block on purpose. A plain `tail -5` of
    #    the whole output would pass VACUOUSLY on this one-node fixture:
    #    the driver's pre-existing `build: app — FAILED (see …)` line
    #    happens to land within 5 lines here. On a 50-node build it would
    #    be hundreds of lines up, which is exactly why the issue was filed
    #    despite that line already existing. Verified by mutation — with
    #    the fix reverted, the unscoped form still passed while this one
    #    fails.
    #
    #    So the real requirement is: the telemetry block's own last lines
    #    state the verdict, no matter how many nodes precede it.
    TELEMETRY="$(printf '%s\n' "$OUT" | sed -n '/^\[telemetry\]/,$p')"
    TAIL="$(printf '%s\n' "$TELEMETRY" | tail -5)"
    if printf '%s\n' "$TAIL" | grep -q 'FAILED'; then
        pass "$MODE: failure visible in the last lines of the summary block"
    else
        fail "$MODE: summary block ends success-shaped (the issue's exact trap)"
        printf '%s\n' "$TAIL" | sed 's/^/        /'
    fi

    # 2b. The roll-up should NAME the target, not just assert a count —
    #     on a 50-node build "something failed" is not actionable.
    if printf '%s\n' "$OUT" | grep -qE '^FAILED: 1 target$' \
       && printf '%s\n' "$OUT" | grep -qE '^  build: app$'; then
        pass "$MODE: roll-up names the failed target"
    else
        fail "$MODE: roll-up missing or does not name the target"
    fi

    # 3. NO BINARY — proves this is a genuine failure. Without this the
    #    test could pass against a build that succeeded and was merely
    #    mislabelled, which would be a different bug entirely.
    if [ ! -e "$WORK/target/build/app/bin/app" ]; then
        pass "$MODE: no binary produced (a real failure, not a mislabel)"
    else
        fail "$MODE: a binary exists — the build did not actually fail"
    fi

    # 4. LOG POINTER — the issue asked for the gcc stderr log to be
    #    named, so someone who redirected stderr or scrolled past a
    #    multi-node build has somewhere to go back to.
    if printf '%s\n' "$OUT" | grep -q '_gcc_stderr\.log'; then
        pass "$MODE: output names the gcc stderr log"
    else
        fail "$MODE: output does not name _gcc_stderr.log"
    fi
done

# --- The passing build: silence stays the success signal -------------------
# Guards the other direction. A fix that reddens failures is worthless if
# it also reddens (or noisily annotates) green builds — every downstream
# green-output assertion, and every human skim, depends on a clean run
# looking clean.
write_helper_ok
OUT_OK="$(run_build par)"

if printf '%s\n' "$OUT_OK" | grep -q 'FAILED'; then
    fail "green build: output contains FAILED"
    printf '%s\n' "$OUT_OK" | grep -n 'FAILED' | sed 's/^/        /'
else
    pass "green build: no FAILED anywhere in the output"
fi

if printf '%s\n' "$OUT_OK" | grep -qE '^FAILED: '; then
    fail "green build: emitted a roll-up block"
else
    pass "green build: no roll-up block (silence = success)"
fi

# And it really did build — otherwise "no FAILED" would be vacuous.
if [ -x "$WORK/target/build/app/bin/app" ]; then
    pass "green build: binary produced"
else
    fail "green build: no binary — the OK fixture does not actually build"
    printf '%s\n' "$OUT_OK" | tail -20 | sed 's/^/        /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "build-failure-visibility: PASS"
    exit 0
fi
echo "build-failure-visibility: FAIL ($FAILURES assertion(s))"
exit 1
