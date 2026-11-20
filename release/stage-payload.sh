#!/usr/bin/env bash
# release/stage-payload.sh — stage aeb's source payload: the tree both the
# bootstrap tarball and every per-platform bundle are made from.
#
#   release/stage-payload.sh TAG STAGE_DIR
#
# Run from a checkout of aeb. STAGE_DIR is created (it is removed first if it
# exists). The payload is source only: the bash trampoline, tools/*.ae, lib/,
# veto/, sandbox/, the AETHER_PIN / AETHER_FETCH files, a VERSION holding TAG,
# and no prebuilt executable. The release workflow calls this, and so does
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
cp -r lib tools veto sandbox "$STAGE/"
mkdir -p "$STAGE/docs"
cp docs/aeb-host-vm-or-container-setup.md "$STAGE/docs/" || true

# Drop every build artefact from the copy: a developer checkout may hold
# built helpers (gitignored, mode +x, not .ae/.md) and their toolchain stamps.
# The payload is SOURCE ONLY; a stray binary in it would be a prebuilt tool
# for one platform shipped to all of them.
find "$STAGE/tools" -type f -perm -u+x ! -name '*.ae' ! -name '*.md' -delete || true
find "$STAGE/tools" -type f -name '*.toolchain' -delete || true

# The resolver jar and its sources are built separately and published as
# their own asset (aeb-resolve.jar); keep them out of the payload.
rm -f "$STAGE/tools/aeb-resolve.jar"
rm -rf "$STAGE/tools/resolver"
