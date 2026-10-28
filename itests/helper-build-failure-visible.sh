#!/usr/bin/env bash
# itests/helper-build-failure-visible.sh — a helper tool that fails to build
# stops aeb with the compiler's errors, naming the helper.
#
# aeb-main builds its helpers (extract-deps, scan-ae-files, topo-sort, ...)
# from tools/<name>.ae on first use. It sent that build's output to /dev/null
# and never looked for the binary, so a failed build surfaced later as
#   sh: .../tools/topo-sort: No such file or directory
#   aeb: topo-sort produced no build order for a non-empty graph.
# which points at the graph, not the build. The usual cause is an `ae` whose
# compiler or stdlib comes from another Aether install (an inherited
# AETHER_HOME); here a broken topo-sort.ae stands in for that.
#
# Fixture: a copy of this aeb tree (aeb, lib, tools) with its helper binaries
# removed, and a one-node project.
#
# Assertions:
#   1. GREEN — the helpers build on first use and the build passes.
#   2. RED   — with topo-sort.ae broken and its binary gone: exit non-zero,
#              "could not build its helper tool 'topo-sort'" and the
#              compiler's error are printed, "no build order" is not.
#
# Usage: AETHER=/path/to/ae ./itests/helper-build-failure-visible.sh
# Exit: 0 if all pass; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOME_COPY="$WORK/aeb-home"
mkdir -p "$HOME_COPY"
cp "$REPO_ROOT/aeb" "$REPO_ROOT/AETHER_PIN" "$HOME_COPY/"
[ -f "$REPO_ROOT/AETHER_FETCH" ] && cp "$REPO_ROOT/AETHER_FETCH" "$HOME_COPY/"
cp -R "$REPO_ROOT/lib" "$REPO_ROOT/tools" "$HOME_COPY/"
# aeb-main too, so the copy builds it from this tree's source (the aeb
# script's cold bootstrap) rather than running a binary built earlier.
for h in aeb-main extract-deps scan-ae-files topo-sort aeb-link aeb-graph aeb-report aeb-query affected-targets; do
    rm -f "$HOME_COPY/tools/$h" "$HOME_COPY/tools/$h.exe"
done

mkdir -p "$WORK/proj/app"
cat > "$WORK/proj/app/.build.ae" <<'EOF'
aeb(cap) {
    return 0
}
EOF

run() {
    (cd "$WORK/proj" && "$HOME_COPY/aeb" app/.build.ae >"$WORK/out.txt" 2>&1)
}

echo "1. GREEN: helpers build on first use"
if run; then pass "build passed"; else fail "build failed: $(tail -5 "$WORK/out.txt")"; fi
if [ -x "$HOME_COPY/tools/topo-sort" ] || [ -x "$HOME_COPY/tools/topo-sort.exe" ]; then
    pass "topo-sort was built"
else
    fail "topo-sort was not built"
fi

echo "2. RED: topo-sort.ae does not compile"
rm -f "$HOME_COPY/tools/topo-sort" "$HOME_COPY/tools/topo-sort.exe"
printf '\nthis is not aether (\n' >> "$HOME_COPY/tools/topo-sort.ae"
if run; then fail "build passed with a broken helper"; else pass "exit non-zero"; fi
if grep -q "could not build its helper tool 'topo-sort'" "$WORK/out.txt"; then
    pass "names the helper"
else
    fail "does not name the helper: $(tail -5 "$WORK/out.txt")"
fi
if grep -q "error\[E" "$WORK/out.txt"; then pass "shows the compiler's error"; else fail "no compiler error shown"; fi
if grep -q "no build order" "$WORK/out.txt"; then
    fail "still reports 'no build order'"
else
    pass "no misleading 'no build order'"
fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILURES FAILURE(S)"; exit 1
