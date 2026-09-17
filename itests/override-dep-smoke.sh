#!/usr/bin/env bash
# itests/override-dep-smoke.sh — end-to-end test of --overrideDep node substitution.
#
# --overrideDep <real>=<substitute> relabels every dep("<real>") edge to
# <substitute>, a normal aeb node the dev authors (e.g. a .getFromGhReleases.ae
# that fetches a prebuilt and publishes the same edges). The prebuilt lands in
# target/ through the ordinary builder — no read-redirect, no build-set surgery.
#
# This drives the REAL --overrideDep CLI arg through the trampoline (not the
# internal AEB_OVERRIDE_DEP env var), so it covers the whole path: arg parse ->
# env -> the aeb-main relabel -> the actual build. A Level-4 check the unit
# suite can't do — it's about DAG rewrite + scheduling, not a command string.
#
# Assertions:
#   1. SUBSTITUTE BUILDS   — the substitute node runs in place of the real one
#   2. REAL DOES NOT BUILD — the replaced node is dropped from the build set
#   3. NO DANGLING EDGE    — the consumer still builds green (green exit)
#   4. REPEATABLE          — two --overrideDep flags both take effect
#   5. BAD SUBSTITUTE      — a non-existent substitute node is rejected (exit 1)
#
# No language toolchain needed — members are trivial bash.test nodes.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/override-dep-smoke.sh
# Exit code: 0 if every assertion passed; 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
export AETHER

if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi
if ! command -v "$AETHER" >/dev/null 2>&1; then echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
MARK="$WORK/marks"; mkdir -p "$MARK"
trap 'rm -rf "$WORK"' EXIT

# A node whose test script drops a uniquely-named marker so we can tell it RAN.
# $1 = node dir, $2 = build-file basename, $3 = marker name.
make_node() {
    local dir="$WORK/$1" base="$2" mark="$3"
    mkdir -p "$dir"
    cat > "$dir/$mark.sh" <<EOF
#!/usr/bin/env bash
echo RAN > "$MARK/$mark"
EOF
    chmod +x "$dir/$mark.sh"
    cat > "$dir/$base" <<EOF
import bldr
import bash
import bash (script)
main() { bldr.build() { bash.test() { script("$mark.sh") } } }
EOF
}

# producer real node + its substitute; a second dep (core) for the repeat test.
make_node producer .build.ae               real_ran
make_node producer .getFromGhReleases.ae   sub_ran
make_node core     .build.ae               core_real_ran
make_node core     .getFromGhReleases.ae   core_sub_ran

# consumer deps on both producer and core.
mkdir -p "$WORK/consumer"
cat > "$WORK/consumer/check.sh" <<'EOF'
#!/usr/bin/env bash
echo CONSUMER-RAN
EOF
chmod +x "$WORK/consumer/check.sh"
cat > "$WORK/consumer/.build.ae" <<'EOF'
import bldr
import bash
import bash (script)
main() {
    bldr.build() {
        dep("producer/.build.ae")
        dep("core/.build.ae")
        bash.test() { script("check.sh") }
    }
}
EOF

# --- Test A: single override (producer -> its substitute) ---
rm -f "$MARK"/*
( cd "$WORK" && "$AEB" --overrideDep "producer/.build.ae=producer/.getFromGhReleases.ae" consumer/.build.ae ) >"$WORK/a.log" 2>&1
rc=$?
[ -f "$MARK/sub_ran" ]  && pass "substitute node built in place of real"       || fail "substitute node did not build (see $WORK/a.log)"
[ ! -f "$MARK/real_ran" ] && pass "real node dropped from the build"           || fail "real node still built (not replaced)"
if [ $rc -eq 0 ] && ! grep -qE "No rule to make target|aeb-link: FATAL" "$WORK/a.log"; then
    pass "consumer built green, no dangling edge"
else
    fail "consumer build failed or left a dangling edge (rc=$rc)"
fi

# --- Test B: repeatable (override producer AND core) ---
rm -f "$MARK"/* ; rm -rf "$WORK/target" "$WORK"/*/target
( cd "$WORK" && "$AEB" \
    --overrideDep "producer/.build.ae=producer/.getFromGhReleases.ae" \
    --overrideDep "core/.build.ae=core/.getFromGhReleases.ae" \
    consumer/.build.ae ) >"$WORK/b.log" 2>&1
if [ -f "$MARK/sub_ran" ] && [ -f "$MARK/core_sub_ran" ] && [ ! -f "$MARK/real_ran" ] && [ ! -f "$MARK/core_real_ran" ]; then
    pass "two --overrideDep flags both took effect"
else
    fail "repeat override incomplete (see $WORK/b.log)"
fi

# --- Test C: baseline (no override) still builds the real nodes ---
rm -f "$MARK"/* ; rm -rf "$WORK/target" "$WORK"/*/target
( cd "$WORK" && "$AEB" consumer/.build.ae ) >"$WORK/c.log" 2>&1
if [ -f "$MARK/real_ran" ] && [ ! -f "$MARK/sub_ran" ]; then
    pass "baseline (no override) builds the real node"
else
    fail "baseline behaviour changed (see $WORK/c.log)"
fi

# --- Test D: a non-existent substitute is rejected ---
( cd "$WORK" && "$AEB" --overrideDep "producer/.build.ae=producer/.nope.ae" consumer/.build.ae ) >"$WORK/d.log" 2>&1
drc=$?
if [ $drc -ne 0 ] && grep -qi "substitute node not found" "$WORK/d.log"; then
    pass "non-existent substitute rejected"
else
    fail "bad substitute not rejected (rc=$drc, see $WORK/d.log)"
fi

# --- Test E: dep_artifact READ follows the substitution ---
# The bug selaenium hit (aeb 0.313): the substitute is scheduled, but a consumer
# that reads dep_artifact("<real>", key) resolved the REAL node's (empty) target
# dir. The read must follow to the SUBSTITUTE's target dir. Real node publishes
# shared_lib=/real, substitute publishes shared_lib=/fetched; the consumer reads
# by the real label under override and must get /fetched.
ED="$WORK/edgetest"; mkdir -p "$ED/eng" "$ED/cons"
cat > "$ED/eng/.build.ae" <<'EOF'
import bldr
main() { bldr.build() { bldr.publish_artifact("shared_lib", "/real/lib.so") } }
EOF
cat > "$ED/eng/.getFromGitHubReleases.ae" <<'EOF'
import bldr
main() { bldr.build() { bldr.publish_artifact("shared_lib", "/fetched/lib.so") } }
EOF
cat > "$ED/cons/.build.ae" <<'EOF'
import bldr
import std.io
main() {
    bldr.build() {
        dep("eng/.build.ae")
        lib = bldr.dep_artifact("eng/.build.ae", "shared_lib")
        _w = io.write_file("$ED_MARK", lib)
    }
}
EOF
# inline the marker path (the heredoc is quoted, so substitute it after)
sed -i "s#\$ED_MARK#$MARK/read_follow#" "$ED/cons/.build.ae"
rm -f "$MARK/read_follow"
( cd "$ED" && "$AEB" --overrideDep "eng/.build.ae=eng/.getFromGitHubReleases.ae" cons/.build.ae ) >"$WORK/e.log" 2>&1
got_lib="$(cat "$MARK/read_follow" 2>/dev/null || true)"
if [ "$got_lib" = "/fetched/lib.so" ]; then
    pass "dep_artifact read follows the substitution (got the substitute's value)"
else
    fail "dep_artifact read did NOT follow the substitution (got '$got_lib', want /fetched/lib.so; see $WORK/e.log)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "override-dep-smoke: all assertions passed"
    exit 0
fi
echo "override-dep-smoke: $FAILURES assertion(s) failed"
exit 1
