#!/usr/bin/env bash
# release/check-payload.sh — assert what a staged payload, or the share/aeb tree
# of a built bundle, actually contains.
#
#   release/check-payload.sh [--bundle] TREE REPO
#
#   TREE    the staged payload (release/stage-payload.sh output), or with
#           --bundle the share/aeb directory of a bundle (release/build-bundle.sh)
#   REPO    the aeb checkout the tree was made from; what the tree must hold is
#           read from it, so a new script nobody remembered to ship fails here
#
# Exit 0 when the tree is right, 1 with every problem listed when it is not.
# The release workflow runs it on the payload before publishing, and
# itests/prebuilt-bundle-no-rebuild.sh runs it on the payload and on a bundle.
#
# What "right" means:
#
#   1. Every file git tracks under tools/, lib/, veto/ and sandbox/ is in the
#      tree, with the same executable bit, except tools/resolver/ (the Maven
#      resolver's sources: its jar is its own release asset). tools/aeb-cc.sh,
#      tools/aeb-watch, tools/gh-release-fetch.sh and tools/container/aeb-ctr
#      are not .ae files, and a payload once dropped them with the built helpers.
#   2. Every tools/ name that aeb's own runtime sources (the trampoline, the
#      tools, the SDK modules) mention is accounted for: a file the repo tracks
#      (and so rule 1 requires), a helper built from a tools/*.ae source, or one
#      of the few things built or fetched on first use (BUILT_ON_DEMAND below).
#      A name that is none of these is reported, so a new runtime script is
#      either shipped or named here on purpose.
#   3. Nothing else is in the tree beyond the payload's own VERSION and, in a
#      bundle, BUNDLE and the five prebuilt helpers (SHIPPED_HELPERS, the
#      INSTALL_TOOLS of the Makefile) with their stamps. So no other built
#      helper, no toolchain stamp of one that is not shipped, no Windows
#      debug-symbol (.pdb) file, no editor leftover.
#   4. VERSION is present and non-empty. The setup guide the release notes
#      point to, docs/guides/aeb-host-vm-or-container-setup.md, is among the
#      tracked files rule 1 asks for.
set -uo pipefail

BUNDLE=0
if [ "${1:-}" = "--bundle" ]; then BUNDLE=1; shift; fi
TREE="${1:?usage: check-payload.sh [--bundle] TREE REPO}"
REPO="${2:?usage: check-payload.sh [--bundle] TREE REPO}"
TREE="$(cd "$TREE" && pwd)"
REPO="$(cd "$REPO" && pwd)"

# Keep in step with INSTALL_TOOLS in the Makefile and TOOLS in build-bundle.sh.
SHIPPED_HELPERS="aeb-main aeb-link aeb-graph affected-targets gcheckout"
# Named by the runtime sources but not shipped, on purpose: the Maven resolver
# jar is its own release asset (fetched on first JVM build), and the sandbox
# preload library is compiled from the Aether runtime the first time --sandbox
# is used.
BUILT_ON_DEMAND="aeb-resolve.jar resolver libaether_sandbox.so"

PROBLEMS=0
problem() { echo "check-payload: $1"; PROBLEMS=$((PROBLEMS + 1)); }

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "check-payload: $REPO is not a git checkout; cannot tell what it tracks" >&2
    exit 1
fi

# Tracked files: "<mode> <path>", the paths a payload is made of.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
TRACKED="$SCRATCH/tracked"
git -C "$REPO" ls-files -s -- tools lib veto sandbox aeb AETHER_PIN AETHER_FETCH Makefile LICENSE README.md \
    docs/guides/aeb-host-vm-or-container-setup.md | awk '{print $1, $4}' > "$TRACKED"

in_set() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
is_tracked() { awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' "$TRACKED"; }

# --- 1. everything tracked is shipped, executable bit and all ---------------
while read -r mode path; do
    case "$path" in tools/resolver/*) continue ;; esac
    if [ ! -f "$TREE/$path" ]; then problem "missing: $path"; continue; fi
    if [ "$mode" = 100755 ] && [ ! -x "$TREE/$path" ]; then problem "not executable: $path"; fi
done < "$TRACKED"

# --- 2. every tools/ name the runtime sources mention is accounted for ------
NAMES="$(
    cd "$REPO" && {
        [ -f aeb ] && cat aeb
        find tools lib -name '*.ae' -type f -exec cat {} +
    } | grep -v '^[[:space:]]*\(#\|//\)' | grep -oE 'tools/[A-Za-z0-9_.-]+' | sed 's|^tools/||' | sort -u
)"
for name in $NAMES; do
    case "$name" in *.ae) continue ;; esac                  # a source file, named in a message or a build
    if [ -f "$REPO/tools/$name.ae" ]; then continue; fi    # a helper built from its source
    if [ -d "$REPO/tools/$name" ]; then continue; fi       # a directory of aeb nodes or an aeb module; rule 1 covers its files
    if in_set "$name" "$BUILT_ON_DEMAND"; then continue; fi
    if is_tracked "tools/$name"; then
        # rule 1 already demands it; say so by name when a script the runtime
        # runs is the one that is gone
        [ -f "$TREE/tools/$name" ] || problem "the runtime runs tools/$name and the tree has none"
        continue
    fi
    problem "the runtime sources name tools/$name, which is not tracked, not a helper built from tools/$name.ae, and not in BUILT_ON_DEMAND (release/check-payload.sh): ship it or say why not"
done

# --- 3. nothing else ---------------------------------------------------------
EXPECTED_EXTRA="VERSION"
if [ "$BUNDLE" = 1 ]; then
    EXPECTED_EXTRA="VERSION BUNDLE"
    for t in $SHIPPED_HELPERS; do
        if [ ! -f "$TREE/tools/$t" ] && [ ! -f "$TREE/tools/$t.exe" ]; then problem "the bundle has no prebuilt tools/$t"; fi
        if [ ! -f "$TREE/tools/$t.toolchain" ]; then problem "the bundle has no stamp tools/$t.toolchain"; fi
    done
fi
( cd "$TREE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$SCRATCH/files"
while read -r f; do
    if is_tracked "$f"; then continue; fi
    if in_set "$f" "$EXPECTED_EXTRA"; then continue; fi
    if [ "$BUNDLE" = 1 ]; then
        ok=0
        for t in $SHIPPED_HELPERS; do
            case "$f" in "tools/$t"|"tools/$t.exe"|"tools/$t.toolchain") ok=1 ;; esac
        done
        [ "$ok" = 1 ] && continue
    fi
    problem "not part of the release: $f"
done < "$SCRATCH/files"

# --- 4. VERSION (the guide is a tracked file, so rule 1 asks for it) ---------
[ -s "$TREE/VERSION" ] || problem "VERSION is missing or empty"

if [ "$PROBLEMS" -gt 0 ]; then
    echo "check-payload: $PROBLEMS problem(s) in $TREE"
    exit 1
fi
echo "check-payload: $TREE is complete ($(wc -l < "$TRACKED" | tr -d ' ') tracked files considered)"
exit 0
