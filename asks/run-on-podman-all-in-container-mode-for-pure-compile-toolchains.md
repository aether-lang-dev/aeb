# run_on=podman needs an all-in-container mode for pure-compile toolchains (rust/go/...)

> **STATUS: RESOLVED** (commit cd92fe9, 2026-06-14/15). Added `--all-in-container`
> to aeb-agent: when set, run_on=podman does ONE `podman run --rm <image> aeb
> <target>` (whole build in the per-job image) instead of the phase split. The
> duality stays default. Proven GREEN end-to-end: a real HTTP dispatch to
> `aeb-agent --run-on podman --all-in-container --ctr-image aeb-tc:rust-1.75`
> for the rust node returned `status:done result:pass`, with libvowelbase.so
> (4.4MB) carrying the Java_components_vowelbase_VowelBase_printString JNI symbol
> (jni dep merged+linked). Agent trace: ACCEPT → image-override aeb-tc:rust-1.75
> → all-in-container build → DONE result=pass. Option 1 from below was taken.

**Filed by**: aeb Claude, 2026-06-14, Rung 2 of the agent-driven-container ladder
— a real HTTP dispatch to `aeb-agent --run-on podman` for google-monorepo-sim's
rust node, image `aeb-tc:rust-1.75`, on bazzite.

**Severity**: blocking for agent-driven builds of any node whose toolchain is
ONLY in the container (rust cargo, go, ...). The agent accepts, applies the
per-job image, runs phase 1 — then fails the node's compile on the host.

## What works (proven this session)

The dispatch lifecycle is GREEN up to the build: auth (lease) → scope → prep
(git tree) → veto → **per-job image override applied** (`aeb-tc:rust-1.75`) →
`run_on=podman phase 1 compile-only in aeb-tc:rust-1.75`. The dep-merge fix
(54d6b56) works in-agent too (generated Cargo.toml carries the jni path-dep).

## The failure

```
agent: run_on=podman — phase 1 compile-only in aeb-tc:rust-1.75   (OK)
...
rust/components/vowelbase: compiling prod code (cargo build)
sh: line 1: cargo: command not found
rust/components/vowelbase: cargo build failed
agent: DONE guid=... result=fail (rc=1)
```

## Root cause — the two-phase duality doesn't cover cargo

run_on=podman runs the compile-in-container/execute-on-host duality
(docs/two-aeb-duality.md), as wired in tools/aeb-agent.ae ~1206-1241:

- **Phase 1 (IN container):** `aeb --compile-only <target>` compiles the Aether
  ORCHESTRATOR (`target/_ae_build_all`). Works.
- **Phase 2 (ON host):** run the orchestrator with `AEB_EXECUTE_ONLY=1` — it
  executes the per-node build steps on the host, delegating per-node
  *compilation* back into the container via the AEB_COMPILE_CONTAINER seam.

But rust's `cargo build` (lib/rust/module.ae ~1192, `build._sh(cargo_cmd)`) is a
per-node COMPILE step that runs as a plain HOST `_sh` — it does NOT go through
the AEB_COMPILE_CONTAINER seam. So on a toolchain-less host (the whole point of
run_on=podman) cargo isn't found. The agent's own comment (line ~1211) already
notes "the per-node AEB_COMPILE_CONTAINER seam alone is NOT enough"; this is a
concrete case where it's not enough for the SDK's native compiler either.

## What's wanted

An **all-in-container run mode** for run_on=podman: when the toolchain lives
only in the image, run the WHOLE build (orchestrator + every node step incl.
cargo/go/javac) inside one `podman run` of the per-job image, rather than
splitting compile-in-container / execute-on-host. The duality is right when the
host HAS runtimes to execute against (host-Python etc.); but for a pure-compile
artifact (a rust cdylib) produced by a container-only toolchain, the host need
not — and cannot — run any node step.

Shape options:
1. **`--run-on podman --all-in-container`** (or a per-dispatch field): the agent
   does `podman run --rm <image> aeb <target>` (full build), bind-mounts the
   tree, collects artifacts via the mount. (This is exactly what Rung 1 proved
   by hand — `aeb <target>` in the rust container produced libvowelbase.so.)
2. Route the SDK's native compiler (`cargo`/`go`/`javac`) through
   AEB_COMPILE_CONTAINER too, so phase 2 on the host delegates THOSE into the
   container like it does aetherc. More surface; only worth it if host-side
   execution of OTHER nodes in the same build is needed.

Option 1 is the clean fit for the per-job-image vision (one image per node,
whole node built in it) and matches what already works by hand.

## Acceptance

A dispatch to `aeb-agent --run-on podman` for the rust node (image
aeb-tc:rust-1.75) returns result=pass with libvowelbase.so in the artifacts —
the agent having built it entirely in the container, no host cargo.

## Cross-ref

- memory `layered-temp-containers-on-aeb-base` (the ladder; Rung 1 proved the
  hand-run all-in-container build)
- memory `per-job-agent-image` (lists "no all-in-container mode" as a known gap)
- docs/two-aeb-duality.md, tools/aeb-agent.ae ~1206-1241, lib/rust/module.ae ~1192
