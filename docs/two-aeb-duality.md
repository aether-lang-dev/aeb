# The two-aeb duality — host-aeb orchestrates, container-aeb compiles

> **VALIDATION UPDATE (2026-06-02, on the real Bazzite NUC).** Two premises
> tested; one held, one revealed the split is at the WRONG layer. Read
> "Validation findings" at the bottom before building further — it changes
> where the container boundary goes. The per-capability table below is still
> the right *intent*; the *mechanism* (where exactly host hands off to
> container) is corrected there.

Status: **design / proposal.** A new execution model for immutable hosts
(Bazzite / Silverblue / CoreOS): run aeb as **two cooperating instances of
the same binary** — a host-side aeb that orchestrates and does host-native
work, delegating only the toolchain-needing steps (compile) to a container-
side aeb. Builds on what's already proven this session: the `aeb-toolchain`
container image (`tools/container/`), `aether-build` as the bootstrap, and
the readiness DAG running `--aeb` in-container. Read after
`docs/containment-and-the-control-plane.md` (the why) and
`tools/container/README.md` (the image).

## The problem this solves

`aether-build --aeb` runs the **whole** build inside one container. That
works (proven on the NUC), but it's coarse:

- **Tests/execution run in the toolchain container** — which deliberately
  lacks host-language *runtimes* (libpython, libruby, …). A test binary that
  dlopens libpython compiles fine but can't *run* there. Execution belongs on
  the host.
- **podman is not available inside the toolchain container** — so aeb-in-
  container can't drive `container.run` / `podman build` (the dogfood loop —
  aeb building its own agent image — is blocked).
- **No host-side orchestration** — the DAG walk, mtime-incremental decision,
  and telemetry all happen in-container, even though none of them need a
  toolchain.

The fix is to split aeb's capabilities by *where they belong*, not run them
all in one place.

## The model: one binary, two instances, a per-capability split

```
Bazzite host (immutable, podman, NO toolchain)
  ┌─ host-aeb  (/usr/bin/aeb — copied OUT of the container image) ───────────┐
  │  orchestrates the DAG; does HOST-NATIVE capabilities directly;           │
  │  DELEGATES toolchain capabilities to container-aeb via podman.           │
  │                                                                           │
  │     compile node X  ──delegate──▶  podman run aeb-toolchain:slim         │
  │                                       └─ container-aeb compiles X ────────┼──▶ artifact + cache marker
  │     run test / execute / podman / DAG / mtime-incremental  ── done here ──┘   (to host via mount)
  └───────────────────────────────────────────────────────────────────────────┘
```

**There is one aeb codebase.** It deploys as two instances:
- **container-aeb** — the aeb baked into `aeb-toolchain:slim` (already built).
  The toolchain worker.
- **host-aeb** — the *same binaries*, **copied out** of that image to the
  host (`/usr/bin/aeb` or similar). No separate build: aeb's tools are
  relocatable linux-x86-64 ELF linking only libc, so extraction = deployment.
  The orchestrator.

The host-aeb never invokes a compiler. The container-aeb never drives podman
or runs host-targeted tests. Each does only its side.

## The per-capability split (the heart of it)

Every aeb capability is classified **container-side** (needs the toolchain)
or **host-side** (needs the host: runtimes, podman, or is pure logic):

| Capability                          | Side       | Why                                                        |
|-------------------------------------|------------|------------------------------------------------------------|
| compile `.ae`→C→bin (aetherc, gcc)  | container  | needs the toolchain the host lacks                         |
| javac / kotlinc / cargo / tsc / …   | container  | (when that SDK's toolchain is in the image)                |
| scan tree / build DAG / topo-sort   | host       | pure logic, no toolchain                                   |
| mtime-incremental staleness check   | host       | reads source + marker mtimes; the split's timestamp seam   |
| run tests / execute produced binary | **host**   | the binary needs host runtimes (python/ruby/…) the image omits |
| `container.run` / `container.image` | **host**   | host has podman; the toolchain container does NOT          |
| the aeb-agent (listen/dispatch)     | host       | long-lived host service                                    |
| telemetry / summary render          | host       | reads on-disk markers; no toolchain                        |

The split is **declared, not hardcoded** — see "DSL-with-scope" below. The
table above is the sensible default for an Aether-only toolchain image;
fattening the image (add rustc etc.) moves more rows to container-side.

## Why the bootstrap is trivial

host-aeb is **copied out of the container**, so there is no chicken-and-egg
and no second compile:

```
build aeb-toolchain:slim once (already done) → it contains a built aeb →
podman cp / extract aeb's binaries (trampoline + tools/ + lib/) to the host →
/usr/bin/aeb on Bazzite, runs natively (libc-only ELF).
```

The host can't *compile* aeb, but it can *run* an aeb that was compiled in the
container. That's the whole trick — same as a user's compiled binary running
on the host after an in-container build.

## The compile-delegation protocol (the boundary contract)

When host-aeb hits a compile node, it ships that node to container-aeb. The
contract:

- **Crosses INTO the container:** the node's source dir (bind-mounted
  read-only) + the build flags/label + the target output dir (bind-mounted
  writable). Reuses `aether-build`'s mount mechanics (`:Z` on SELinux, no
  `--userns=keep-id` on Bazzite-crun, work dir not `$HOME` — all proven).
- **Comes back OUT:** the compiled artifact under `target/<buildtype>/<dir>/`
  AND the cache marker (`.aeb_cache`, mtimes intact — the bind mount is the
  same filesystem, so host-side mtime-incremental stays valid across runs).
- **Failure:** if the node's SDK toolchain isn't in the image, the in-
  container compile fails (`rustc not found`); container-aeb reports that node
  failed; host-aeb folds it as a normal per-target failure and continues.
  Honest partial build — exactly the polyglot-DAG-on-an-Aether-only-image
  reality.

Path mapping (host `target/...` ↔ container `/work`,`/out`) is mechanical and
already solved in `aether-build`'s entrypoint; this formalizes it as aeb's
internal compile-delegation rather than a user-facing `--aeb` wrapper.

## DSL-with-scope: declaring the split

Which capabilities containerize, and with which image, is **declared in the
build config's scope**, not hardcoded — the same closure-with-scope idiom aeb
uses elsewhere. Sketch (illustrative, not final grammar):

```
# the split is a property of the RUN CONTEXT, not the target:
#   compile → container image aeb-toolchain:slim
#   test/execute/podman → host
# A target that needs a toolchain absent from the image fails gracefully.
```

This keeps the duality configurable: a normal (mutable) host declares
nothing → everything runs locally as today; an immutable host declares the
compile→container delegation. The target files (`.build.ae` etc.) are
unchanged — the split lives in the context/scope, mirroring how
policy-class/grant separates the request from its environment
(`docs/run-policy-class-and-cloud-leverage.md`).

## What this unblocks

- **Tests run on the host** with their real runtimes — compile-in-container,
  run-on-host, the split forced by the runtime-library reality.
- **podman orchestration is host-side** → the dogfood loop works: host-aeb
  can `container.image` / `podman build` aeb's own agent image on the control
  plane (no podman-in-podman).
- **Incremental across runs** — host-side mtime check is instant; only stale
  nodes pay the container dispatch. Fresh nodes skip it entirely.
- **Host stays the orchestrator** — DAG, telemetry, decision logic where no
  toolchain is needed; the container is a pure per-node compile worker.

## Honest hard parts (not blockers — the real work)

1. **The boundary protocol must be exact** — host↔container path mapping,
   mtime preservation, what crosses each way per compile node. The mechanics
   exist (`aether-build`); formalizing them inside aeb is the work.
2. **Per-capability classification must be explicit and complete** — every
   SDK builder and every aeb subcommand gets a side. Miss one and it either
   runs where it can't (compile on host → fails) or where it shouldn't (test
   in container → no runtime).
3. **Two instances, one version** — host-aeb and container-aeb must be the
   same build (copied out), or label/path/cache contracts drift. The
   copy-out-of-the-image bootstrap enforces this naturally; a manual host
   install could skew.
4. **Dispatch cost** — a podman invocation per compile node is heavier than a
   local `gcc`. mtime-incremental (only stale nodes dispatched) is what keeps
   it tolerable; without it, every node paying container startup is slow.

## The one-line summary

One aeb, deployed twice: **host-aeb orchestrates the DAG and does everything
host-native (run tests, execute, drive podman); container-aeb does the
toolchain-needing compiles; the split is per-capability, declared in the
run scope, and bootstrapped by copying aeb out of the toolchain image.** It
turns "the whole build runs in one container" into "the host orchestrates,
the container compiles" — which is what an immutable control plane actually
wants.

---

## Validation findings (2026-06-02, on the real Bazzite NUC)

Tested two load-bearing premises by extracting host-aeb from the toolchain
image (`podman cp`) onto the bare immutable box and running it.

### ✅ Premise 1 (HELD): host-aeb orchestrates toolchain-free

`host-aeb --version` and `host-aeb --graph` both work on the bare host with
NO `ae`/`aetherc`/`gcc` present (`which ae` → nothing). `--graph` correctly
emitted the readiness DAG (`app -> greeter`). So the *orchestration* layer —
scan, DAG, topo-sort, telemetry, the mtime decision — genuinely needs no
toolchain. The copy-out bootstrap works; libc-only ELF runs natively. This
half of the model is sound and proven.

### ❌ Premise 2 (BROKE — and it relocates the boundary): a real build needs the toolchain to compile aeb's OWN orchestrator

`host-aeb app/.build.ae` (a real build) FAILED — `dirname: missing operand`,
then `aeb-link` usage error. Root cause (tools/aeb-main.ae ~753):

```
aether_dir_cmd = "dirname $(command -v ae)"   # ae not on host → empty
aether_dir = run_capture(...)                  # → ""
# "" passed to aeb-link as <aether-dir> → arg-shift → aeb-link too few args
```

But the empty `aether_dir` is the *symptom*. The real finding is **why**
aeb-link needs it: aeb's core mechanism (LLM.md) is that **aeb-link compiles
the `.build.ae` files into ONE native orchestrator binary (`_ae_build_all`),
linking it with a LOCAL `gcc` + `libaether.a`, then runs it** — and that run
is what does the per-target compiles. So the toolchain is needed at TWO
layers, and the deeper one runs FIRST:

```
host-aeb
  └─ aeb-link: compile+link _ae_build_all   ← needs gcc + libaether.a  (LAYER 1, FIRST)
        └─ run _ae_build_all
              └─ per-target compile (ae build greeter.ae)  ← the AEB_COMPILE_CONTAINER seam (LAYER 2)
```

The `lib/aether` `AEB_COMPILE_CONTAINER` seam (commit 3410686) correctly
delegates **Layer 2** — and it's well-tested and right *for that layer*. But
host-aeb dies at **Layer 1**: it can't build its own orchestrator binary
without a local toolchain, so it never reaches Layer 2. This is why `--graph`
worked (pure scan, never builds `_ae_build_all`) but a real build didn't.

**Consequence for the model:** the container boundary is NOT at the
`lib/aether` compile shell-out. It's higher — at **aeb-link's orchestrator
compile+link** (and everything downstream of it, including the per-target
compiles, runs in the same container). The Layer-2 seam is necessary but
INSUFFICIENT; delegating only it leaves Layer 1 stranded on a toolchain-less
host.

### What this means — the corrected split

The clean boundary is: **host-aeb does scan + DAG + mtime-decide (no
toolchain), then hands the ENTIRE compile-and-run phase — aeb-link onward —
to the container.** That is, functionally, very close to what
`aether-build --aeb` ALREADY does (run the whole build, orchestrator + all
compiles, in-container — proven working on this NUC). So the realistic
duality is:

- **host-aeb:** scan, DAG, telemetry, the mtime-incremental decision of
  *which targets are stale*, and the host-only capabilities (run tests,
  execute artifacts, drive podman / the agent).
- **container:** the stale-target *build* — aeb-link + `_ae_build_all` +
  per-target compiles — i.e. `aether-build --aeb` (or an equivalent
  `aeb-link`-in-container invocation), scoped to just the stale subgraph.

The per-capability table above stays correct in spirit; the correction is
that "compile" is not a single shell-out to wrap — it's the whole
aeb-link→orchestrator→per-target phase, and the boundary is drawn there.

### Options to decide next (not yet chosen)

1. **Lean on `aether-build --aeb` as the compile side.** host-aeb decides
   stale targets, then dispatches the build of just those into the container
   via `aether-build --aeb` (proven). Least new code; the lib/aether seam
   becomes redundant (or stays as the inner mechanism `aether-build --aeb`'s
   in-container aeb uses — harmless either way).
2. **Containerize aeb-link's orchestrator link** so a host-side aeb-link
   builds `_ae_build_all` in the container. More surgical, keeps host-aeb
   "driving," but re-implements much of what `aether-build --aeb` does.
3. **Make host-aeb's aeb-link toolchain-agnostic when delegating** — skip the
   local `aether_dir` resolution and route the orchestrator compile to the
   container. Same destination as (2), framed as a fix to the empty-aether_dir
   symptom.

The lib/aether seam (commit 3410686) is kept — correct for Layer 2, tested,
and it's the mechanism whichever option wins. This section records that the
*boundary* is at aeb-link, decided next.
