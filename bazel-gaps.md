# AetherBuild vs. Bazel — feature gap analysis

> **Superseded — see [`docs/aeb-vs-bazel.md`](docs/aeb-vs-bazel.md) for the
> canonical, current comparison.** This original gap table is kept for its
> detail, but parts are now **stale**: several items it lists as gaps have
> since shipped (parallel execution via `make -jN`, affected-target
> detection `--since`/`--print-affected`, graph viz `--graph`, and the
> content-cache wired into rebuild decisions for several SDKs). The
> canonical doc reconciles have/design/won't accurately and explains which
> remaining gaps aeb pursues vs. deliberately declines.

Source: comparison against the "Introduction to Bazel" talk (Flor, Enflow) — covers Bazel's pitch as of 2026.

AetherBuild already has the polyglot core (18 SDKs, explicit DAG, topo-sort, multi-language FFI). It trails Bazel on most of the scaling/correctness features that came up in the talk.

## Have it (or close)

| Bazel feature | aeb status |
|---|---|
| Polyglot, one tool for many languages | Done. 18 SDKs in `lib/` (java, kotlin, scala, go, rust, dotnet, python, clojure, ts, angular, jest, webpack, pnpm, container, etc.) |
| Explicit build graph | Done. `tools/topo-sort.ae`, `tools/aeb-main.ae:100-180` BFS through `.build.ae` deps |
| Multi-language FFI | Done. Java ↔ C/Rust via `shared_library_deps_including_transitive` (`lib/java/module.ae:333-361`); Aether ↔ C/Rust (`lib/aether/module.ae:85-100`) |
| Native registries | Done. Maven Central, crates.io, npm, NuGet via `build.dep()` |
| Content-based hashing primitives | Partial — phase 1. `lib/cache/module.ae` SHA256 + zlib + sharded local store, `tests/test_cache.ae`. Not yet wired into build skip-decisions (still timestamp-based per `build._needs_rebuild()`). |
| Cross-compilation | Partial — sketched (Go GOOS/GOARCH, Rust `--target`, .NET `--runtime`) but `TODO.md:238-242` flags it as untested end-to-end |

## Material gaps vs. Bazel

### Correctness / hermeticity (the talk's central thesis)

- **Sandboxing** — none. Bazel uses Linux namespaces / macOS `sandbox-exec` to enforce that undeclared deps fail. `TODO.md:309-321` has a DSL sketch (`grant_fs_read`, `grant_fs_write`, `grant_exec`) but nothing implemented. aeb currently trusts modules to declare deps correctly; missing deps just "happen to work" via system PATH.
- **Hermetic toolchains** — none. Bazel's `hermetic_cc_toolchain` / hermetic JDK fetch a pinned compiler+sysroot. aeb uses whatever `javac` / `go` / `rustc` / `mvn` is on `PATH`. `TODO.md:414-421` explicitly *rejected* tool-version validation in favour of fail-fast — that's a deliberate divergence from Bazel's "everything pinned" stance.
- **Reproducibility flags** — not handled. No equivalent of the rules_cc layer that auto-injects `-ffile-prefix-map`, `-Wl,--build-id=none`, etc. (the audience question at 45:46 in the talk).

### Scaling

- **Remote cache** — none. `TODO.md:189-202` is the explicit roadmap; `lib/cache/` is local-only phase 1. Direction & policy framing: [`docs/distributed-cache-plan.md`](docs/distributed-cache-plan.md) — Wingerd-style named scopes (mainline / dev / release / task) with promotion gates, sequenced ahead of CDC.
- **Remote execution** — none. Local sequential execution only.
- **Parallelism** — none. `TODO.md:177-181` mentions actor-based parallel execution; current runner walks topo order serially.
- **Daemon / server model** — none. Bazel keeps the loaded graph hot in a JVM server; aeb regenerates and recompiles its orchestrator binary (`target/_ae_build_all` — the per-run driver that calls each module's function in topo order; *not* the `tools/` helper binaries, which `make install` prebuilds and which are reused unchanged across invocations) every invocation. The regen+compile is driven by `tools/aeb-main.ae` → `tools/aeb-link.ae`.
- **Lazy loading of build files** — partial. aeb scans `.build.ae` files transitively from a target, which is the right shape, but there's no three-phase loading/analysis/execution pipeline.

### Query / introspection

- **No `query` / `cquery` / `aquery`** at all. No `deps()`, `rdeps()`, `somepath()`, `allpaths()`, `tests()`, action-graph dump. `TODO.md:204-209` lists "graph visualization (DOT/Mermaid)" as not-yet-done.
- **No affected-target detection** — the `git diff → run only impacted tests` workflow (39:01 in the talk) isn't there. Listed in `TODO.md` runner section as not done.
- **No layering / strictdeps checks** — Bazel will fail a build if you `#include` a header from a transitive dep you didn't declare directly. aeb has no equivalent (audience question at 50:27).
- **No visibility** — Bazel's `visibility = ["//foo:__pkg__"]` (slide at 18:00). aeb has no public/private distinction between targets.

### Configuration model

- **No `select()` / configurable attributes** — Bazel's `config_setting` + `select()` for picking deps/flags per platform is absent. Cross-compile is per-SDK env-var plumbing.
- **No platforms / constraint API**.

### Ecosystem / DX

- **No Bazelisk equivalent** — no `.aeb-version` file + auto-fetch of pinned aeb binary.
- **No Buildifier equivalent** — no formatter/linter for `.build.ae`. (`.ae` is Aether source, so this overlaps with whatever Aether tooling exists.)
- **No Gazelle equivalent** — no auto-generation of `.build.ae` from source layout.
- **No IDE integration** — no LSP, no IntelliJ/VSCode plugin, no compile-commands export.
- **No central registry** — Bazel Central Registry pins `MODULE.bazel` deps. aeb relies on each language's own registry; there's no aeb-level "this is the canonical fmt / protobuf / abseil entry."

## Suggested priority order

If "go after Bazel's featureset" is the framing, the high-leverage next steps are roughly:

1. **Wire `lib/cache/` into `build._needs_rebuild()`** — finish phase 1 by switching skip decisions from mtime to content hash. Cheap; unlocks reliable branch-switching.
2. **Affected-target query + `aeb test --since <ref>`** — small surface, huge CI value, falls out naturally from the existing DAG walk.
3. **Remote cache backend behind `lib/cache/`** — phase 2 from `TODO.md:189-202`. Even an HTTP-CAS client gets most of the productivity win.
4. **`aeb query` / `aeb rdeps`** — read-only; the graph already exists in memory during a build.
5. **Sandboxing** — bigger lift, but the correctness story is hand-wavy without it.

Hermetic toolchains, remote execution, `select()`, and a registry are larger structural projects; worth scoping separately.
