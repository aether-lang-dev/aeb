#!/usr/bin/env bash
# test_host_lua.build.sh — non-uniform build for the in-process Lua
# host test (test_host_lua.ae). The test imports `lua`, which lives in
# an aether-guest-languages checkout (github.com/aether-lang-dev/
# aether-guest-languages; it was aether's contrib.host.lua until the
# guest-language bridges left aether), so the build needs that checkout
# on its --lib path, which the uniform `ae build` line in run.sh lacks.
#
# The module's bridge C comes in through its @source and dlopens liblua
# at run time: no Lua dev package, no -DAETHER_HAS_LUA, no bridge source
# to hunt for in an aether tree.
#
# Args (from run.sh): $1 AETHER (ae binary)  $2 output bin
#                     $3 LIB_DIR             $4 TOOLS_DIR
#
# Two outcomes, each producing a runnable $BIN so the suite stays green:
#   built — a checkout was found: the test runs (and says whether liblua
#           loaded)
#   skip  — no checkout: a tiny pass-through binary says so
#
# The checkout: $AEB_GUEST_LANGUAGES, else a sibling of this aeb checkout
# (../aether-guest-languages), else ~/scm/aether-guest-languages.
set -u

AETHER="$1"; BIN="$2"; LIB_DIR="$3"; TOOLS_DIR="$4"
: "$LIB_DIR" "$TOOLS_DIR"   # unused: test_host_lua.ae imports only `lua`
CC="${CC:-cc}"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SRC_DIR/test_host_lua.ae"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t 'host_lua')"
trap 'rm -rf "$TMP"' EXIT

emit_skip() {
    # $1 = reason. A trivial binary that reports a clean skip so the
    # run.sh PASS:/FAIL: scan keeps the suite green.
    cat > "$TMP/skip.c" <<EOF
#include <stdio.h>
int main(void) {
    puts("PASS: hosted Lua skipped — $1");
    puts("host lua tests done");
    return 0;
}
EOF
    "$CC" "$TMP/skip.c" -o "$BIN"
    exit $?
}

AGL=""
for cand in \
    "${AEB_GUEST_LANGUAGES:-}" \
    "$(cd "$SRC_DIR/../.." 2>/dev/null && pwd)/aether-guest-languages" \
    "$HOME/scm/aether-guest-languages"
do
    if [ -n "$cand" ] && [ -f "$cand/lua/module.ae" ]; then AGL="$cand"; break; fi
done
[ -z "$AGL" ] && emit_skip "no aether-guest-languages checkout (set AEB_GUEST_LANGUAGES)"

# Build from an empty directory: run from aeb's root, `ae build` also
# searches ./lib, where aeb's own build-tool SDK lib/lua (`lua.script()`
# and friends) would win the `import lua` over the guest-languages module.
cp "$SRC" "$TMP/test_host_lua.ae"
case "$BIN" in /*) OUT="$BIN" ;; *) OUT="$PWD/$BIN" ;; esac
if ! (cd "$TMP" && "$AETHER" build test_host_lua.ae --lib "$AGL" -o "$OUT.real") > "$TMP/build.log" 2>&1; then
    echo "host-lua: ae build against $AGL failed" >&2
    sed 's/^/  /' "$TMP/build.log" >&2
    exit 1
fi
echo "host-lua: built against $AGL"

# The bridge finds liblua by $AETHER_LUA_SONAME, then `liblua.so` only (a
# deliberate two-step contract, lua/README.md); finding the host's Lua is
# left to the caller, and the checkout ships the probe its own tests use
# (tests/lua_env.sh: Homebrew's dylib on macOS, the loader cache's
# versioned soname on Linux). $BIN is a wrapper that runs it first.
cat > "$OUT" <<EOF
#!/bin/sh
if [ -f "$AGL/tests/lua_env.sh" ]; then . "$AGL/tests/lua_env.sh"; lua_soname || true; fi
exec "$OUT.real" "\$@"
EOF
chmod +x "$OUT"
