#!/usr/bin/env bash
# itests/tools-cold-compile-smoke.sh — cold-compile EVERY tools/*.ae on the
# pinned toolchain from a fresh AETHER_HOME (aeb gate hardening).
#
# WHY THIS EXISTS
# ---------------
# The warm unit suite (tests/run.sh) and `make build` compile most tools, but
# NOT all of them: three are opt-in and deliberately skipped by `make install`
# (aeb-agent, aeb-lease, aeb-keygen — the remote-agent kit), and several tools
# are lazy-built (aeb-report, aeb-graph, aeb-query — code-gen only when first
# invoked). A cached binary from an older toolchain can then MASK a source that
# no longer compiles on the newly-pinned Aether, so the failure only surfaces to
# whoever next runs that opt-in/lazy tool — or, worse, is discovered only by
# cutting a release (the toolchain the release gate pins is newer than the one
# that last built the cached binary).
#
# This bit us twice pinning Aether 0.706:
#   * tools/aeb-report.ae — 0.702 tightened branch-hoisted-local typing; an
#     int local re-read from a ptr-returning map.get hit E0200 (re-bind as ptr).
#   * tools/aeb-keygen.ae — a latent wrong-module call (cryptography.base64_encode
#     instead of encoding.base64_encode, destructuring a non-tuple return) that
#     had NEVER been cold-compiled because keygen is opt-in.
# Neither was in a `make build` target, so the gate stayed green while the
# release itself failed to build the tool.
#
# WHAT IT DOES
# ------------
# Compiles every tools/*.ae from scratch under a throwaway AETHER_HOME (so `ae`
# and `aetherc` both resolve to the pinned toolchain and NOTHING is served from
# a warm cache), with the same --lib flags the Makefile uses. Any tool that
# fails to code-gen/type-check/link fails the gate here — before a tag is cut.
#
# Usage: AETHER=/path/to/ae ./itests/tools-cold-compile-smoke.sh
# Exit: 0 if every tool cold-compiles; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AETHER="${AETHER:-ae}"
if ! command -v "$AETHER" >/dev/null 2>&1; then
  echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1
fi

cd "$REPO_ROOT" || exit 1

# Fresh, throwaway toolchain home: forces cold code-gen + link, and makes `ae`
# AND `aetherc` resolve to the same pinned version (no stale cache masking).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AETHER_HOME="$WORK/h"; mkdir -p "$AETHER_HOME"

# Same per-tool --lib wiring as the Makefile: `--lib tools` makes the shared
# aeblabel/gen-orchestrator modules importable; `--lib lib` adds the SDK modules
# (the lazy/opt-in tools and the SDK-touching ones need it). Passing both to
# every tool is a strict superset of what any single tool needs — an unused
# --lib path is harmless, a missing one is a false failure.
LIBS="--lib tools --lib lib"

FAILURES=0
TOTAL=0
FAILED_TOOLS=""
echo "cold-compiling every tools/*.ae on $("$AETHER" --version 2>/dev/null | head -1) ..."
for src in tools/*.ae; do
  [ -f "$src" ] || continue
  TOTAL=$((TOTAL + 1))
  base="$(basename "${src%.ae}")"
  out="$WORK/$base"
  if err="$("$AETHER" build "$src" -o "$out" $LIBS 2>&1)"; then
    echo "  ok    $base"
  else
    FAILURES=$((FAILURES + 1))
    FAILED_TOOLS="$FAILED_TOOLS $base"
    echo "  FAIL  $base"
    echo "$err" | grep -E 'error\[E[0-9]+\]|Undefined|cannot re-bind|aborting: [0-9]+ error' | head -4 | sed 's/^/          /'
  fi
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "tools-cold-compile-smoke: all $TOTAL tools cold-compile on the pinned toolchain"
  exit 0
else
  echo "tools-cold-compile-smoke: $FAILURES/$TOTAL tools FAILED to cold-compile:$FAILED_TOOLS"
  echo "  (a cached binary may mask this in a warm build — the release gate would still fail)"
  exit 1
fi
