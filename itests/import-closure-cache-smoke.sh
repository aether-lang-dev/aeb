#!/usr/bin/env bash
# itests/import-closure-cache-smoke.sh — editing ANY module in an aether.program's
# import closure busts the link cache, wherever that module resolves from.
#
# The bug (seen building aether-ui / OpenDisk-ae): after editing an imported
# module, an aeb rebuild got a cache HIT and restored the previous binary, so the
# edit never reached it. `_cache_key_for_aether_link` walked the import closure
# against source_dir + its ANCESTORS only. A module reached through a node
# `lib("...")` dir — a sibling checkout, often via a relative symlink such as
# OpenDisk-ae's `aether-ui -> ../aether-ui` — never resolved, so neither it nor
# anything IT imported was hashed. (The lib() contribution hashed only the
# `<dir>/*.ae` files directly in the dir, never `<dir>/<mod>/module.ae`.)
#
# Fixture (all outside the app's ancestor chain):
#   shared/greet/module.ae   imports `deep`      (the "aether-ui" stand-in,
#   shared/deep/module.ae                         reached via app/sib -> ../shared)
#   vendor/plain/module.ae                       (a plain, non-symlinked lib dir)
#   app/main.ae              imports greet + plain; lib("sib") + lib("../vendor")
#
# Assertions (manual aetherc+gcc path — link_flag forces it; that is the path
# with the content-addressed link cache):
#   1. COLD          — builds and prints the original values.
#   2. WARM HIT      — an unchanged rebuild is a cache hit (key is stable).
#   3. LIB DIR       — edit vendor/plain/module.ae only → rebuilt, edit visible.
#   4. SYMLINKED LIB — edit shared/greet/module.ae only → rebuilt, edit visible.
#   5. TWO DEEP      — edit shared/deep/module.ae only (main → greet → deep)
#                      → rebuilt, edit visible.
#   6. WARM HIT      — unchanged rebuild after all that is a hit again.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/import-closure-cache-smoke.sh
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
trap 'rm -rf "$WORK"' EXIT
export AETHER_CACHE_DIR="$WORK/aecache"; mkdir -p "$AETHER_CACHE_DIR"
export AEB_CACHE_DIR="$WORK/aebcache"; mkdir -p "$AEB_CACHE_DIR"
unset AEB_NO_CACHE

# --- Fixture -----------------------------------------------------------------
mkdir -p "$WORK/shared/greet" "$WORK/shared/deep" "$WORK/vendor/plain" "$WORK/app"
cat > "$WORK/shared/deep/module.ae" <<'EOF'
deep_word() -> string { return "deep1" }
EOF
cat > "$WORK/shared/greet/module.ae" <<'EOF'
import deep (deep_word)
greet_word() -> string { return "greet1" }
greet_deep() -> string { return deep_word() }
EOF
cat > "$WORK/vendor/plain/module.ae" <<'EOF'
plain_word() -> string { return "plain1" }
EOF
ln -s ../shared "$WORK/app/sib"
cat > "$WORK/app/main.ae" <<'EOF'
import greet (greet_word, greet_deep)
import plain (plain_word)
main() {
    println("${greet_word()} ${greet_deep()} ${plain_word()}")
}
EOF
cat > "$WORK/app/.build.ae" <<'EOF'
import bldr
import aether
import aether (source, output, link_flag, lib)
aeb(cap) {
    bldr.build() {
        aether.program() {
            source("main.ae")
            output("prog")
            lib("sib")
            lib("../vendor")
            link_flag("-lm")
        }
    }
}
EOF

find_bin() { find "$1" -name "$2" -type f 2>/dev/null | head -1; }
LAST_OUT=""
build() { LAST_OUT="$( cd "$WORK/app" && "$AEB" .build.ae 2>&1 )"; [ -n "${DEBUG_IT:-}" ] && echo "$LAST_OUT" | sed "s/^/      | /"; }
run_prog() { b="$(find_bin "$WORK/app/target" prog)"; [ -n "$b" ] && "$b" 2>/dev/null; }
was_hit() { echo "$LAST_OUT" | grep -qE 'aether cache hit|^ *build: +\. +[0-9.]+s \[hit\]'; }

check() {   # check <label> <expected-output> <expect-hit:0|1>
  got="$(run_prog)"
  if [ "$got" != "$2" ]; then
    fail "$1: binary prints '$got', expected '$2'"
    if was_hit; then echo "    (stale cache HIT served the old binary)"; fi
    echo "$LAST_OUT" | grep -iE 'error|undefined|fail' | head -4 | sed 's/^/    /'
    return
  fi
  if [ "$3" = "1" ] && ! was_hit; then fail "$1: expected a cache hit, got a rebuild"; return; fi
  if [ "$3" = "0" ] && was_hit; then fail "$1: expected a rebuild, got a cache hit"; return; fi
  pass "$1"
}

echo "=== import-closure-cache-smoke ==="

# 1. COLD
build
check "cold build prints original values" "greet1 deep1 plain1" 0

# 2. WARM HIT
build
check "unchanged rebuild is a cache hit" "greet1 deep1 plain1" 1

# 3. LIB DIR (plain, non-symlinked lib() dir outside the ancestor chain)
sed -i.bak 's/plain1/plain2/' "$WORK/vendor/plain/module.ae" && rm -f "$WORK/vendor/plain/module.ae.bak"
build
check "edit to a module in a lib() dir busts the cache" "greet1 deep1 plain2" 0

# 4. SYMLINKED LIB (sibling checkout reached via app/sib -> ../shared)
sed -i.bak 's/greet1/greet2/' "$WORK/shared/greet/module.ae" && rm -f "$WORK/shared/greet/module.ae.bak"
build
check "edit to a module in a symlinked lib() dir busts the cache" "greet2 deep1 plain2" 0

# 5. TWO DEEP (main -> greet -> deep; edit only deep)
sed -i.bak 's/deep1/deep2/' "$WORK/shared/deep/module.ae" && rm -f "$WORK/shared/deep/module.ae.bak"
build
check "edit to a transitively-imported (2-deep) module busts the cache" "greet2 deep2 plain2" 0

# 6. WARM HIT again
build
check "unchanged rebuild after the edits is a cache hit" "greet2 deep2 plain2" 1

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "import-closure-cache-smoke: all assertions passed"
  exit 0
fi
echo "import-closure-cache-smoke: $FAILURES assertion(s) FAILED"
exit 1
