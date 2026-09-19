#!/usr/bin/env bash
# itests/ae-add-binary-package-smoke.sh — end-to-end test of the ae-add
# binary-package EMITTER (lib/aether: aether.emit_binary_package).
#
# aeb builds an Aether shared lib and stages it as an `ae add`-consumable
# binary package: aether.toml ([package] binary = "<stem>", modules="."),
# <stem>-<tag>-<triple><ext>, and its .sha256 sidecar. This drives the whole
# producer→consumer round trip against the REAL `ae add` (0.694+) so it proves
# aeb emits exactly the contract ae_try_binary_package() parses — not just that
# a string generator produces plausible text (that's the unit test's job).
#
# Assertions:
#   1. EMIT STAGES TRIO   — aether.toml + <stem>-<tag>-<triple><ext> + .sha256
#   2. MANIFEST SIGNAL    — the aether.toml carries `binary = "<stem>"` + modules="."
#   3. ASSET NAME         — the lib is named <stem>-<tag>-<triple><ext> exactly
#   4. SHA MATCHES        — the sidecar's hex equals the staged lib's real sha256
#   5. AE ADD INSTALLS    — `ae add <pkg>@<tag>` (file:// forge) installs it,
#                           reporting "Checksum verified." (the sidecar is honoured)
#   6. IMPORT RESOLVES    — a consumer `import <stem>` runs and prints the fn output
#
# `ae add` binary packages need Aether >= 0.694; if this `ae` is older the whole
# test SKIPs (exit 0) rather than failing — the emitter is still valid, the
# consumer toolchain just can't exercise it.
#
# Usage: AEB=/path/to/aeb AETHER=/path/to/ae ./itests/ae-add-binary-package-smoke.sh
# Exit code: 0 if every assertion passed (or skipped); 1 otherwise.

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

STEM="greetlib"
TAG="v0.2.0"
PKG="github.com/test/greetpkg"

# --- 1. A trivial Aether lib + a node that builds it and emits the package. ---
LIBDIR="$WORK/src"
mkdir -p "$LIBDIR"
cat > "$LIBDIR/greet.ae" <<EOF
exports(hello)
hello() -> string { return "binpkg ok" }
EOF
cat > "$LIBDIR/.lib.ae" <<EOF
import bldr
import aether
import aether (source, output, stem, release_tag)
aeb(cap) {
    bldr.build() {
        aether.shared_lib() {
            source("greet.ae")
            output("lib${STEM}.so")
        }
        aether.emit_binary_package() {
            source("greet.ae")
            output("lib${STEM}.so")
            stem("${STEM}")
            release_tag("${TAG}")
        }
    }
}
EOF

export AETHER_HOME="$WORK/aehome_build"; mkdir -p "$AETHER_HOME"
( cd "$LIBDIR" && "$AEB" .lib.ae ) >"$WORK/emit.log" 2>&1

# The node is .lib.ae so its target dir is target/lib/; the package is ae-add/.
PKGDIR="$LIBDIR/target/lib/ae-add"
EXT=".so"   # this host: linux/freebsd. (macOS .dylib / Windows .dll — the emit
            # names for the running host; a matrix release runs one per platform.)
case "$(uname -s)" in Darwin) EXT=".dylib";; MINGW*|MSYS*|CYGWIN*) EXT=".dll";; esac
# host triple, matching bldr._host_os_arch / ae_host_triple
OS="linux"; case "$(uname -s)" in Darwin) OS="macos";; FreeBSD) OS="freebsd";; MINGW*|MSYS*|CYGWIN*) OS="windows";; esac
ARCH="$(uname -m)"; case "$ARCH" in aarch64|arm64) ARCH="arm64";; esac
ASSET="${STEM}-${TAG}-${OS}-${ARCH}${EXT}"

# 1. trio present
if [ -f "$PKGDIR/aether.toml" ] && [ -f "$PKGDIR/$ASSET" ] && [ -f "$PKGDIR/$ASSET.sha256" ]; then
  pass "emit staged the trio (aether.toml + $ASSET + .sha256)"
else
  fail "emit did not stage the trio under $PKGDIR"; ls -la "$PKGDIR" 2>&1 | sed 's/^/    /'; cat "$WORK/emit.log" | tail -20 | sed 's/^/    /'
fi

# 2. manifest signal
if grep -q "binary = \"${STEM}\"" "$PKGDIR/aether.toml" 2>/dev/null && grep -q 'modules = "."' "$PKGDIR/aether.toml" 2>/dev/null; then
  pass "aether.toml carries binary = \"$STEM\" + modules = \".\""
else
  fail "aether.toml missing the binary-package signal"; cat "$PKGDIR/aether.toml" 2>&1 | sed 's/^/    /'
fi

# 3. asset name exact
if [ -f "$PKGDIR/$ASSET" ]; then
  pass "lib asset named $ASSET (<stem>-<tag>-<triple><ext>)"
else
  fail "expected asset $ASSET not found"; ls "$PKGDIR" 2>&1 | sed 's/^/    /'
fi

# 4. sha matches the staged lib
if command -v sha256sum >/dev/null 2>&1; then HASHER="sha256sum"; else HASHER="shasum -a 256"; fi
if [ -f "$PKGDIR/$ASSET" ] && [ -f "$PKGDIR/$ASSET.sha256" ]; then
  GOT="$($HASHER "$PKGDIR/$ASSET" 2>/dev/null | awk '{print $1}')"
  WANT="$(awk '{print $1}' "$PKGDIR/$ASSET.sha256" 2>/dev/null)"
  if [ -n "$GOT" ] && [ "$GOT" = "$WANT" ]; then
    pass "sidecar sha256 matches the staged lib"
  else
    fail "sha256 mismatch: sidecar=$WANT computed=$GOT"
  fi
else
  fail "cannot check sha256 (asset or sidecar missing)"
fi

# --- 5 + 6. Real `ae add` round trip against a file:// forge. ---
AEVER="$("$AETHER" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
ae_ge_694() {
  # returns 0 if AEVER >= 0.694.0
  [ -n "$AEVER" ] || return 1
  printf '%s\n0.694.0\n' "$AEVER" | sort -V | head -1 | grep -q '^0\.694\.0$' && return 0
  [ "$AEVER" = "0.694.0" ] && return 0
  # sort -V puts the smaller first; if 0.694.0 is first, AEVER >= it
  [ "$(printf '0.694.0\n%s\n' "$AEVER" | sort -V | head -1)" = "0.694.0" ]
}

if ! ae_ge_694; then
  echo "  SKIP: ae $AEVER < 0.694.0 — ae add binary packages unsupported; emitter assertions above stand"
else
  FORGE="$WORK/forge"
  DEST="$FORGE/$PKG/releases/download/$TAG"
  mkdir -p "$DEST"
  cp "$PKGDIR"/* "$DEST/" 2>/dev/null
  CONSUMER="$WORK/consumer"; mkdir -p "$CONSUMER"
  printf '[package]\nname = "consumer"\n' > "$CONSUMER/aether.toml"
  cat > "$CONSUMER/main.ae" <<EOF
import ${STEM}
main() { println(${STEM}.hello()) }
EOF
  export AETHER_HOME="$WORK/aehome_consume"; mkdir -p "$AETHER_HOME"
  export AE_RELEASE_BASE_URL="file://$FORGE"
  # ae add caches installed packages under $HOME/.aether/packages (keyed by
  # get_home_dir(), NOT AETHER_HOME) and SKIPS the fetch when that dir already
  # exists. Isolate HOME so a prior run's cache can't short-circuit this one
  # (the fetch/verify path is exactly what we're testing).
  export HOME="$WORK/fakehome"; mkdir -p "$HOME"

  ADDLOG="$WORK/add.log"
  ( cd "$CONSUMER" && "$AETHER" add "$PKG@$TAG" ) >"$ADDLOG" 2>&1
  if grep -q "Checksum verified" "$ADDLOG" && grep -qi "as a binary package" "$ADDLOG"; then
    pass "ae add installed it as a binary package (checksum verified)"
  else
    fail "ae add did not install it"; cat "$ADDLOG" | sed 's/^/    /'
  fi

  RUNLOG="$WORK/run.log"
  ( cd "$CONSUMER" && "$AETHER" run main.ae ) >"$RUNLOG" 2>&1
  if grep -q "binpkg ok" "$RUNLOG"; then
    pass "consumer import ${STEM} resolves + runs (printed the fn output)"
  else
    fail "consumer could not import/run the installed package"; cat "$RUNLOG" | tail -15 | sed 's/^/    /'
  fi
fi

# --- 7. Cross-target emit (the one-host matrix release model). ---
# A cross target() names the asset for the BUILT triple, not the host: a Linux
# host cross-building x86_64-windows must stage greetlib-<tag>-windows-x86_64.dll
# (ae-add triple spelling + .dll), reading the cross-mangled libX.so.dll that
# `ae build --emit=lib --target=` wrote. This is what lets one host emit the full
# per-triple set through the builder (servirtium-vcr / selenium release model).
XLIBDIR="$WORK/xsrc"
mkdir -p "$XLIBDIR"
cat > "$XLIBDIR/greet.ae" <<EOF
exports(hello)
hello() -> string { return "cross ok" }
EOF
cat > "$XLIBDIR/.lib.ae" <<EOF
import bldr
import aether
import aether (source, output, stem, release_tag, target)
aeb(cap) {
    bldr.build() {
        aether.shared_lib() { source("greet.ae") output("lib${STEM}.so") target("x86_64-windows") }
        aether.emit_binary_package() { source("greet.ae") output("lib${STEM}.so") stem("${STEM}") release_tag("${TAG}") target("x86_64-windows") }
    }
}
EOF
export AETHER_HOME="$WORK/aehome_cross"; mkdir -p "$AETHER_HOME"
( cd "$XLIBDIR" && "$AEB" .lib.ae ) >"$WORK/cross.log" 2>&1
XRC=$?
XPKGDIR="$XLIBDIR/target/lib/ae-add"
XASSET="${STEM}-${TAG}-windows-x86_64.dll"
if [ "$XRC" -ne 0 ]; then
  # Cross-build needs zig cc; if the toolchain can't cross to windows, SKIP the
  # cross leg rather than fail (the naming logic is unit-tested regardless).
  if grep -qiE 'zig|cross|target|toolchain|not found|Unknown target' "$WORK/cross.log"; then
    echo "  SKIP: cross-build to x86_64-windows unavailable here (no zig cc?) — target() naming is unit-tested"
  else
    fail "cross-target emit build failed"; tail -12 "$WORK/cross.log" | sed 's/^/    /'
  fi
elif [ -f "$XPKGDIR/$XASSET" ] && [ -f "$XPKGDIR/$XASSET.sha256" ]; then
  pass "cross target(x86_64-windows) staged $XASSET (ae-add triple + .dll, not host)"
else
  fail "cross emit did not stage $XASSET"; ls -la "$XPKGDIR" 2>&1 | sed 's/^/    /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ae-add-binary-package-smoke: all assertions passed"
  exit 0
else
  echo "ae-add-binary-package-smoke: $FAILURES assertion(s) FAILED"
  exit 1
fi
