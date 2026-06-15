# Agent-driven container builds — the ladder

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
| 3 | Requester token→image loop | `aeb --prereqs <target>` → map each token to its image → dispatch per node | ◻ next |
| 4 | Multi-image cross-language pipeline | rust `.so` → (artifact threaded) → jdk node compiles against it, each in its own image | ◻ |
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
- **Veto is whole-workdir-scoped, not dep-closure-scoped.** A stray
  `binding.gyp` (ffi-napi) in the workdir vetoed an unrelated rust build. Worth
  scoping the Tier-A scan to the target's dep closure.
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
