#!/usr/bin/env bash
# release/stage-payload.sh — stage aeb's source payload: the tree both the
# bootstrap tarball and every per-platform bundle are made from.
#
#   release/stage-payload.sh TAG STAGE_DIR
#
# Run from a checkout of aeb. STAGE_DIR is created (it is removed first if it
# exists). The payload is source only: the bash trampoline, tools/*.ae, lib/,
# veto/, sandbox/, the AETHER_PIN / AETHER_FETCH files, a VERSION holding TAG,
# the host/VM/container setup guide, and no prebuilt executable. The release workflow calls this, and so does
# itests/prebuilt-bundle-no-rebuild.sh, so the test stages the way a release does.
set -euo pipefail

TAG="${1:?usage: stage-payload.sh TAG STAGE_DIR}"
STAGE="${2:?usage: stage-payload.sh TAG STAGE_DIR}"

rm -rf "$STAGE"
mkdir -p "$STAGE"

cp aeb AETHER_PIN AETHER_FETCH Makefile LICENSE README.md "$STAGE/"
# VERSION is how an unpacked payload (no .git) reports its tag: `make install`
# copies it into AEB_STAMP's `version` field, and a bundle's prebuilt helpers
# are stamped against it (see release/build-bundle.sh).
printf '%s' "$TAG" > "$STAGE/VERSION"
# What goes in is what git tracks, not a copy of the directories. A developer
# checkout holds built helpers (tools/aeb-main and friends, gitignored, mode
# +x), their toolchain stamps, a built libaether_sandbox.so, the resolver jar
# and leftovers of aborted builds; the payload is SOURCE ONLY, and a stray
# binary in it would be a prebuilt tool for one platform shipped to all of them.
# Copying only tracked files keeps every one of those out without a list of
# what to delete, and keeps what an earlier version deleted by file mode
# (tools/aeb-cc.sh, tools/aeb-watch, tools/resolve-imports.sh, tools/cargo-*.sh,
# tools/container/aeb-ctr: scripts aeb runs, or offers, from tools/) in.
# release/check-payload.sh asserts the result.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "stage-payload: not a git checkout; cannot tell the sources from the built files" >&2
    exit 1
fi
git ls-files -z -- lib tools veto sandbox docs/guides/aeb-host-vm-or-container-setup.md \
    | tar --null -T - -cf - | tar -xf - -C "$STAGE"

# The resolver jar's sources are built separately and its jar is published as
# its own asset (aeb-resolve.jar); keep them out of the payload.
rm -rf "$STAGE/tools/resolver"
