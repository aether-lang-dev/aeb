# Directions — where aeb can grow, and the line it won't cross

A synthesis doc. The comparison docs (`aeb-vs-*.md`) each measure aeb
against one neighbour; the design docs (`agent-lifecycle.md`,
`run-policy-class-and-cloud-leverage.md`, `nodes-as-subprocesses.md`,
`distributed-cache-plan.md`, `lifecycle_plan.md`,
`toolchain-selection-and-locks.md`, `containment-and-the-control-plane.md`)
each spec one capability. This doc steps back and asks: **across all of
them, which directions are real, how do they relate, and what is the one
invariant none of them may break?**

Read the invariant first. It is the lens for everything below.

## 0. The invariant — the single-process, single-threaded, no-container build is sacred

aeb will **never abandon the option to run a build as one single-threaded,
non-container process that orchestrates the build directly.** Every
scaling direction in this doc — parallel nodes, nodes-as-subprocesses,
containerized steps, a remote agent grid, a persistent controller — is
**additive and opt-in**, layered *over* a core that still works as a lone
process on a bare host with nothing but a toolchain on `PATH`.

This is not nostalgia or a fallback. It is the load-bearing property:

- **It's the bootstrap floor.** `aeb` must build itself, and any project,
  on a fresh machine with no daemon, no container runtime, no k8s, no
  agent — just `ae` and a compiler. The duality work (compile-in-
  container / execute-on-host) and the whole host-language story
  (`guest-languages.md`) depend on this floor existing.
- **It's the debuggability floor.** A single process in topo order is the
  mode you can `strace`, step through, and reason about with no
  scheduler, no IPC, no container namespace in the way. Every richer mode
  is a performance/isolation layer that must degrade *cleanly back to
  this* when its substrate is absent (`AEB_JOBS=1`, no `make`, no podman).
- **It's already how degradation works.** `tools/aeb-driver.ae` runs
  `make -jN` by default but **falls back to a sequential in-process loop**
  when `make` is missing or `AEB_JOBS=1`. `container.run` is *a builder
  you choose*, not a mode the runtime imposes — `guest-languages.md` is
  explicit that a container is "a separate process … not a limitation to
  fix," and the in-process path is a peer, not a lesser option.

**Corollary — the direction we lean *into*, not away from: steps as
library invocations in one process.** The richest CI tools push the other
way (every step its own container; see §3). aeb keeps the *opposite* pole
open and may push *further* down it: a build where steps are **library
calls inside one process**, not shell-outs and not containers. The
precedent already exists two ways —

1. **in-process guest hosting** (`contrib.host.<lang>`): Lua/Python/Perl/
   Ruby/Tcl/JS linked into the aeb binary and run in its address space,
   no subprocess (`guest-languages.md` Way 2); and
2. **`--emit=lib` binary-import SDKs** (LLM.md, aether `[current]`): an
   SDK compiled to a `.so` and `import`ed, its builder grammar
   reconstructed at full fidelity — a *step that is a linked library
   entry point*, not an `os.system`.

The end of that road is an aeb build that, for the steps that allow it,
never forks at all: the orchestrator calls into linked builders directly.
That is a *first-class direction*, co-equal with the containerize-
everything direction, not a legacy mode. **Any feature that would make
the single-process / library-call build impossible or second-class is
out of scope, by definition.**

## 1. The shape of the directions — three concentric rings

Everything aeb might grow sorts into three rings around that core. The
ring tells you how far from the invariant a direction sits and therefore
how cautiously it's taken.

```
        ┌─────────────────────────────────────────────┐
        │ Ring C — distributed / as-CI (opt-in, heavy) │
        │   agent grid · persistent controller ·       │
        │   remote cache · inbound triggers            │
        │  ┌────────────────────────────────────────┐  │
        │  │ Ring B — multi-process on one host       │  │
        │  │   make -jN nodes · nodes-as-subprocess · │  │
        │  │   containerized steps · per-step reap    │  │
        │  │  ┌───────────────────────────────────┐   │  │
        │  │  │ Ring A — THE CORE (the invariant) │   │  │
        │  │  │  one process, topo order,         │   │  │
        │  │  │  steps as fn calls / shell-outs / │   │  │
        │  │  │  library invocations; no daemon,  │   │  │
        │  │  │  no container required            │   │  │
        │  │  └───────────────────────────────────┘   │  │
        │  └────────────────────────────────────────┘  │
        └─────────────────────────────────────────────┘
   every outer ring DEGRADES CLEANLY to the one inside it.
```

- **Ring A — the core (the invariant).** One process, topo order. Steps
  are function calls, shell-outs, or (the direction we lean into) library
  invocations. Always works; everything else degrades back to it.
- **Ring B — multi-process on one host.** `make -jN` parallel nodes
  (shipped), nodes-as-subprocesses (shipped — `aeb-driver.ae`),
  containerized steps via `container.run`/`container.service` (`container-
  lifecycle.md`), per-step reaping + `timeout { … }` (design,
  `lifecycle_plan.md` §9, now unblocked by the subprocess driver). Opt-in
  isolation/throughput; absent its substrate, falls back to Ring A.
- **Ring C — distributed / as-CI.** The sovereign agent grid
  (`agent-lifecycle.md`, `run-policy-class-and-cloud-leverage.md`), a
  persistent controller, remote cache (`distributed-cache-plan.md`),
  inbound triggers — the "aeb becomes the CI" frontier
  (`aeb-vs-jenkins.md`). Heaviest, most opt-in; a single `aeb` invocation
  on a laptop must never need any of it.

## 2. What to take from the build-system neighbours (Bazel, Nix, moon)

From the comparison docs, the *scope-respecting* borrows — each lands in a
ring without threatening the invariant:

- **From Bazel ([`aeb-vs-bazel.md`](aeb-vs-bazel.md)):** `aeb query` /
  `rdeps` (Ring A — read-only, the graph already exists in-process);
  remote cache (Ring C, as *repeatability* not RBE-reproducibility);
  finer cache-into-skip wiring (Ring A). **Decline:** mandatory sandbox,
  hermetic-toolchain provisioning, `select()`, the full macro language —
  all either Ring-C-heavy or invariant-threatening (a mandatory sandbox
  is the opposite of "runs as a lone process on a bare host").
- **From Nix ([`aeb-vs-nix.md`](aeb-vs-nix.md)):** toolchain
  *selection* + self-validating locks (Ring A/B,
  `toolchain-selection-and-locks.md`) — the selection slice of
  hermeticity. **Decline:** the store and toolchain *materialization* —
  owning the closure is fundamentally at odds with "use what's on PATH in
  one process."
- **From moon ([`aeb-vs-moon-moonbit.md`](aeb-vs-moon-moonbit.md)):** the
  n2-style content-hash dirty model could improve Ring B's dirty
  detection. **Decline:** compilation-unit granularity — that needs
  compiler coupling aeb deliberately lacks; aeb's grain is the toolchain
  invocation.

## 3. The container-orchestration frontier — envy with a hard limit

The CI tools worth envying for **container orchestration** are
container-*native* by design: **Tekton** (every step a container in a k8s
pod, workspaces as volumes, a Pipeline = a DAG of Tasks), **Argo
Workflows** (container-DAG with artifact passing), **Concourse** (every
step a container + versioned resource, immutable pipelines), **Drone**
(pipeline = container steps). Their shared bet: *the container is the unit
of a build step.*

aeb has the raw material to move toward this — the `container.image` /
`container.run` / future `container.service` grammar
([`containment-and-the-control-plane.md`](containment-and-the-control-plane.md)),
nodes-as-subprocesses (each node already its own process), and the agent
grid. The envy is legitimate and lands in **Ring B/C**: "what if an aeb
node could run in its own container with declared workspaces, scheduled,
with sidecars" is a real and good direction, and Tekton is the clearest
mirror for it (see a future `aeb-vs-tekton.md`).

**But this is exactly where the invariant bites, and it bites on
purpose.** The container-native CIs make the container *mandatory* — in
Tekton there is no "just run the step in this process," every step is a
pod. aeb takes the **inverse stance**: containerization is **a builder
you opt into**, and the same pipeline must still run as one process with
zero containers when you don't. Where Tekton says *"the step is a
container,"* aeb says *"the step is a function call; you may, if you
choose, make it a container."* So:

- **Take from Tekton/Argo/Concourse:** declared per-step workspaces /
  inputs-outputs (the artifact-passing discipline — aeb already does this
  over disk markers, `nodes-as-subprocesses.md`); sidecar/service
  lifecycle (the `container.service` + `lifecycle_plan.md` teardown
  story); scheduling independent steps (Ring B's `make -jN`, later a real
  scheduler).
- **Refuse from them:** container-as-mandatory-step-unit; a required
  cluster/daemon; pipeline semantics that *only* exist inside the
  container model. The day aeb can't run a pipeline as a lone process is
  the day it broke its own invariant.

The synthesis: aeb can grow *toward* container-native CI's orchestration
power (Ring B/C) **while keeping the container optional** — the one thing
none of those tools offer, and the thing that keeps Ring A intact.

## 4. The as-CI frontier (Ring C) — see the Jenkins doc

The "aeb becomes a CI tool" direction is written up in
[`aeb-vs-jenkins.md`](aeb-vs-jenkins.md): self-hosted controller + owned
agent fleet + pipeline-as-code, with the deliberate refusals (no Groovy-
sandbox trust boundary, no server-side plugin store, no stateful-
controller SPOF). It sits entirely in Ring C and is gated by the same
invariant: the controller/agent machinery is opt-in scaffolding around a
core that still builds as one process. The agent grid
([`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md))
is its substrate; policy-class × grant is its authority model.

## 5. Priority lens (not a schedule)

Ordered by *value per unit of distance from the invariant* — cheap,
Ring-A things first; invariant-threatening things never:

1. **Ring A, cheap, high-value:** `aeb query`/`rdeps`; finish cache-into-
   skip across SDKs; lean further into library-invocation steps
   (`--emit=lib` SDKs, in-process hosting from `.build.ae`).
2. **Ring B, designed, unblocked:** per-step `timeout { … }` + per-step
   reaping (rides on nodes-as-subprocesses); `container.service` for
   sidecar/service steps.
3. **Ring C, heavy, opt-in:** remote cache (as repeatability); the
   persistent controller + inbound triggers (the as-CI step).
4. **Never:** anything that makes the single-process / no-container /
   library-call build impossible or second-class — mandatory sandbox,
   mandatory container per step, required daemon/cluster, store-owned
   toolchains.

## The one-line statement

> aeb grows *outward* — parallel, subprocess, containerized, distributed,
> as-CI — but only ever as **opt-in rings around a core that always
> remains a single-threaded, non-container, single-process build**, and
> it leans *into* the road the big CIs ignore: **steps as library
> invocations in one process.** Envy the container-native orchestrators'
> power; refuse their mandatory container. The floor is sacred.
