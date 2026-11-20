#!/usr/bin/env bash
# itests/stale-helper-rebuilt.sh — a helper tool older than its source, or
# than an aeb module it imports, is rebuilt; one that is current is not.
#
# aeb builds its helper tools (tools/<name>.ae) the first time each is needed
# and keeps the binary beside the source. "The binary exists" was the whole
# test for most of them, so in a checkout that is pulled into, a helper from
# before a change went on doing what it did before, with nothing to say so
# (2026-11-19: a new rule in tools/extract-deps.ae did not apply on three
# machines until the old binaries were deleted by hand).
#
# Runs on a COPY of aeb's tree, so the checkout's own binaries and file times
# are not touched. Each helper is watched by its modification time:
#
#   1. Built once, a second run rebuilds nothing.
#   2. A helper's own source touched: that helper is rebuilt
#      (extract-deps, built by aeb-main; gcheckout, built by the launcher).
#   3. A module it imports touched (tools/aebnode, which extract-deps and
#      gcheckout import and topo-sort does not): the importers are rebuilt,
#      topo-sort is not.
#   4. A module imported through another (lib/mvngraph, through
#      tools/aebmvn, by extract-deps): extract-deps is rebuilt.
#   5. aeb-main itself, built by the launcher, when its source is touched.
#
# Usage: AETHER=/path/to/ae ./itests/stale-helper-rebuilt.sh
# Exit: 0 if every assertion passed; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AETHER="${AETHER:-ae}"
export AETHER
if ! command -v "$AETHER" >/dev/null 2>&1; then echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; fi

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t aeb_stale)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# A copy of aeb with no built helpers in it.
HOME_COPY="$TMP/aeb"
mkdir -p "$HOME_COPY"
cp "$REPO_ROOT/aeb" "$HOME_COPY/aeb"
cp -R "$REPO_ROOT/lib" "$HOME_COPY/lib"
mkdir -p "$HOME_COPY/tools"
( cd "$REPO_ROOT/tools" && for e in *; do
    if [ -d "$e" ]; then cp -R "$e" "$HOME_COPY/tools/$e"
    else case "$e" in *.ae|*.sh|*.py) cp "$e" "$HOME_COPY/tools/$e" ;; esac
    fi
  done )
for f in AETHER_PIN AETHER_FETCH ZIG_REF VERSION; do
    [ -f "$REPO_ROOT/$f" ] && cp "$REPO_ROOT/$f" "$HOME_COPY/$f"
done
unset AEB_HOME
AEB="$HOME_COPY/aeb"
T="$HOME_COPY/tools"

# A two-node project, so the scan, the dep read and the sort all run.
PROJ="$TMP/proj"
mkdir -p "$PROJ/.aeb" "$PROJ/a" "$PROJ/b"
printf 'import bldr\nmain() { bldr.build() { } }\n' > "$PROJ/a/.build.ae"
printf 'import bldr\nimport bldr (dep)\nmain() { bldr.build() { dep("a/.build.ae") } }\n' > "$PROJ/b/.build.ae"
( cd "$PROJ" && git init -q . 2>/dev/null )

mtime() { if stat -f %m "$1" >/dev/null 2>&1; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }
build() { ( cd "$PROJ" && "$AEB" b/.build.ae ) > "$TMP/build.log" 2>&1; }
gco() { ( cd "$PROJ" && "$AEB" gcheckout add b/.build.ae ) > "$TMP/gco.log" 2>&1; }
# A file time in the future of every binary built so far, without sleeping
# past a one-second clock: set the source's time two seconds ahead of now.
touch_ahead() {
    local when
    when=$(( $(date +%s) + 2 ))
    if touch -d "@$when" "$1" 2>/dev/null; then :; else touch -t "$(date -r "$when" +%Y%m%d%H%M.%S)" "$1"; fi
}
# After touching a source two seconds ahead, wait so a rebuilt binary is
# newer than it and the next run sees it as current.
settle() { sleep 3; }

echo "[stale-helper-rebuilt]"
build
if [ ! -x "$T/aeb-main" ] || [ ! -x "$T/extract-deps" ] || [ ! -x "$T/topo-sort" ]; then
    echo "  the cold build did not produce the helpers:"; tail -5 "$TMP/build.log" | sed 's/^/    /'
    exit 1
fi
gco
[ -x "$T/gcheckout" ] || { echo "  gcheckout was not built:"; tail -5 "$TMP/gco.log" | sed 's/^/    /'; exit 1; }

echo
echo "1: nothing changed"
m_main=$(mtime "$T/aeb-main"); m_xd=$(mtime "$T/extract-deps"); m_ts=$(mtime "$T/topo-sort"); m_gc=$(mtime "$T/gcheckout")
sleep 1; build; gco
if [ "$(mtime "$T/aeb-main")" = "$m_main" ] && [ "$(mtime "$T/extract-deps")" = "$m_xd" ] \
   && [ "$(mtime "$T/topo-sort")" = "$m_ts" ] && [ "$(mtime "$T/gcheckout")" = "$m_gc" ]; then
    pass "a second run rebuilds no helper"
else
    fail "a helper was rebuilt with nothing changed"
fi

echo
echo "2: a helper's own source is newer"
touch_ahead "$T/extract-deps.ae"; touch_ahead "$T/gcheckout.ae"
build; gco
if [ "$(mtime "$T/extract-deps")" != "$m_xd" ]; then pass "extract-deps (built by aeb-main) is rebuilt"; else fail "extract-deps was not rebuilt after its source changed"; fi
if [ "$(mtime "$T/gcheckout")" != "$m_gc" ]; then pass "gcheckout (built by the launcher) is rebuilt"; else fail "gcheckout was not rebuilt after its source changed"; fi
if [ "$(mtime "$T/topo-sort")" = "$m_ts" ]; then pass "topo-sort, untouched, is not"; else fail "topo-sort was rebuilt though nothing of its changed"; fi
settle; build; gco

echo
echo "3: a module it imports is newer"
m_xd=$(mtime "$T/extract-deps"); m_ts=$(mtime "$T/topo-sort"); m_gc=$(mtime "$T/gcheckout")
touch_ahead "$T/aebnode/module.ae"
build; gco
if [ "$(mtime "$T/extract-deps")" != "$m_xd" ]; then pass "extract-deps imports aebnode: rebuilt"; else fail "extract-deps was not rebuilt after tools/aebnode changed"; fi
if [ "$(mtime "$T/gcheckout")" != "$m_gc" ]; then pass "gcheckout imports aebnode: rebuilt"; else fail "gcheckout was not rebuilt after tools/aebnode changed"; fi
if [ "$(mtime "$T/topo-sort")" = "$m_ts" ]; then pass "topo-sort does not import it: not rebuilt"; else fail "topo-sort was rebuilt for a module it does not import"; fi
settle; build; gco

echo
echo "4: a module imported through another is newer"
m_xd=$(mtime "$T/extract-deps")
touch_ahead "$HOME_COPY/lib/mvngraph/module.ae"
build
if [ "$(mtime "$T/extract-deps")" != "$m_xd" ]; then pass "extract-deps reaches lib/mvngraph through tools/aebmvn: rebuilt"; else fail "extract-deps was not rebuilt after lib/mvngraph changed"; fi
settle; build

echo
echo "5: aeb-main itself"
m_main=$(mtime "$T/aeb-main")
touch_ahead "$T/aeb-main.ae"
build
if [ "$(mtime "$T/aeb-main")" != "$m_main" ] && grep -q "^aeb: 2 build" "$TMP/build.log"; then
    pass "the launcher rebuilds aeb-main, and the build still runs"
else
    fail "aeb-main was not rebuilt after its source changed"; tail -4 "$TMP/build.log" | sed 's/^/        /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "stale-helper-rebuilt: all assertions passed"
    exit 0
fi
echo "stale-helper-rebuilt: $FAILURES assertion(s) failed"
exit 1
