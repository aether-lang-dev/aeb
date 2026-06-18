# Agent-driven container builds — the ladder

**To a developer, this is Remote Build Execution (RBE):** a thin client (a
Chromebook with no toolchains) names a target, the build runs *somewhere else*
on a box that has the right compiler, and the result comes back. That's the
experience we demonstrated — dispatch from the Chromebook, `result:pass`
returns, no toolchain ever installed locally.

The *contract* differs from hyperscale RBE, deliberately (see
[`aeb-vs-bazel.md`](aeb-vs-bazel.md)): aeb's executors are **sovereign, trusted,
lease-gated `aeb-agent`s**, not a fungible/untrusted worker pool, and dispatch
is **node-granular** (one `.build.ae` per request) rather than action-granular
(one compiler invocation). The distinguishing twist is the **per-job toolchain
container**: the image is chosen *per dispatch* from the build's declared
`prereq`s, not a single fixed worker image.

## Two RBE shapes — both supported

RBE covers two distinct "build remotely, report back" cases, and `aeb-agent`
does both. They differ in *where the source of truth lives* and *whether a
commit results*:

| | Shape 1 — **committed build** | Shape 2 — **patch-on-base** |
|---|---|---|
| Dispatch carries | `ref` + `hash` (or `mode:advance` + `branch`) | `ref`/`hash` (the BASE) + `patch_b64` (the delta) |
| Mode | `advance` (track a branch HEAD) / `autoclone` (clone repo#branch fresh) | `patch` |
| Source of truth | **git** — a real commit anyone can clone | **the dispatch** — the patch is never committed |
| Use case | CI: "build commit `abc123` / branch HEAD" | dev pre-integration: "build my dirty tree on `main`, is it green?" |
| Result | the built artifacts / verdict | the verdict — **no commit, no trace left** |

Shape 2 is aeb's headline case (the operating doc's "lease a machine to build
*this*, no commit as a result"): build an uncommitted patch on a pinned base, on
a real toolchain box, and report green/red — leaving nothing behind. Hyperscale
RBE is almost entirely Shape 1; aeb does Shape 1 too but leads with Shape 2. The
field present is the tell: `ref`+`hash` alone → Shape 1; add `patch_b64` →
Shape 2. (See [`agent-provisioning-modes.md`](agent-provisioning-modes.md) for
the `patch`/`advance`/`autoclone` lifecycle axis.)

Running status of the initiative: **one root-level `aeb-agent` on an immutable
host that, per HTTP dispatch, summons a per-job toolchain container, builds one
node of a (polyglot) repo in it, and drops the container.** The proving ground
is [`../../google-monorepo-sim`](https://github.com/paul-hammant/google-monorepo-sim)
(rust / go / jdk / kotlin nodes, cross-language `dep()` edges) on the bazzite
box (192.168.0.57, podman, immutable).

This doc is the *climb* — what's green, what's next. The *problems* found and
fixed along the way live in `asks/` (linked below). Update this as rungs land.

## The rungs

| # | Rung | What it proves | Status |
|---|------|----------------|--------|
| 0 | Raw `podman run` (hand-driven) | the layered toolchain image compiles the source | ✅ done |
| 1 | Real `aeb` in-container | `aeb <target>` in the image assembles the dep closure → artifact | ✅ green |
| 2 | Agent over HTTP (`run_on=podman`) | the **agent** drives the per-job container: auth → scope → veto → image-override → build | ✅ **green** |
| 3 | Requester token→image loop | `aeb --prereqs <target>` → map each token to its image → dispatch per node | ✅ **GREEN (build passes)** — `prereq rust:1.75 → image aeb-tc:rust-1.75` → lease → dispatch → veto-pass → build in-container → `remote build PASSED` rc=0 (2026-06-16) |
| 4 | Multi-image cross-language pipeline | rust `.so` → (artifact threaded) → jdk node compiles against it, each in its own image | ✅ **GREEN** — `AEB_NODE_CONTAINER=1` (aeb-driver) routes each node to its own prereq-image: rust node built `libvowelbase.so` in `aeb-tc:rust-1.75` (cargo), jdk node built `VowelBase.class` in `aeb-tc:jdk-21` (javac) linking the `.so` threaded via the `/work` mount — all rc=0 (2026-06-18). Required refreshing the jdk image to a current ae (0.281) base. |
| 5 | 4-toolchain capstone | `directed_graph_build_systems_are_cool` (jdk+kotlin+go+rust) driven entirely from `--prereqs` | ◻ |

## What's proven (Rungs 0–2)

- **Layering.** One base `aeb-toolchain` (debian + Aether + aeb) → thin
  `FROM`-base sibling images, one toolchain each: `aeb-tc:rust-1.75`,
  `aeb-tc:go-1.22`, `aeb-tc:jdk-21`. Each node stays single-toolchain; the dep
  DAG partitions the work (NO fat multi-toolchain image needed). `aeb --prereqs`
  is transitive + complete — a top-level app surfaces its whole 4-toolchain set.
- **The product path (Rung 2, green 2026-06-15).** A real `POST /dispatch`
  (lease token + `image:"aeb-tc:rust-1.75"`) to `aeb-agent --run-on podman
  --all-in-container` walked: `ACCEPT → image-override aeb-tc:rust-1.75 →
  all-in-container build → DONE result=pass`, producing `libvowelbase.so`
  (4.4 MB) with the `Java_components_vowelbase_VowelBase_printString` JNI symbol
  (so the vendored `jni` dep merged + linked). The host has no rust toolchain —
  it all happens in the ephemeral `--rm` container.

## Per-node container routing (Rung 4, green 2026-06-18)

`AEB_NODE_CONTAINER=1` makes `aeb-driver` (the per-node-subprocess runner) build
**each node in the toolchain image its OWN `prereq` selects** — not one image for
the whole flattened target. A cross-language DAG then spans multiple images:

- For each node, `extract-deps --prereqs <node>` gives that node's own prereq
  token → `agent.prereq_to_image` → its image (`rust:1.75` → `aeb-tc:rust-1.75`).
- The node's Makefile recipe becomes, in that image (root bind-mounted at
  `/work`): `aeb --noexe <node>` (link the in-image orchestrator) `&&`
  `_ae_build_all /work <label>` (run **only this node** via the orchestrator's
  per-node label selector — so deps, whose labels don't match, are NOT
  recompiled in the wrong image).
- Sibling artifacts thread through the shared `/work` mount: the rust node's
  `.so` is on disk when the jdk node's `javac` links it.

Two non-obvious constraints this design encodes (both verified):
- **Glibc.** The host-linked `_ae_build_all` won't run in an image with a
  different glibc (host 2.42 vs image 2.36 → `GLIBC_2.42 not found`), so each node
  builds with the IMAGE's own aeb/toolchain, not the host orchestrator binary.
- **Single-node, not closure.** `aeb <node>` would rebuild the node's deps in
  THIS image (a rust dep cargo-building in the jdk image → `cargo: not found`).
  The `--noexe` + label-selector two-step builds exactly one node.

Proven on `google-monorepo-sim`: `aeb java/components/vowelbase` with
`AEB_NODE_CONTAINER=1` → rust node `libvowelbase.so` in `aeb-tc:rust-1.75`
(cargo), jdk node `VowelBase.class` in `aeb-tc:jdk-21` (javac) linking that `.so`,
all rc=0. Zero SDK changes — the wrap is at the node-subprocess boundary.

This is the BUILD-layer form (works with plain `aeb`, no agent). The agent's
`--all-in-container` (one image for the whole build) stays the right choice for a
single-language dispatch; per-node routing is for cross-language DAGs.

## The hop chain (Rung 2, today)

```
💻 dev box ──ssh──► 🐧 bazzite host ──(on-box)──► curl POST 127.0.0.1:9440/dispatch
                                                  └► aeb-agent (host pid, loopback)
                                                       └► podman run --rm <per-job image>
                                                            └► aeb <target>  (in container)
                                                                 └► cargo / javac / …  ◄ the build
```

The agent listens on the **host's loopback** (`127.0.0.1:9440`) — a plain host
process, not containerized — and spawns containers via podman. Loopback-only is
the safe default (reachable only from inside bazzite, i.e. via ssh). To dispatch
straight from the dev box, start with `--host 0.0.0.0 --allow-from <dev-ip>`
(source-IP gate restores the access control loopback gave for free).

## Blockers found & resolved (the asks)

- [`toolchain-image-aether-version-floor`](../asks/toolchain-image-aether-version-floor.md)
  — toolchain base must carry Aether ≥ aeb's floor (≥0.231 for `os.run_supervised`).
  Unblocked by building a fresh `debian:12` base via Aether/aeb's own installers.
- [`rust-vendored-crate-dep-not-merged-into-cargo-toml`](../asks/rust-vendored-crate-dep-not-merged-into-cargo-toml.md)
  — **RESOLVED** (`54d6b56`): a clean build dropped the vendored `jni` path-dep;
  fixed `_read_dep_artifact` with a cross-buildtype fallback. The container's
  clean build exposed what a stale local `target/` had masked.
- [`run-on-podman-all-in-container-mode-for-pure-compile-toolchains`](../asks/run-on-podman-all-in-container-mode-for-pure-compile-toolchains.md)
  — **RESOLVED** (`cd92fe9`): the compile-in-container/execute-on-host duality
  ran `cargo` on the toolchain-less host. Added `--all-in-container` (one
  `podman run` for the whole build). This made Rung 2 green.

## Known follow-ups

- **All-in-container doesn't thread the artifact manifest back.** The `.so` is
  built (verified on disk) but the verdict's `artifacts[]` array is empty over
  the wire — that list is populated phase-2/host-side. Minor; revisit if the
  requester (Rung 3) needs the manifest in the reply.
- **Veto scope — FIXED (pragmatic), perfectionist TODO open.** A stray
  `binding.gyp` (ffi-napi) in the workdir used to veto an unrelated rust build
  (whole-workdir scan). Fixed 2026-06-16 (`9a7ae92`): tree/file-scope rules now
  scan the target's CONTAINING DIRECTORY subtree (`_veto_scan_root`), not the
  whole worktree — this is what made Rung 3 build-green. TODO(perfectionist)
  left in code: replace the subtree heuristic with the exact transitive `.ae`
  dep closure (extract-deps BFS), which also catches deps OUTSIDE the target's
  dir. See `lib/agent` `_veto_scan_root` + `docs/build-veto-and-sandbox.md`.
- **Image GC.** Per-job `--rm` drops containers; nothing prunes images. A
  long-lived agent needs an image-GC policy (prune dangling after compose, LRU
  cap).
- **Toolchain-base Aether floor isn't asserted up front** — a too-old base fails
  cryptically. aeb should expose its min Aether and the image build assert it.

## Pointers

- Agent: [`../tools/aeb-agent.ae`](../tools/aeb-agent.ae); operating guide
  [`aeb-agent-operating.md`](aeb-agent-operating.md); the duality
  [`two-aeb-duality.md`](two-aeb-duality.md).
- Per-job image vision: see the `per-job-agent-image` factpack.
- Toolchain base recipe: [`../tools/container/Containerfile.aeb-toolchain`](../tools/container/Containerfile.aeb-toolchain).
