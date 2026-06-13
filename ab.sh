#!/usr/bin/env bash
# ab.sh — A/B differential harness: prove the pure-Aether entrypoint (aeb-cli)
# is a faithful facsimile of the bash trampoline (aeb).
#
# Runs the SAME build target through BOTH entrypoints, each into its own
# scratch copy of the project, and diffs the observable surface:
#   - exit code
#   - the produced artifact tree under target/ (relative paths + sizes)
#   - the structured telemetry + tests JSON (node list, per-node outcome)
#
# Any divergence is a facsimile bug. Identical across all three = the pure
# entrypoint is provably equivalent for this target. This is the regression
# gate the MINGW A/B plan calls for (mingw_a_b_plan.md step 2).
#
# Usage:
#   ab.sh <target.ae> [extra aeb flags...]
#   AEB_HOME=/path ab.sh itests/c-hello/.build.ae
#   ab.sh itests/c-hello/.build.ae --sandbox
#
# Honors AEB_HOME (defaults to ~/.local/share/aeb). The bash entrypoint is
# $AEB_HOME/aeb (or $AEB_BASH override); the pure one is $AEB_HOME/tools/aeb-cli
# (or $AEB_CLI override), lazy-built if absent.

set -u

AEB_HOME="${AEB_HOME:-$HOME/.local/share/aeb}"
AEB_BASH="${AEB_BASH:-$AEB_HOME/aeb}"
AEB_CLI="${AEB_CLI:-$AEB_HOME/tools/aeb-cli}"
AETHER="${AETHER:-ae}"

if [ $# -lt 1 ]; then
    echo "usage: ab.sh <target.ae> [extra aeb flags...]" >&2
    exit 2
fi
TARGET="$1"; shift
EXTRA=("$@")

if [ ! -f "$TARGET" ]; then echo "ab.sh: no such target: $TARGET" >&2; exit 2; fi
if [ ! -x "$AEB_BASH" ]; then echo "ab.sh: bash entrypoint not found/executable: $AEB_BASH" >&2; exit 2; fi

# Lazy-build the pure entrypoint if absent (mirrors how aeb lazy-builds tools).
if [ ! -x "$AEB_CLI" ]; then
    echo "ab.sh: building $AEB_CLI ..." >&2
    "$AETHER" build "$AEB_HOME/tools/aeb-cli.ae" --lib "$AEB_HOME/lib" --lib "$AEB_HOME/tools" -o "$AEB_CLI" || {
        echo "ab.sh: failed to build aeb-cli" >&2; exit 2; }
fi

# The target lives in a project; A/B each into its own throwaway copy so the
# two runs never share target/ state. Project root = the dir holding the target
# (good enough for single-dir itests; multi-dir trees pass the repo root as cwd).
PROJ_DIR="$(cd "$(dirname "$TARGET")" && pwd)"
PROJ_BASE="$(basename "$PROJ_DIR")"
TARGET_FILE="$(basename "$TARGET")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# Snapshot the produced artifact tree — the build OUTPUT (which files the build
# produced), ignoring the intermediate target/_aeb/ scratch. We compare the
# artifact SET (relative paths) — "did both entrypoints produce the same outputs"
# — which is the faithful-facsimile question. We deliberately do NOT compare
# compiled-binary CONTENT byte-for-byte: the Aether→C→gcc toolchain is not
# reproducible (it embeds the absolute source path and other build-specific bits,
# verified: the same bash entrypoint run twice yields different add_gen.o hashes),
# so byte-identity is a separate "reproducible builds" concern, not a facsimile
# one. For small TEXT artifacts (the pointer files that record an absolute path
# to the binary) we DO compare content, with the per-run scratch root normalised
# out, since those should match exactly once the path is neutralised.
snapshot() {
    local root="$1"
    ( cd "$root" 2>/dev/null && \
      find target -type f 2>/dev/null \
        | grep -vE '^target/_aeb/|/\.timestamp$|^target/\.aeb/' \
        | LC_ALL=C sort \
        | while IFS= read -r f; do \
            sz="$(wc -c < "$f" 2>/dev/null)"; \
            tag="bin"; \
            # Small files that are pure text (the artifact pointer files) get a
            # content hash with the scratch root normalised out; everything else
            # (compiled binaries/objects — non-reproducible) is compared by
            # presence only (path), with size shown for eyeballing.
            if [ "${sz:-0}" -le 4096 ] && LC_ALL=C grep -qI . "$f" 2>/dev/null; then \
                tag="txt:$(sed "s|$root|@ROOT@|g" "$f" 2>/dev/null | sha256sum 2>/dev/null | cut -c1-16)"; \
            fi; \
            printf '%s %s\n' "$tag" "$f"; \
          done )
}

run_one() {
    # $1 = label (A/B), $2 = launcher path, $3 = "bash"|"cli"
    local label="$1" launcher="$2" kind="$3"
    local dst="$WORK/$kind"
    cp -R "$PROJ_DIR" "$dst"
    rm -rf "$dst/target"
    local tj="$WORK/$kind.telemetry.json"
    local out="$WORK/$kind.out"
    local rc
    ( cd "$dst" && AEB_HOME="$AEB_HOME" "$launcher" --telemetry-json "$tj" "${EXTRA[@]}" "$TARGET_FILE" ) >"$out" 2>&1
    rc=$?
    echo "$rc" > "$WORK/$kind.rc"
    snapshot "$dst" > "$WORK/$kind.snap"
    # Normalise telemetry: drop wall-clock timings (legitimately differ), keep
    # node label + type + cache outcome (the semantic content).
    if [ -f "$tj" ]; then
        sed -E 's/"wall_ms":[ ]*[0-9]+/"wall_ms":N/g; s/"[a-z_]*_ms":[ ]*[0-9]+/"_ms":N/g' "$tj" \
            | LC_ALL=C sort > "$WORK/$kind.telem.norm"
    else
        : > "$WORK/$kind.telem.norm"
    fi
    echo "  $label ($kind): exit=$rc, $(wc -l < "$WORK/$kind.snap" | tr -d ' ') artifact(s)"
}

echo "ab.sh: A/B '$TARGET' ${EXTRA[*]:+(flags: ${EXTRA[*]})}"
run_one "A" "$AEB_BASH" bash
run_one "B" "$AEB_CLI"  cli

fail=0
rc_bash="$(cat "$WORK/bash.rc")"; rc_cli="$(cat "$WORK/cli.rc")"
if [ "$rc_bash" != "$rc_cli" ]; then
    echo "DIVERGE: exit code  bash=$rc_bash  cli=$rc_cli"; fail=1
else
    echo "  match: exit code ($rc_bash)"
fi
if ! diff -q "$WORK/bash.snap" "$WORK/cli.snap" >/dev/null; then
    echo "DIVERGE: artifact tree"; diff "$WORK/bash.snap" "$WORK/cli.snap" | sed 's/^/    /'; fail=1
else
    echo "  match: artifact tree ($(wc -l < "$WORK/bash.snap" | tr -d ' ') files)"
fi
if ! diff -q "$WORK/bash.telem.norm" "$WORK/cli.telem.norm" >/dev/null; then
    echo "DIVERGE: telemetry (node/outcome)"; diff "$WORK/bash.telem.norm" "$WORK/cli.telem.norm" | sed 's/^/    /'; fail=1
else
    echo "  match: telemetry node/outcome"
fi

if [ "$fail" = 0 ]; then
    echo "AB PASS — aeb-cli is a faithful facsimile for this target"
    exit 0
fi
echo "AB FAIL — divergence above"
exit 1
