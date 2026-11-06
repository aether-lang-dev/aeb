#!/usr/bin/env bash
# itests/symlinked-ae-stale-sibling.sh — a symlinked `ae` is followed to its
# install before aeb looks for the runtime beside it.
#
# The bug this guards (2026-11-05, Paul's Mac): `ae version use` leaves
# ~/.local/bin/ae -> ~/.aether/current/bin/ae, and an older get.sh install had
# left ~/.local/share/aether, ~/.local/include/aether and ~/.local/lib/libaether.a
# beside those symlinks. aeb took `dirname $(command -v ae)` as the toolchain
# dir, so every `<dir>/../share/aether` and `<dir>/../lib` probe found the
# stale install, and a 0.890.0 `ae`'s orchestrator was compiled against the
# older runtime: aeb's own build broke after `ae upgrade`.
#
# This stages that layout from the installed toolchain: a prefix whose bin/ae
# and bin/aetherc are symlinks to the real ones, and whose share/aether holds a
# poisoned runtime (aether_panic.h is an #error), then builds a small repo with
# AETHER pointing at the symlink. Followed, the build succeeds; not followed,
# the orchestrator's compile meets the #error.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/symlinked-ae-stale-sibling.sh
# Exit: 0 if the symlink is followed, 1 otherwise. POSIX hosts only (Windows'
# toolchain dir comes from MSYS paths and is not resolved; SKIP there).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="${AEB:-$REPO_ROOT/aeb}"
AETHER="${AETHER:-ae}"
if [ ! -x "$AEB" ]; then echo "error: aeb not found at '$AEB' (set \$AEB)" >&2; exit 1; fi
if ! command -v "$AETHER" >/dev/null 2>&1; then echo "error: '$AETHER' not found (set \$AETHER)" >&2; exit 1; fi
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "  SKIP: Windows (the toolchain dir is not symlink-resolved there)"; exit 0 ;; esac

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT

# The real install the symlinks point at (resolved, whatever $AETHER is).
AE_REAL="$(cd "$(dirname "$(command -v "$AETHER")")" && pwd -P)/$(basename "$(command -v "$AETHER")")"
while [ -L "$AE_REAL" ]; do
  t="$(readlink "$AE_REAL")"
  case "$t" in /*) AE_REAL="$t" ;; *) AE_REAL="$(cd "$(dirname "$AE_REAL")" && cd "$(dirname "$t")" && pwd -P)/$(basename "$t")" ;; esac
done
REAL_BIN="$(dirname "$AE_REAL")"
[ -x "$REAL_BIN/aetherc" ] || { echo "error: no aetherc beside $AE_REAL" >&2; exit 1; }

# The staged layout: symlinked binaries, a poisoned sibling runtime and archive.
SHIM="$WORK/shim"
mkdir -p "$SHIM/bin" "$SHIM/share/aether/runtime" "$SHIM/share/aether/std" "$SHIM/lib" "$SHIM/include/aether"
ln -s "$REAL_BIN/ae" "$SHIM/bin/ae"
ln -s "$REAL_BIN/aetherc" "$SHIM/bin/aetherc"
for h in aether_panic.h aether_runtime.h actor_state_machine.h; do
  printf '#error "stale sibling runtime: aeb did not follow the symlinked ae"\n' > "$SHIM/share/aether/runtime/$h"
done
printf 'not an archive\n' > "$SHIM/lib/libaether.a"

mk_repo() {
  local d="$1"; mkdir -p "$d/core"
  printf 'exports(hello)\nhello() -> string { return "x" }\n' > "$d/core/greet.ae"
  cat > "$d/core/.build.ae" <<'EOF'
import bldr
import aether
import aether (source, output)
aeb(cap) {
  bldr.build() {
    aether.shared_lib() { source("greet.ae") output("libgreet.so") }
  }
}
EOF
}

mk_repo "$WORK/repo"
export AETHER_HOME="$WORK/h"; mkdir -p "$AETHER_HOME"
LOG="$WORK/build.log"
( cd "$WORK/repo" && AETHER="$SHIM/bin/ae" "$AEB" --scan '.build.ae' ) >"$LOG" 2>&1
RC=$?
# Not followed shows as either the poisoned header reaching the compiler or the
# poisoned archive reaching aeb-link's libaether floor check, whichever is probed first.
if grep -q "stale sibling runtime" "$LOG" || grep -q "$SHIM/lib/libaether.a\|$SHIM/bin/../lib" "$LOG"; then
  fail "the build used the runtime beside the symlink, not the install it points at"
  grep -m3 "stale sibling runtime\|libaether" "$LOG" | sed 's/^/    /'
elif [ "$RC" -eq 0 ] && [ -f "$WORK/repo/target/_ae_build_all" ] && [ -f "$WORK/repo/target/build/core/lib/libgreet.so" ]; then
  pass "a symlinked ae is followed to its install (the stale sibling runtime is not used)"
else
  fail "unexpected outcome (rc=$RC)"; tail -12 "$LOG" | sed 's/^/    /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "symlinked-ae-stale-sibling: all assertions passed"
  exit 0
else
  echo "symlinked-ae-stale-sibling: $FAILURES assertion(s) FAILED"
  exit 1
fi
