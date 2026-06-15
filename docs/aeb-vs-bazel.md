# aeb vs. Bazel

The canonical aeb↔Bazel comparison. Bazel is the closest prior art for
aeb's *core* — a declarative, file-based, greppable build DAG over a
polyglot monorepo — so this is the most important comparison in the set
and the one to get right.

Consolidates and supersedes earlier scattered material — a root-level
feature-gap table (now removed; its content, with corrected status, lives
here) and two real-world "musings" written *during* the PyTorch and
Selenium migrations, kept for their narrative detail:
- [`../itests/pytorch/Aeb_vs_Bazel.md`](../itests/pytorch/Aeb_vs_Bazel.md)
  and [`../itests/selenium/Aeb_vs_Bazel.md`](../itests/selenium/Aeb_vs_Bazel.md)
  — the framings below are distilled from them.

Companion comparisons on adjacent axes:
[`aeb-vs-starlark.md`](aeb-vs-starlark.md) (the rule/macro language),
[`aeb-vs-nix.md`](aeb-vs-nix.md) (hermeticity/closures),
[`aeb-vs-moon-moonbit.md`](aeb-vs-moon-moonbit.md) (single-language depth).

## Same starting point, different bet

Bazel and aeb begin in the *same* place — a declarative file-based DAG,
greppable rule edges, no recursion-driven build, topo-sorted execution,
polyglot by design. The split is in what each treats as **load-bearing**:

- **Bazel's bet: hermeticity.** Correctness-first. Pinned toolchains, a
  per-action sandbox that fails the build if you touch an undeclared
  input, content-addressed everything, remote execution. The payoff is
  *worst-case correctness at hyperscale*: no bad artifact ever lands, and
  the same inputs produce the same bytes on any machine. The cost is
  months of toolchain-parity work and a steep concept count
  (platforms, constraints, `select()`, visibility, repository rules).
- **aeb's bet: the closure DSL over real toolchains as they stand.**
  Ergonomics-first. The source tree *is* the graph; a target is a
  dot-`.ae` file next to the code; builders are typed Aether closures;
  the toolchains are whatever the host has (selected, not provisioned).
  The payoff is *average-case throughput for a 5–50-person polyglot
  monorepo* with a fraction of the concepts. The cost is that aeb does
  **not** promise bit-identity or enforce hermeticity (see
  [`aeb-vs-nix.md`](aeb-vs-nix.md)'s repeatability-vs-reproducibility
  framing — the same axis).

Neither bet is wrong; they're tuned for different blast radii. Google's
pain from one bad cached artifact is an incident and a rollback; a
50-person org's is "delete cache, rebuild, move on."

## Status — what aeb HAS (several shipped since the earlier gap analysis)

An earlier gap analysis (a 2026 feature table, since folded into this
doc) listed some of the following as *gaps*. Verified against current
code, they have **shipped**:

| Bazel feature | aeb today |
|---|---|
| Polyglot, one tool, many languages | **[have]** 20+ language SDKs under `lib/` (incl. dart, moonbit, gleam) |
| Explicit, greppable, statically-extractable DAG | **[have]** `build.dep("…")` edges, scanned without evaluation |
| Multi-language FFI handoff | **[have]** Java↔Rust (JNI), Java↔Go (.so), Aether↔C/Rust, etc. |
| Native registries | **[have]** Maven/crates.io/npm/NuGet/pip via `build.dep` |
| **Parallel execution** | **[have]** — `tools/aeb-driver.ae` emits a Makefile and runs `make -jN` (independent nodes concurrent). *Earlier analysis: "none" — since shipped.* |
| **Affected-target detection** (`git diff → only impacted`) | **[have]** — `aeb --since <ref>` / `--print-affected`. *Earlier analysis: "not there" — since shipped.* |
| **Build-graph visualisation** | **[have]** — `aeb --graph` (DOT) / `--graph mermaid`. *Earlier analysis: "not-yet-done" — since shipped.* |
| **Content-addressed cache wired into skip decisions** | **[have]** (partial) — `lib/cache` sha256+zlib is wired into `lib/aether` (link), `lib/maven`, `lib/java`; `cache.get`/`cache.put` gate rebuilds there. *Earlier analysis: "not yet wired" — now true for several SDKs, mtime-only for the rest.* |
| Watch mode | **[have]** — `aeb --watch` (inotify/fswatch). |
| Sparse checkout for monorepos | **[have]** — `aeb gcheckout` (DAG walk → `git sparse-checkout`). |
| Per-step process reaping + `--timeout` | **[have]** build-level (trampoline `set -m` + group-kill); per-step is design ([`lifecycle_plan.md`](lifecycle_plan.md) §9). |

So the honest 2026 read: **aeb has closed most of the *scaling-DX* gaps
the earlier analysis flagged** (parallelism, affected-targets, graph viz,
cache-into-skip). What remains is genuinely the *hermeticity/correctness*
and *hyperscale* tier — which is largely the part aeb **declines on
purpose**, not the part it hasn't gotten to.

## Where Bazel is genuinely ahead — and which aeb will pursue vs. decline

### Pursue (real gaps, on the roadmap) — [design]

- **Remote cache.** `lib/cache` is local-only today; phase 2 is designed
  in [`distributed-cache-plan.md`](distributed-cache-plan.md) — and note
  it's framed as a *repeatability* cache with a stated policy contract,
  **not** a Bazel-style reproducibility CAS (that's the deliberate
  divergence, not an oversight).
- **Query / introspection.** No `query`/`cquery`/`aquery` —
  `deps()`/`rdeps()`/`somepath()`/`allpaths()`. The graph already exists
  in memory during a build and the edges file is on disk, so a read-only
  `aeb query`/`aeb rdeps` is low-risk and high-value; the affected-target
  walk is already half of it.
- **Finer cache granularity.** Wiring `lib/cache` into the remaining SDKs
  (the table above is partial) — pure follow-through.

### Decline, or do differently — [won't] / [different]

These are where aeb consciously refuses Bazel's approach (the itest
musings call this "the strict-vs-permissive middle ground" / "the
Wingerd middle ground"):

- **Mandatory per-action sandbox + hermetic toolchains.** Bazel fails the
  build if you touch an undeclared input, and fetches a pinned
  compiler+sysroot per build. aeb **selects** an installed toolchain
  (discover-select-or-fail, [`toolchain-selection-and-locks.md`](toolchain-selection-and-locks.md))
  but **never provisions**, and contains for *trust on a shared agent*
  ([`build-veto-and-sandbox.md`](build-veto-and-sandbox.md) /
  [`containment-and-the-control-plane.md`](containment-and-the-control-plane.md))
  rather than for bit-reproducibility. `TODO.md` records that
  tool-version *validation* was explicitly weighed and chosen as
  fail-fast-not-pin. **[different, deliberate]**
- **`select()` / `config_setting` / platforms+constraints.** Bazel's
  configurable-attributes machinery is a large concept surface; aeb's
  cross-compile is per-SDK env-var plumbing today. Whether aeb grows a
  `select()` analogue is open — the bar is "does it earn its concept
  cost for the target user," and so far the answer has been no.
  **[different]**
- **Starlark's full rule/macro language.** aeb can express the same
  abstraction space with Aether closures (see
  [`aeb-vs-starlark.md`](aeb-vs-starlark.md)) but **deliberately keeps it
  small** — the explicit non-goal is Starlark's failure mode where build
  intent disappears behind repo-specific macro frameworks and "what does
  this target depend on?" stops being greppable. aeb protects the
  source-tree-is-the-graph property over macro power. **[won't]**
- **strictdeps / layering enforcement, visibility.** Bazel fails on an
  `#include` from an undeclared transitive dep, and has
  `visibility = [...]`. aeb has neither; both are correctness features
  that ride on the sandbox aeb doesn't mandate. Candidates *if* the
  veto/containment layer grows that far, but not today. **[design, low]**
- **Daemon/server model.** Bazel keeps the loaded graph hot in a JVM
  server. aeb regenerates + recompiles its orchestrator each invocation
  (cheap at aeb's scale; the `tools/` helpers are prebuilt and reused).
  A persistent server only becomes interesting in the "aeb as CI"
  direction ([`aeb-vs-jenkins.md`](aeb-vs-jenkins.md)). **[different]**
- **Remote execution.** Distinct from remote *cache*; full RBE is a
  hyperscale feature. aeb's analogue is the **agent grid** (sovereign
  `aeb-agent` + dispatch, [`agent-lifecycle.md`](agent-lifecycle.md)) —
  related shape, different contract (a fleet of trusted peers, not a
  fungible RBE worker pool). The developer *experience* is RBE — a thin
  client dispatches, the build runs on a box with the toolchain, the
  result returns — and the per-job-container path (`--run-on podman`,
  toolchain image chosen per dispatch from the build's `prereq`s) is
  demonstrated end-to-end in [`agent-container-ladder.md`](agent-container-ladder.md).
  What stays *different* from hyperscale RBE: trusted sovereign agents
  vs. a fungible/untrusted worker pool, and node-granular dispatch (one
  `.build.ae`) vs. action-granular (one compiler call). **[different]**

### DX / ecosystem gaps (real, unglamorous)

No Bazelisk (`.aeb-version` auto-fetch), no Buildifier (`.build.ae`
formatter — partly Aether-tooling's job), no Gazelle (auto-generate
`.build.ae` from source layout), no LSP/IDE plugin, no aeb-level central
registry (aeb leans on each language's). All **[no]**, all roadmap-able,
none architecturally hard.

## What the real migrations revealed (PyTorch, Selenium)

The two itest musings are worth reading in full; the load-bearing
findings:

- **The closure DSL scaled to real polyglot DAGs.** Selenium (Java + JS +
  Python + Rust) and PyTorch (C++ + Python + codegen) both expressed
  cleanly as `.build.ae` graphs without a macro layer — evidence the
  "keep it small" Starlark stance holds under real load.
- **The clear gap was the same both times: hermeticity/cache at scale**,
  not expressiveness. aeb didn't run out of *grammar*; it ran into the
  *correctness-at-scale* tier — exactly the tier it bets differently on.
- **"Why aeb won't parse `maven_install.json`"** (Selenium): aeb honours
  external lock formats via shell-out to the tool that owns them, rather
  than parsing them itself — the `.ae`-as-truth principle, which is the
  anti-Bazel-`MODULE.bazel`-registry stance in miniature.

## Net positioning

> Bazel and aeb share a DNA — declarative, greppable, polyglot DAG — and
> diverge on the bet. Bazel bets on **hermeticity for worst-case
> correctness at hyperscale**, paying months of toolchain-pinning and a
> large concept surface. aeb bets on the **closure DSL over real
> toolchains for average-case throughput at human scale**, paying a named
> loss of bit-reproducibility. aeb has, by now, **closed most of Bazel's
> *scaling-DX* gaps** (parallelism, affected-targets, graph viz,
> content-cache-into-skip) and **deliberately declined most of Bazel's
> *hermeticity* tier** (mandatory sandbox, pinned toolchains, `select()`,
> the full macro language). The remaining genuine roadmap items —
> remote cache (as *repeatability*, not RBE-reproducibility), `aeb
> query`, finer cache wiring — are the ones that give Bazel-grade
> productivity without adopting Bazel's correctness contract.

## Rule of thumb

Reach for Bazel when you need **hermetic, bit-reproducible builds at
hyperscale** and will pay the toolchain-pinning and concept-count tax.
Reach for aeb when you want a **fast, greppable, language-aware
source-tree-native graph** for a human-scale polyglot monorepo that
*names* what its cache does and doesn't guarantee. Don't port Bazel's
macro/sandbox/`select()` machinery into aeb wholesale — adopt the parts
that earn their concept cost (query, remote cache as repeatability) and
keep aeb's source-tree-is-the-graph advantage intact.
