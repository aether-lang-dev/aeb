#!/usr/bin/env bash
# itests/container-emit-only.sh — container.image must actually write a file.
#
# THE BUG THIS PREVENTS. `container.image` computes its Dockerfile path as
# target/<type>/<dir>/Dockerfile and then wrote it with:
#
#     _e5 = io.write_file(df_path, df_content)
#
# Two mistakes in one line. Nothing had created target/<type>/<dir> — every
# other SDK mkdirs its own output dir first (lib/c does it five times over;
# container.run, twenty lines further down this same file, does it too) — so
# the write failed. And io.write_file's return, which is "" on success and an
# error string on failure, went into a discard variable, so the failure was
# never seen. The builder carried on and returned 0.
#
# Under AEB_CONTAINER_EMIT_ONLY that was the whole node: a green build, a
# telemetry row indistinguishable from a real one, and no Dockerfile anywhere
# on disk. On the normal path it surfaced much later and pointing at the
# wrong thing — `podman build` failing to open a -f file nobody had noticed
# was missing.
#
# WHY THE UNIT SUITE MISSED IT. tests/test_container_dockerfile.ae is a good
# test of dockerfile_full_content(): it asserts the exact generated string,
# including that ordered run/workdir/run steps render in call order. It was
# passing throughout, because the string was never wrong. The defect was
# entirely in what the builder did with the string, and tests/run.sh runs
# Aether unit tests with no builder context and no filesystem — it cannot
# reach a builder body. This script is the other half: same grammar, driven
# through a real aeb node, asserting on the file.
#
# WHY EMIT-ONLY. AEB_CONTAINER_EMIT_ONLY is the immutable-host adapter
# (docs/design/containment-and-the-control-plane.md) — generate the
# Dockerfile, skip `podman build`. That makes it exactly the right harness
# here: it exercises setters, generation and the write, and needs no
# container engine, no image pull and no network. It is also the path where
# the bug was total rather than merely confusing.
#
# ASSERT ON THE ARTIFACT, NOT ON $?. The broken builder exited 0. A test
# that checked only the exit code would have passed against the bug — the
# same lesson as build-failure-visibility.sh.
#
# Mutation-checked: drop the bldr._mkdirs(target_dir) from container.image
# and 5 assertions fail — all of rounds 1 and 2, plus round 3's setup check,
# which exists so that round can never report a pass it did not earn.
#
# Needs a working `ae` that can link a multi-module build. Fetches nothing.
#
# Usage:  ./container-emit-only.sh
# Exit:   0 all assertions pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AEB="$REPO_ROOT/aeb"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "[container-emit-only]"

if [ ! -x "$AEB" ]; then
    echo "  SKIP: no $AEB"
    exit 0
fi

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t aeb_container_emit)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Strip the compiler's warning frames so a diagnostic change upstream can't
# make an assertion here pass or fail for the wrong reason.
run_aeb() {   # run_aeb <dir> <target>
    ( cd "$1" && AEB_CONTAINER_EMIT_ONLY=1 "$AEB" "$2" ) > "$TMP/out" 2>&1
    echo "$?" > "$TMP/rc"
}

# --- round 1: the full-recipe path ------------------------------------------
# from()/run_step() flip image() into recipe mode (dockerfile_full_content).
# This is the shape itests/agent-container/.image.ae uses.
echo
echo "round 1: full-recipe image() writes its Dockerfile"
R1="$TMP/recipe"
mkdir -p "$R1"
cat > "$R1/.image.ae" <<'AE'
import bldr
import container
import container (from, arg, run_step, workdir, expose, entrypoint, tag)

aeb(cap) {
    bldr.build() {
        container.image() {
            from("debian:trixie-slim")
            arg("REF", "main")
            run_step("step-one")
            workdir("/opt/thing")
            run_step("step-two")
            expose("9440")
            entrypoint("[\"thing\"]")
            tag("emit-only-recipe")
        }
    }
}
AE

run_aeb "$R1" ".image.ae"
DF1="$(find "$R1/target" -name Dockerfile 2>/dev/null | head -1)"

if [ -n "$DF1" ]; then
    pass "a Dockerfile exists on disk"
else
    fail "NO Dockerfile was written (the original bug)"
    echo "        aeb exit was $(cat "$TMP/rc")"
fi

# The generated content, not just the file's existence: a mkdir that let an
# empty file through would satisfy the check above.
if [ -n "$DF1" ] && grep -q '^FROM debian:trixie-slim$' "$DF1" \
   && grep -q '^ARG REF=main$' "$DF1" \
   && grep -q '^EXPOSE 9440$' "$DF1"; then
    pass "recipe setters (from/arg/expose) reached the file"
else
    fail "generated Dockerfile is missing recipe lines"
    [ -n "$DF1" ] && sed 's/^/        /' "$DF1" | head -10
fi

# Ordering is load-bearing (a RUN must see the WORKDIR set before it), and
# it is the one property that survives only if the ordered recipe_steps
# record round-trips through the write.
if [ -n "$DF1" ] && \
   [ "$(grep -c . "$DF1")" -gt 0 ] && \
   printf '%s' "$(grep -E '^(RUN|WORKDIR) ' "$DF1")" \
     | tr '\n' '|' | grep -q '^RUN step-one|WORKDIR /opt/thing|RUN step-two$'; then
    pass "run/workdir/run render in call order"
else
    fail "ordered recipe steps did not survive to the file"
    [ -n "$DF1" ] && sed 's/^/        /' "$DF1" | head -10
fi

# --- round 2: the artifact-packaging path -----------------------------------
# No from()/run_step() — image() takes the FROM + WORKDIR + COPY default.
# A separate code path through the same write, so it needs its own round.
echo
echo "round 2: artifact-packaging image() writes its Dockerfile"
R2="$TMP/packaging"
mkdir -p "$R2"
cat > "$R2/.image.ae" <<'AE'
import bldr
import container
import container (base, workdir, tag)

aeb(cap) {
    bldr.build() {
        container.image() {
            base("alpine:3")
            workdir("/srv")
            tag("emit-only-packaging")
        }
    }
}
AE

run_aeb "$R2" ".image.ae"
DF2="$(find "$R2/target" -name Dockerfile 2>/dev/null | head -1)"

if [ -n "$DF2" ] && grep -q '^FROM alpine:3$' "$DF2" && grep -q '^WORKDIR /srv$' "$DF2"; then
    pass "artifact-packaging default reached the file"
else
    fail "artifact-packaging Dockerfile missing or wrong"
    [ -n "$DF2" ] && sed 's/^/        /' "$DF2" | head -10
fi

# --- round 3: an unwritable Dockerfile destination reddens ------------------
# The other direction. The discarded io.write_file return is why a failed
# write was invisible; now that it is checked, a write that cannot land must
# be a loud, attributed failure rather than a quiet 0.
#
# The destination has to be made unwritable AFTER a successful run, not
# before: aeb scaffolds target/_aeb/ for its own orchestrator, so clamping
# the whole of target/ up front fails aeb-main long before any builder body
# runs, and would assert nothing about container.image.
echo
echo "round 3: an unwritable Dockerfile destination reddens the build"
R3="$TMP/unwritable"
mkdir -p "$R3"
cp "$R2/.image.ae" "$R3/.image.ae"

run_aeb "$R3" ".image.ae"
DF3="$(find "$R3/target" -name Dockerfile 2>/dev/null | head -1)"
if [ -z "$DF3" ]; then
    fail "round 3 setup: the first (green) run wrote no Dockerfile"
else
    # Remove the file and clamp only its directory, so the builder's mkdirs
    # is a no-op on an existing dir and the create is what fails.
    DF3_DIR="$(dirname "$DF3")"
    rm -f "$DF3"
    chmod a-w "$DF3_DIR"

    run_aeb "$R3" ".image.ae"
    RC3="$(cat "$TMP/rc")"
    chmod u+w "$DF3_DIR"   # so the trap's rm -rf can clean up

    if [ "$RC3" != "0" ]; then
        pass "aeb exits non-zero when the Dockerfile cannot be written"
    else
        fail "unwritable Dockerfile reported success (exit 0)"
    fi

    if grep -q "could not write" "$TMP/out"; then
        pass "the failure names what could not be written"
    else
        fail "no diagnostic naming the unwritable file"
        sed 's/^/        /' "$TMP/out" | tail -10
    fi
fi

# --- result -----------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
    echo "[container-emit-only] OK"
    exit 0
fi
echo "[container-emit-only] $FAILURES assertion(s) failed"
exit 1
