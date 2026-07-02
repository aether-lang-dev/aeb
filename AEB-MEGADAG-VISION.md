# Todo-Backend as an aeb mega-DAG — plan / design / vision

> Status: **vision doc only.** No build files yet. This is the map.

## The thesis

[servirtium-vcr](../servirtium-vcr) proves aeb *in the small*: ~21 language
bindings of one library — a polyglot DAG, real cross-language deps, one test
runner, every dependency sha256-pinned. It already carries a *miniature* of
this idea in `integration/todobackend/` (10 language bindings each running the
canonical TodoBackend JS spec — a Mocha/Chai CRUD suite — in headless Chrome
against a Servirtium VCR, recorded once against a Kotlin SUT then replayed
offline from a committed tape).

This proposes the *large* version: **Todo-Backend's 141 independent
implementations, across 30+ languages and frameworks, pulled into one repo as
one aeb DAG** — each a third-party repo built in its own container, all
conforming to a single spec, the whole fan fanned out to build agents.

Where servirtium says *"aeb can build a polyglot library,"* this says *"aeb can
ingest, isolate, build, and conformance-test 141 strangers' repos at once."*
That is the Bazel-monorepo pitch — but with **hermetic per-implementation
containers, cloud-agent fan-out, and supply-chain veto on untrusted code**,
which Bazel doesn't hand you out of the box.

## Why "legacy" is the feature, not the bug

Todo-Backend is effectively dormant. That is exactly what makes it ideal:

- **Frozen corpus.** 141 implementations that won't shift under us — a stable
  benchmark you can re-run and compare against. A moving target can't be a
  benchmark.
- **It's the *hard* reproducibility test.** A 2016 Scala/sbt impl, or a
  Node-0.12 Express app, or a Ruby/Sinatra with long-dead gem versions, is
  *unbuildable the naïve way* — the transitive deps and the toolchain are gone
  from `PATH`. Making it build again is **precisely** the test of pinned
  toolchains + pinned deps + containers — the machinery this lineage just
  built (sha256-pinned `mvn_repo` closures resolved from a content-addressed
  cache; per-language SDKs that select a toolchain; `container.image` builds).
  If aeb can resurrect a frozen polyglot corpus, the reproducibility story is
  *real*, not a slide.
- **Failures are data, not blockers.** Some upstreams have rotted past rescue.
  *"N of 141 build green; here's the failure taxonomy"* is itself an honest,
  compelling result — and a living regression target that only gets better as
  the container/pinning machinery hardens.

## The corpus (upstream, not yet vendored here)

The canonical manifest is Todo-Backend's own `data/implementations.yaml`
(upstream at [todobackend.com] / the `TodoBackend/todobackend.com` repo) —
**141 entries**, each:

```yaml
".NET 6 / Clean Architecture":
  sourcecode_url: https://github.com/thehaseebahmed/aspnetcore-clean-architecture
  live_url: https://csharp-todo-backend.azurewebsites.net/api/v1/todo
  tags: [dotnet, csharp]
```

The tag spread (top of the long tail):

| | | | | |
|---|---|---|---|---|
| jvm ×49 | java ×27 | postgres ×25 | gradle ×17 | nodejs ×15 |
| dotnet ×15 | javascript ×13 | scala ×12 | kotlin ×12 | spring ×10 |
| csharp ×10 | python ×9 | mongodb ×9 | golang ×8 | vertx ×6 |
| ruby ×6 | php ×6 | fsharp ×6 | haskell ×5 | … |

…trailing into clojure, rust, perl, crystal, elixir, ktor, hapijs, owin, and
dozens more. **Every JVM language and most of the web ecosystem, plus a long
tail of the exotic** — across SDKs aeb already has (java/kotlin/scala/clojure/
groovy/go/rust/python/ruby/php/dotnet/ts/…) and some it doesn't (crystal, perl,
fsharp, vlang, …), which is itself a useful forcing function.

[todobackend.com]: https://www.todobackend.com/

## The conformance contract (what makes it *one DAG*, not 141 islands)

Every implementation, whatever its language, satisfies the **same** contract:
serve the Todo-Backend REST API and pass the **`todo-backend-js-spec`**
(the canonical Mocha/Chai CRUD conformance suite, ~16 assertions). servirtium
already vendors a copy of that suite at
`../servirtium-vcr/integration/todobackend/suite/` (`specs.js` + `runner.js`),
where its 10 bindings run it in headless Chrome — the natural starting point
for the shared spec node here.

So the DAG is not 141 disconnected trees. It has a **shared spine**:

```
                          ┌─ todo-backend-js-spec (the ONE conformance suite)
                          │      ▲ every impl's .tests.ae deps this node
   141 per-impl subgraphs:│
      <impl>/.build.ae  ──┤  build the SUT (in its own container)
      <impl>/.tests.ae  ──┴─ up SUT → run the shared spec against it → assert 16/16 → down
```

One node (the spec) is depended on by all 141 — the cross-cutting edge that
makes this a genuine monorepo DAG and not a `for` loop.

## Why this is *the* test case for aeb containers + agents

Three properties of this corpus map onto exactly the aeb capabilities that
need a hard workout:

1. **Per-impl toolchain isolation → containers are mandatory, not optional.**
   30+ languages × many framework/runtime versions *cannot* coexist on one
   host `PATH` (aeb's honest "hermetic toolchains ✗" gap). Containers are the
   answer: each impl declares its build image (`FROM gradle:7…`, `FROM
   node:14…`, `FROM ruby:2.5…`), aeb's `lib/container` (`container.image` /
   `container.run`) builds and runs it. The mega-DAG *forces* aeb to lean on
   containers for toolchain hermeticity — the exact thing you want to exercise.

2. **141 independent nodes → embarrassingly parallel → agent fan-out.** The
   per-impl subgraphs share only the spec node; otherwise they're independent.
   That's the ideal shape for `aeb-agent` dispatch: fan 141 container builds
   across a pool of build agents (local or cloud), each builds+tests one impl
   in isolation and reports a verdict. It stresses dispatch, the
   accept/busy/reject decision, and result aggregation at real scale (see
   `../aeb/docs/agent-lifecycle.md`).

3. **141 third-party untrusted repos → the supply-chain story, for real.**
   These are *strangers'* repos with `postinstall` hooks, `binding.gyp`,
   curl-pipe-sh build scripts, the lot. That's precisely what `aeb --vet`
   (AST deny-rules + coordinate allowlist), `--sandbox` (deny-by-default,
   no-tcp libc containment), and the container boundary are *for*. Running the
   veto across 141 real-world build trees is the most credible demonstration
   aeb could give of "treat the build tree as an untrusted surface."

## The mega-DAG shape (per implementation)

Two leaves per impl, modelled on the existing
`servirtium-vcr/integration/todobackend/` pattern (which already does
container-up → exercise → container-down inline in Aether):

```
<impl-dir>/
  Containerfile          # FROM <impl's runtime>; build the SUT image
  .build.ae              # container.image(b) { ... }  — build the SUT image
  .tests.ae              # up SUT container → run todo-backend-js-spec → assert → down
```

- **`.build.ae`** — `container.image(b)` builds the implementation in its own
  toolchain container. For impls aeb has a native SDK for, an alternative
  non-container path (`java.javac` + a pinned `mvn_repo`, `go.go_build`, …) is
  possible — and the *comparison* (container vs native pinned) is itself a
  finding.
- **`.tests.ae`** — the uniform conformance test: bring the SUT up, run the
  shared `todo-backend-js-spec` against its HTTP endpoint, assert 16/16, tear
  down unconditionally (the `up → poke → down` shape from
  `../aeb/docs/container-lifecycle.md`). DB-backed impls (25 postgres, 9
  mongodb) bring up a sidecar DB container too.

The spec is one shared node every `.tests.ae` `build.dep`s — so a change to the
conformance suite re-tests all 141 (aeb `--since` / affected-target detection
turns that into "only re-test what changed").

## What it exercises — and the gaps it would expose

A scorecard against aeb's own (from `../aeb/LLM.md`):

| aeb capability | how the mega-DAG hammers it |
|---|---|
| Build-graph topology ✓ | 141-node DAG with a shared spine — the biggest real graph aeb has seen |
| Multi-language ✓ | 30+ languages in one tree, well past the "≥5" bar |
| Container SDK ✓ | per-impl build+run images become the *primary* build path, not a sidecar |
| Supply-chain veto / sandbox ✓ | run `--vet`/`--sandbox` across 141 untrusted strangers' trees |
| Agent fan-out (`aeb-agent`) | 141 independent nodes — the canonical fan-out workload |
| Pinned deps (`mvn_repo` / sha256) | resurrect dead-dep legacy impls reproducibly |
| Affected-target (`--since`) ✓ | spec change → reverse-dep walk re-tests only the impacted impls |
| **Hermetic toolchains ✗** | containers *paper over* this gap — the corpus shows whether that's enough |
| **Remote build cache ✗** | 141 container builds *beg* for a shared cache; this is the motivating workload |
| **CI integration ✗** | "the conformance dashboard" (X/141 green, per-language) wants CI output |
| **Cross-compilation ✗** | mostly N/A (services, not binaries) — but multi-arch images touch it |

The honest read: the mega-DAG **validates** aeb's strong axes (graph, polyglot,
container, veto, agents, pinning) at a scale nothing else has, and **pressures**
the weak ones (hermetic toolchains, remote cache, CI) into being roadmap items
with a concrete forcing workload behind them.

## Phased plan

- **Phase 0 — this doc.** The vision + the honest risks. ← *we are here.*
- **Phase 1 — ingest.** Fetch Todo-Backend's upstream `data/implementations.yaml`
  and parse it → a machine-readable manifest (name, repo, tags, live_url).
  Curate a starter subset: begin with
  languages aeb already has SDKs + the 8 already containerized in servirtium.
  Vendor the chosen repos as subdirectories (git submodule or a frozen
  snapshot — legacy means snapshots are safe and reproducible).
- **Phase 2 — the spine + one exemplar end-to-end.** Stand up the shared
  `todo-backend-js-spec` node; pick *one* simple live impl (a Go or Node one)
  and get `container.image` build + conformance test green. Prove the loop.
- **Phase 3 — generate, don't hand-write.** A `repo → (.build.ae +
  Containerfile + .tests.ae)` generator (same spirit as `mvn-to-aeb`): infer
  the runtime from tags, scaffold the container build + the uniform conformance
  test. Hand-fix the long tail.
- **Phase 4 — scale out.** Fan the build/test across `aeb-agent`s; produce a
  conformance dashboard (X/141, per-language, with a failure taxonomy:
  *dead-deps / dead-runtime / needs-DB / network-only / genuinely-broken*).
- **Phase 5 — the showcase.** `aeb --graph mermaid` of the spine + a slice of
  the fan; the headline number; the "we rebuilt a frozen 2015-era polyglot
  corpus reproducibly, in containers, with pinned deps, fanned to agents,
  vetted as untrusted" story.

## Honest risks & unknowns

- **Upstream rot.** Many of the 141 will not build — dead package registries,
  removed base images, abandoned runtimes. *Expected and fine* (it's the
  reproducibility test); but don't promise 141/141.
- **Dead `live_url`s.** Many hosted demos are down. The conformance test must
  run the SUT *we build*, not the upstream's hosting.
- **DB & network deps.** 25 postgres + 9 mongodb impls need sidecar DB
  containers; some impls reach external services. More container orchestration,
  more flakiness surface.
- **Scale of effort.** 141 third-party repos is a genuinely large ingestion +
  per-impl debugging job — Phase 3's generator is what makes it tractable, not
  heroic hand-work.
- **Licensing.** Vendoring third-party repos in-tree needs a license audit
  (or a submodule-only approach that pulls at build time).

## The one-line pitch

> *servirtium showed aeb building a polyglot library. Todo-Backend shows aeb
> ingesting 141 strangers' repos across 30+ languages, building each in its own
> pinned container, fanning the lot to cloud agents, vetting every untrusted
> tree, and conformance-testing all of them against one spec — a frozen,
> reproducible, greppable mega-DAG.*
