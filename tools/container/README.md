# tools/container — aeb in a container, for immutable hosts

`aeb` needs a toolchain (gcc + Aether's aetherc) that an immutable host
(Bazzite / Silverblue / Fedora-atomic) won't let you install. The fix is to
run aeb *inside* a container that has the toolchain, with your sources
bind-mounted. See `docs/containment-and-the-control-plane.md` for the why.

## The layering

```
aether-builder:slim     (UPSTREAM: aether/tools/docker/aether-build)
   debian-slim + gcc + Aether (ae/aetherc) + host headers.  Has ae, NOT aeb.
        │  FROM
        ▼
aeb-toolchain:slim      (HERE: Containerfile.aeb-toolchain)
   + clones aeb, drops itests/ (~225 MB), make install → aeb on PATH.
```

The base is what `aether-build` bootstraps. It deliberately omits aeb (its
`--aeb` mode aborts with "aeb not installed in this image"). This layer adds
aeb so `--aeb` works.

## Build + use (on a podman host)

```sh
# 1. bootstrap the base once (clones+builds Aether — ~5 min):
aether-build hello.ae          # produces aether-builder:slim as a side effect

# 2. build the aeb layer on top:
podman build -t aeb-toolchain:slim \
    -f tools/container/Containerfile.aeb-toolchain tools/container

# 3. run aeb in-container against bind-mounted sources. On SELinux hosts
#    (Bazzite) the mounts need :Z, and the work dir must NOT be $HOME
#    (relabeling $HOME is refused). Use a dedicated dir:
podman run --rm \
    -v "$PWD/myproj:/work:Z" \
    -v "$PWD/out:/out:Z" \
    aeb-toolchain:slim --aeb app/.build.ae
```

(Bazzite caveat: do NOT use `--userns=keep-id` — it crashes this crun with
`crun: readlink \`\`: No such file or directory`; output is correctly
user-owned without it. Both this and the `:Z`/`$HOME` traps are documented
upstream in `../aether/ctr_notes.md`.)

## Readiness probes

The `readiness/` tree in the hosted-language-headers repo has two smoke
tests this image should pass:
- `hello.ae` — bare Aether (`ae build` → `aether-ready`).
- `aebproj/` — a pure-Aether multi-target aeb DAG (`aeb app/.build.ae` →
  `hello-from-greeter`). No cross-language deps, so an Aether-only image
  suffices. Run these after building the image to confirm aeb works
  in-container before trusting it with real builds.

## What this is for

Letting an immutable control plane (e.g. the bazzite NUC) compile the
Aether-toolchain-satisfiable targets of a polyglot DAG — drop the artifacts
to the host via the mount, inspect them — without installing anything on the
host. Targets needing other toolchains (rust/go/java/.NET/node) are NOT
buildable in this Aether-only image; fattening it to cover more languages is
a separate, larger decision (see the goal discussion in the aeb session log).
