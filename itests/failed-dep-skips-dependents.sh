#!/usr/bin/env bash
# itests/failed-dep-skips-dependents.sh — a node whose dep failed is SKIPPED,
# not run, under all three schedulers, and the sequential loop runs deps first.
#
# The make path always did this: each recipe exits with its node's rc, so
# `make -k` never remakes a target whose prerequisite failed. The sequential
# loop (AEB_JOBS=1) and the native scheduler (AEB_SCHED=native) ran the
# dependent anyway, on a missing or stale artifact. And the sequential loop
# walked the edges file in BFS order — requested target FIRST — so under
# AEB_JOBS=1 a node ran before its deps. The exit code was 1 throughout (the
# failed dep still counted); what was wrong was what else ran.
#
# Fixture: app/.build.ae deps lib/.build.ae. lib writes $MARK_DIR/lib.done and
# fails when FAIL_LIB=1; app fails unless lib.done already exists (so it
# checks order) and writes $MARK_DIR/app.ran.
#
# Assertions, per scheduler (make, AEB_JOBS=1, AEB_SCHED=native):
#   1. GREEN    — lib runs before app; exit 0.
#   2. RED      — lib fails: exit non-zero, app never runs, app's log says why.
#   3. NO STALE — after a green run, a red run leaves no app .rc marker
#                 (a stale rc=0 would read as a pass).
#
# Usage: AEB=/path/to/aeb ./itests/failed-dep-skips-dependents.sh
# Exit: 0 if all pass; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib" "$WORK/app" "$WORK/marks"

cat > "$WORK/lib/.build.ae" <<'EOF'
import bldr
import std.os
import std.io
import std.string

aeb(cap) {
    d = os.getenv("MARK_DIR")
    _w = io.write_file("${d}/lib.done", "1")
    if string.equals(os.getenv("FAIL_LIB"), "1") == 1 { return 1 }
    return 0
}
EOF

cat > "$WORK/app/.build.ae" <<'EOF'
import bldr
import std.os
import std.io
import std.file

aeb(cap) {
    bldr.build() {
        dep("lib/.build.ae")
    }
    d = os.getenv("MARK_DIR")
    _w = io.write_file("${d}/app.ran", "1")
    if file.exists("${d}/lib.done") == 0 {
        println("app ran before lib")
        return 1
    }
    return 0
}
EOF

run() { # $1 = scheduler env ("" for make), $2 = FAIL_LIB
    rm -f "$WORK"/marks/*
    (cd "$WORK" && env $1 MARK_DIR="$WORK/marks" FAIL_LIB="$2" "$AEB" app/.build.ae >/dev/null 2>&1)
}

for sched in "" "AEB_JOBS=1" "AEB_SCHED=native"; do
    name="${sched:-make}"
    echo "failed-dep-skips-dependents: $name"

    run "$sched" 0; rc=$?
    if [ "$rc" -eq 0 ]; then pass "$name: green build exits 0 (lib ran before app)"
    else fail "$name: green build exited $rc"; cat "$WORK"/target/.aeb/logs/app.log 2>/dev/null; fi

    run "$sched" 1; rc=$?
    if [ "$rc" -ne 0 ]; then pass "$name: failing dep exits non-zero ($rc)"
    else fail "$name: failing dep exited 0"; fi
    if [ ! -e "$WORK/marks/app.ran" ]; then pass "$name: dependent did not run"
    else fail "$name: dependent ran after its dep failed"; fi
    if ls "$WORK"/target/.aeb/rc/ 2>/dev/null | grep -q '^app'; then
        fail "$name: dependent has an .rc marker (stale or real) after being skipped"
    else pass "$name: no stale .rc marker for the skipped dependent"; fi
    if [ -n "$sched" ]; then
        if grep -q "skipped: dependency lib/.build.ae failed" "$WORK"/target/.aeb/logs/app.log 2>/dev/null; then
            pass "$name: dependent's log says why it was skipped"
        else fail "$name: dependent's log has no skip reason"; fi
    fi
done

if [ "$FAILURES" -eq 0 ]; then echo "failed-dep-skips-dependents: all passed"; exit 0; fi
echo "failed-dep-skips-dependents: $FAILURES failure(s)"; exit 1
