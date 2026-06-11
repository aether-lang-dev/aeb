#!/usr/bin/env bash
# itests/cache-smoke.sh — end-to-end verification that the content-addressed
# cache actually skips work on a warm rebuild and re-runs when a source
# changes, for the SDKs wired in the "cache into all artifact SDKs" work.
#
# This is the Level-4 check that the unit suite (tests/run.sh) can't do: it
# drives real `aeb` builds of real projects with the real language
# toolchains, and asserts the per-target cache outcome reported in
# `aeb --telemetry-json`. It must run on a host where:
#   - a WORKING `ae` (>= 0.231, able to link a full multi-module ./aeb) is
#     available — i.e. Linux today (macOS ld64 can't link multi-module
#     builds; see TODO.md "macOS link step"),
#   - the per-project language toolchains are installed (scalac/java, go,
#     dotnet, node+tsc), and
#   - upstream sources have been fetched: `./fetch-upstream.sh`.
# Projects whose toolchain or sources are absent are SKIPPED, not failed,
# so partial CI environments still get useful coverage.
#
# The cache is content-addressed under $AEB_CACHE_DIR; each project gets a
# fresh cache dir so "cold" is genuinely cold.
#
# Assertions per project (toolchain-agnostic, so one shape fits every SDK):
#   1. COLD  (fresh cache)        -> 0 records report cache "hit"
#   2. WARM  (rebuild, no change) -> >0 records report "hit"   (cache works)
#   3. TOUCH (edit one source)    -> fewer "hit" records than WARM
#                                    (the changed target re-ran)
#
# Usage:
#   cd itests && AETHER=/path/to/ae ./cache-smoke.sh           # all projects
#   AETHER=/path/to/ae ./cache-smoke.sh scala-cli-multi-module-demo  # subset
#   AEB=/path/to/aeb AETHER=/path/to/ae ./cache-smoke.sh       # explicit aeb
#
# Exit code: 0 if every project that RAN passed; 1 if any ran and failed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The aeb entrypoint: $AEB, else the repo trampoline.
AEB="${AEB:-$REPO_ROOT/aeb}"
# $AETHER is the compiler aeb uses to build its own tools and the orchestrator.
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

# Project table: "dir|tool|source-glob". `tool` must be on PATH for the
# project to run; `source-glob` picks the file we touch to force a rebuild.
# Only SDKs with a green itest are listed (rust itests are env-broken
# upstream; clojure caches only its AOT main_ns branch so it's omitted to
# avoid a flaky "warm hits>0").
PROJECTS="
scala-cli-multi-module-demo|scalac|*.scala
go-multimodule-fyne|go|*.go
dotnet-architecture-eShopOnWeb|dotnet|*.cs
nx-examples|tsc|*.ts
"

FILTER="${1:-}"

# count_hits <telemetry.json> — number of records whose cache outcome is
# "hit". Prefers jq; falls back to a grep that tolerates spacing.
count_hits() {
    _f="$1"
    [ -f "$_f" ] || { echo 0; return; }
    if command -v jq >/dev/null 2>&1; then
        jq '[.records[]? | select(.cache == "hit")] | length' "$_f" 2>/dev/null || echo 0
    else
        grep -o '"cache"[[:space:]]*:[[:space:]]*"hit"' "$_f" 2>/dev/null | wc -l | tr -d ' '
    fi
}

run_aeb() {
    # run_aeb <proj_dir> <telemetry_out> ; never aborts the script on a
    # non-zero build (some upstream modules may fail to compile for reasons
    # unrelated to caching) — we assert on the telemetry it still emits.
    ( cd "$1" && "$AEB" --telemetry-json "$2" >/dev/null 2>&1 ) || true
}

total=0
passed=0
failed=0
skipped=0
fail_names=""

echo "cache-smoke: aeb=$AEB  ae=$(command -v "$AETHER")"
echo

# Iterate the table (newline-separated; works on bash 3.2 with IFS swap).
OLDIFS="$IFS"
IFS='
'
for row in $PROJECTS; do
    IFS='|' read -r dir tool glob <<EOF
$row
EOF
    [ -n "$dir" ] || continue
    if [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ]; then continue; fi

    proj="$SCRIPT_DIR/$dir"
    printf '  %-34s ' "$dir"

    # Skip conditions (report as SKIP, not failure).
    if [ ! -d "$proj" ]; then echo "SKIP (no project dir)"; skipped=$((skipped+1)); continue; fi
    if ! command -v "$tool" >/dev/null 2>&1; then echo "SKIP (no $tool on PATH)"; skipped=$((skipped+1)); continue; fi
    src="$(find "$proj" -type f -name "$glob" \
            ! -path '*/target/*' ! -path '*/.aeb/*' ! -path '*/node_modules/*' \
            ! -path '*/obj/*' ! -path '*/bin/*' 2>/dev/null | head -1)"
    if [ -z "$src" ]; then echo "SKIP (no $glob source — run ./fetch-upstream.sh?)"; skipped=$((skipped+1)); continue; fi

    total=$((total+1))

    cache_dir="$(mktemp -d)"
    tj="$(mktemp)"
    export AEB_CACHE_DIR="$cache_dir"

    ( cd "$proj" && "$AEB" --init >/dev/null 2>&1 ) || true

    # 1. COLD — fresh cache, expect zero hits.
    run_aeb "$proj" "$tj"
    cold_hits="$(count_hits "$tj")"

    # 2. WARM — no change, expect hits to appear.
    run_aeb "$proj" "$tj"
    warm_hits="$(count_hits "$tj")"

    # 3. TOUCH — perturb one source, expect fewer hits than WARM.
    #    Append a comment-safe newline then restore mtime ordering via touch.
    touch "$src"
    # Make the change real (content), so content-addressed keys bust even if
    # the SDK keyed on content rather than mtime. A trailing newline is
    # syntactically harmless in scala/go/cs/ts.
    printf '\n' >> "$src"
    run_aeb "$proj" "$tj"
    touched_hits="$(count_hits "$tj")"
    # Revert the perturbation so the tree is left clean.
    git -C "$proj" checkout -- "$src" 2>/dev/null || \
        { tmp="$(mktemp)"; sed '$ { /^$/d; }' "$src" > "$tmp" && mv "$tmp" "$src"; }

    rm -rf "$cache_dir"; rm -f "$tj"
    unset AEB_CACHE_DIR

    # Evaluate.
    ok=1
    reason=""
    if [ "$cold_hits" -ne 0 ]; then ok=0; reason="cold hits=$cold_hits (expected 0)"; fi
    if [ "$ok" = 1 ] && [ "$warm_hits" -le 0 ]; then ok=0; reason="warm hits=$warm_hits (expected >0)"; fi
    if [ "$ok" = 1 ] && [ "$touched_hits" -ge "$warm_hits" ]; then
        ok=0; reason="touched hits=$touched_hits not < warm hits=$warm_hits"
    fi

    if [ "$ok" = 1 ]; then
        echo "PASS (cold=$cold_hits warm=$warm_hits touched=$touched_hits)"
        passed=$((passed+1))
    else
        echo "FAIL ($reason)"
        failed=$((failed+1))
        fail_names="$fail_names $dir"
    fi
done
IFS="$OLDIFS"

echo
echo "cache-smoke: $passed passed, $failed failed, $skipped skipped (of $total run)"
if [ "$failed" -ne 0 ]; then
    echo "failed:$fail_names"
    exit 1
fi
if [ "$total" -eq 0 ]; then
    echo "note: nothing ran — install toolchains and ./fetch-upstream.sh, then retry."
fi
exit 0
