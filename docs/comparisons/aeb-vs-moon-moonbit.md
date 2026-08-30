# aeb vs. moon (MoonBit's build system)

Grounded in the `moon` source at `../moonbit/moon/` (88k lines of Rust
across 8 crates) and aeb's own tree (~25k lines of Aether). This is a
comparison of two build systems that barely overlap in purpose — which
is the point: moon is the *reference design* for what a single-language,
compiler-integrated build system looks like, and aeb is deliberately the
opposite shape. Reading them side by side is the clearest way to see
what each is actually for.

The aeb `lib/moonbit` SDK (this repo) makes them adjacent in practice:
aeb can *drive* moon as one node in a polyglot graph. So the question
isn't "which wins" — it's "what is each the right tool for, and where is
the seam between them."

## The one-sentence each

- **moon** is the build system **and package manager** for MoonBit: a
  compiler-aware engine that knows MoonBit's module/package model, builds
  a Ninja-style action graph at the *compilation-unit* level, executes it
  in parallel with content-hash incrementality, and resolves versioned
  dependencies from a registry (mooncakes.io).
- **aeb** is a **polyglot monorepo orchestrator**: a language-agnostic
  DAG over per-module `.ae` files that shells out to each language's
  *own* toolchain (including moon), with a closure-DSL config and a
  greppable, statically-extractable dependency graph.

moon goes **deep** into one language. aeb goes **wide** across many,
treating each language's build tool (moon included) as a black box it
sequences.

## Architecture, side by side

| Dimension | moon | aeb |
|---|---|---|
| **Scope** | One language (MoonBit), end to end | Many languages (20+ SDKs), orchestrating their toolchains |
| **Implementation** | ~88k lines Rust, 8 crates | ~25k lines Aether, SDK-per-language under `lib/` |
| **Compiler awareness** | Deep — drives `moonc` directly, knows the module graph, conditional compilation, targets | None — shells `moon`/`cargo`/`javac`/… and reads exit codes + summary lines |
| **Build-graph granularity** | Per **compilation unit** (package/file-level actions) | Per **module** (one `.build.ae` = one node; the SDK runs a whole toolchain invocation inside) |
| **Execution engine** | `n2` (a Ninja-compatible engine in Rust) — builds an in-memory `n2::graph::Graph`, executes parallel | **Emits a Makefile from the DAG and runs `make -jN`** (N = `nproc`, or `AEB_JOBS`), `-k` to keep going past failures; independent nodes run concurrently. Sequential is only the fallback when `make` is absent or `AEB_JOBS=1`. (Each node is also a self-contained orchestrator-compiled binary.) |
| **Incrementality** | Content-hash, fine-grained, per-action (n2's staleness model) | Per-module: content-addressed cache wired into *some* SDKs (maven, aether, java); mtime-only for others |
| **Dependency resolution** | Real package manager — `mooncake` resolves semver from mooncakes.io, lockfile, registry | Delegated per-language (Maven/npm/Cargo/NuGet/pip resolvers); aeb itself resolves none |
| **Config** | `moon.mod.json` (module) + `moon.pkg.json` (package) — declarative JSON | `.build.ae` closure-DSL — Aether code with setters, no eval'd config |
| **Targets / cross-compilation** | First-class: wasm / wasm-gc / js / native / llvm, with a target-triple model | TODO (roadmap); per-SDK only if the underlying tool does it |
| **Pre-build / codegen** | Build scripts (`build_script.rs`) — a structured `BuildScriptEnvironment` (target triple, profile, out-dir) given to a generator; **not run for downstream dependency consumers** (security) | `<lang>.codegen` with **explicit** input/output declarations + mtime staleness + missing-output verification; works *across* package boundaries |

## Where moon is categorically ahead (and aeb shouldn't try to compete)

These follow directly from moon being a single-language, compiler-coupled
system. They are not gaps aeb should "fix" — they're the dividend of a
narrower scope.

1. **Compilation-unit granularity.** Both systems parallelize — moon
   builds a Ninja graph of individual compile actions and runs them via
   n2; aeb emits a Makefile from its DAG and runs `make -jN`, so
   independent module nodes build concurrently. The real difference is
   *granularity*, not whether-parallel: moon's node is a single
   compilation action, aeb's node is a whole module (one `moon`/`cargo`/…
   invocation). For one large MoonBit project, moon rebuilds *exactly*
   the changed units and schedules them at action grain; aeb would
   re-invoke `moon` for the whole module and parallelize only across
   *sibling modules*. moon wins decisively on within-module incremental
   granularity; aeb's parallelism is real but coarser (across nodes, not
   within them — which is the right grain for an orchestrator).

2. **Real, integrated package management.** `mooncake` is a from-scratch
   semver resolver + registry client + lockfile. aeb has no resolver of
   its own — it leans on each ecosystem's. For MoonBit specifically, moon
   *is* the dependency story; aeb's `moonbit.deps` just shells
   `moon install`.

3. **Cross-target compilation as a first-class model.** moon carries a
   full target-triple abstraction (arch/vendor/os/abi) and switches
   backends (wasm/js/native/llvm) coherently. aeb's cross-compilation is
   a roadmap line; it can only cross-compile if the wrapped tool does.

4. **Compiler-accurate incrementality.** moon's staleness is exact
   because it knows the compiler's inputs/outputs per action. aeb's cache
   is coarser (per-module) and only fully wired for a few SDKs.

## Where aeb is categorically different (and moon can't follow)

These follow from aeb being language-agnostic. moon *structurally cannot*
do them without ceasing to be moon.

1. **Polyglot in one graph.** aeb's reason to exist: a monorepo where a
   Java service depends on a Rust cdylib that depends on generated
   TypeScript, *and* a MoonBit package. One DAG, one `aeb` invocation,
   cross-language artifact handoff (`program_binary`, JNI, .so). moon
   only sees MoonBit; the moment a second language enters, you need an
   orchestrator above it — which is exactly aeb's niche. **aeb drives
   moon, not the reverse.**

2. **Greppable, statically-extractable graph.** Every dependency edge in
   aeb is a literal `build.dep("path/.build.ae")` string, scannable by
   `grep`/`tools/extract-deps.ae` with zero evaluation — Bazel-BUILD-like
   transparency. moon's graph is computed in Rust from the JSON module
   model; you can't `grep` the edges.

3. **Cross-package codegen tracking that survives the dependency
   boundary.** This is the sharpest contrast in the overlap zone. moon
   *has* build scripts — but by deliberate design they **don't run when a
   package is consumed as a dependency** (a security choice). In a
   monorepo where package A's generated `.mbt` feeds package B's compile,
   moon's own mechanism won't track that edge across the boundary. aeb's
   `moonbit.codegen` with explicit `codegen_input`/`codegen_output` makes
   that generated-source edge a first-class, staleness-checked graph node
   *regardless* of package boundaries. This is precisely why aeb's
   MoonBit SDK adds value *on top of* moon rather than duplicating it.

4. **Uniform DSL across every language.** `aether.program`, `rust.crate`,
   `moonbit.build` all share the same closure-with-setters grammar, the
   same `[telemetry]` reporting, the same `--since`/`--graph`/`--watch`.
   A polyglot team learns one build vocabulary. moon's vocabulary is
   (correctly) MoonBit-shaped.

## The honest verdict

They are not competitors; they are **layers**.

- **For a pure-MoonBit project, use moon directly.** It is faster, more
  granular, has real package management, and understands the language.
  aeb wrapping moon for a single MoonBit module buys you nothing but
  overhead — the recompile is moon's job and moon does it better.

- **For a polyglot monorepo that *contains* MoonBit, use aeb on top.**
  aeb's `moonbit` SDK sequences `moon install → check → test → build`
  as one node in a graph that also builds your Java/Rust/TS/Python,
  tracks cross-language and cross-package generated-source edges, and
  gives the whole repo one build command. moon stays the MoonBit expert;
  aeb is the conductor.

The design philosophies are mirror images, and both are right for their
scope:

- moon: **own the language, compute the graph, drive the compiler.**
  Depth through coupling.
- aeb: **own nothing, declare the graph, shell the tools.** Breadth
  through delegation.

aeb's `lib/moonbit` is the proof that the relationship is composition,
not competition: the orchestrator that owns nothing is at its best when
the thing it shells out to is as good as moon.

## What aeb could learn from moon (concrete)

Not "become moon," but specific, scope-respecting borrows:

- **Finer-grained scheduling within a node.** aeb already parallelizes
  *across* module nodes (Makefile + `make -jN`). What moon's n2 has that
  aeb's `make` layer doesn't is *action-level* scheduling — and aeb can't
  get that without compiler awareness it deliberately lacks. The
  scope-respecting borrow isn't "go finer," it's recognizing the ceiling:
  aeb's grain is the toolchain invocation, and that's correct for an
  orchestrator. (n2 over `make` would buy better progress UX and a
  content-hash dirty model — see the cache point below — but not finer
  grain.)
- **A lockfile story.** moon writes one; aeb's resolvers compute closures
  but don't pin (TODO.md). Reproducibility across machines wants this,
  and it composes with the distributed-cache plan.
- **Finer cache granularity where cheap.** aeb's per-module cache is
  coarse by design, but the content-addressed path (already in
  `lib/cache`) could extend to more SDKs — moon shows the ceiling.
