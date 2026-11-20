#!/usr/bin/env bash
# release/build-bundle.sh — build one per-platform aeb bundle: the staged
# payload plus the five install tools prebuilt for the target, an install.sh
# that copies (no make, no compiler), and the stamps that let aeb keep those
# prebuilt tools on a machine that has no C compiler.
#
#   release/build-bundle.sh [--archive] AE STAGE OUT TARGET SUFFIX TAG
#
#   AE      the ae that cross-builds (the release workflow's fetched AETHER_FETCH)
#   STAGE   the payload, from release/stage-payload.sh
#   OUT     the directory that receives aeb-SUFFIX/ (and, with --archive, the
#           .zip, .tar.gz and a .sha256 for each)
#   TARGET  a zig triple (x86_64-linux, aarch64-macos, x86_64-windows, ...), or
#           "native" for the host with the host compiler, which is only for
#           tests: a release uses a triple
#   SUFFIX  the bundle's platform name, e.g. linux-x86_64 or windows-arm64
#   TAG     the release tag, e.g. v0.349
#
# Exit 0 when the bundle is complete; 1 when a tool failed to build (the release
# workflow then skips that platform); 2 when the install.sh smoke failed, which
# is a bug in the bundle itself, not in one target.
# AETHER_SYSROOT, if set, is passed through to the cross-build (FreeBSD).
#
# --- What the stamps say, and why they are sound ----------------------------
#
# A helper in a development tree is stamped with the toolchain that built it
# ("<aetherc> (<version>)"), because it is a program linked against that
# toolchain's runtime and built from sources that move: aeb rebuilds it when the
# toolchain or a source changes (the trampoline's aeb_fresh, tools/aebfresh).
#
# A bundle's helpers are different. They were linked statically here, on the
# release runner, and need nothing from the toolchain on the machine they run
# on: `ldd` shows only libc and libm, and they reach the user's `ae` only as a
# program they run, through its command line. The user's `ae` compiles the
# project's orchestrator with its own runtime; no object of the helper's
# runtime is ever mixed with it. So a bundle's helpers stay valid for any
# toolchain the trampoline accepts (any `ae` that meets AETHER_PIN, or the one
# a user names with AETHER): what has to be true is that they belong to THIS
# tree. Each is therefore stamped
#
#       prebuilt <TAG> <SUFFIX>
#
# and aeb keeps it only when the tree's own VERSION and BUNDLE files (written
# here, copied by install.sh) name that same tag and platform. Neither a
# development tree (no BUNDLE) nor an unstamped file nor a helper from another
# release or platform can satisfy it. The toolchain is deliberately not part of
# the check, and neither is a file time: install.sh keeps times, but an unpacked
# or copied tree must not rebuild because its mtimes were scrambled.
set -uo pipefail

ARCHIVE=0
if [ "${1:-}" = "--archive" ]; then ARCHIVE=1; shift; fi
AE="${1:?usage: build-bundle.sh [--archive] AE STAGE OUT TARGET SUFFIX TAG}"
SRC="${2:?missing STAGE}"
OUT="${3:?missing OUT}"
TRIPLE="${4:?missing TARGET}"
SUFFIX="${5:?missing SUFFIX}"
TAG="${6:?missing TAG}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# The five tools `make install` puts in INSTALL_TOOLS: what a bundle ships.
TOOLS="aeb-main aeb-link aeb-graph affected-targets gcheckout"

mkdir -p "$OUT"
B="$OUT/aeb-$SUFFIX"
LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

rm -rf "$B"; mkdir -p "$B/share/aeb" "$B/bin"
cp -R "$SRC"/. "$B/share/aeb/"
cp -f "$SRC/aeb" "$B/bin/aeb"; chmod +x "$B/bin/aeb" "$B/share/aeb/aeb"

fail=0
for t in $TOOLS; do
    extra=""; [ "$t" = aeb-main ] && extra="--lib $SRC/lib"
    target_flag=""; [ "$TRIPLE" != native ] && target_flag="--target=$TRIPLE"
    # shellcheck disable=SC2086
    if ! "$AE" build $target_flag "$SRC/tools/$t.ae" \
           -o "$B/share/aeb/tools/$t" --lib "$SRC/tools" $extra >"$LOGS/$t.log" 2>&1; then
        echo "  $SUFFIX: $t cross-build FAILED"; sed -n '1,5p' "$LOGS/$t.log"; fail=1
        continue
    fi
    printf 'prebuilt %s %s\n' "$TAG" "$SUFFIX" > "$B/share/aeb/tools/$t.toolchain"
done
if [ "$fail" != 0 ]; then
    echo "  ⚠️  aeb-$SUFFIX skipped (a tool failed to cross-build)"
    exit 1
fi
printf '%s\n' "$SUFFIX" > "$B/share/aeb/BUNDLE"

cp "$HERE/bundle-install.sh" "$B/install.sh"; chmod +x "$B/install.sh"

# Smoke: install into a scratch prefix whose pin files are stale, and check the
# install refreshed them and carried the bundle identity and every stamp.
P="$(mktemp -d)"; mkdir -p "$P/share/aeb"
echo 0.0.1 > "$P/share/aeb/AETHER_PIN"; echo 0.0.1 > "$P/share/aeb/AETHER_FETCH"
"$B/install.sh" "$P" >/dev/null
for f in AETHER_PIN AETHER_FETCH VERSION BUNDLE; do
    if ! cmp -s "$B/share/aeb/$f" "$P/share/aeb/$f"; then
        echo "  $SUFFIX: install.sh left a stale $f"; fail=1
    fi
done
for t in $TOOLS; do
    if ! cmp -s "$B/share/aeb/tools/$t.toolchain" "$P/share/aeb/tools/$t.toolchain"; then
        echo "  $SUFFIX: install.sh lost the stamp of $t"; fail=1
    fi
done
rm -rf "$P"
if [ "$fail" != 0 ]; then echo "::error::install.sh smoke failed"; exit 2; fi

if [ "$ARCHIVE" = 1 ]; then
    ( cd "$OUT" && zip -qr "aeb-$SUFFIX.zip" "aeb-$SUFFIX" )
    ( cd "$OUT" && tar -czf "aeb-$SUFFIX.tar.gz" "aeb-$SUFFIX" )
    ( cd "$OUT" && sha256sum "aeb-$SUFFIX.zip"    > "aeb-$SUFFIX.zip.sha256" )
    ( cd "$OUT" && sha256sum "aeb-$SUFFIX.tar.gz" > "aeb-$SUFFIX.tar.gz.sha256" )
    echo "  ✅ aeb-$SUFFIX.{zip,tar.gz} (+ .sha256 each) ($(du -h "$OUT/aeb-$SUFFIX.zip" | cut -f1) / $(du -h "$OUT/aeb-$SUFFIX.tar.gz" | cut -f1))"
fi
exit 0
