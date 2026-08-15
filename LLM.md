# Notes to self (LLM assisting on aeb / aeb)

Not a CLAUDE.md — short, opinionated, written for a future LLM picking
up mid-task. Re-read at start of every session.

## What aeb is, in one paragraph

Polyglot-monorepo build runner. Replaces `Makefile` / `pom.xml` /
`package.json scripts` / `Cargo.toml` / `.csproj` / `pyproject.toml`
with small declarative dot-prefixed `.ae` files co-located with each
module. Convention does the work; the file declares intent (sources,
deps, output). The runner (`aeb`) walks the tree, builds a file-based
DAG from `build.dep("path/to/.foo.ae")` lines (greppable, like Bazel
BUILD files — every dep edge is a literal string in source, no
runtime evaluation), topo-sorts, generates a single orchestrator
`.ae` file with one function per module, compiles the whole thing to
C, links to a native binary. That binary is one node's worth of work;
`tools/aeb-driver.ae` then schedules the nodes — by default emitting a
Makefile from the DAG and running `make -jN` so independent nodes run
**concurrently as subprocesses**, coordinating via on-disk `.rc`
markers (`AEB_JOBS=1` or a missing `make` → a sequential in-process
loop instead). Within a single node, module functions are `_static`,
sharing one in-memory visited-module map.

### Filenames, not magic targets

aeb has *no special target source-file names*. It scans every
dot-prefixed `.ae` file under cwd (`.build.ae`, `.tests.ae`,
`.foo.ae`, `.whatever.ae`) and builds a DAG over them. The
suffix-naming convention (`.tests.ae` classifies as a test target
in summaries; `.dist.ae` as a packaging target; `.{name}.jar.ae`
etc. as third-party-dep declarations) is just a classification layer
on top of "any dot-prefixed `.ae` file under cwd is a node in the
graph." Default classification when no suffix matches is `build`.

A repo wanting `.foo.ae` and `.bar.ae` as siblings gets them — same
syntax, same DAG semantics. The `.build-<tag>.ae` /
`.tests-<tag>.ae` / `.dist-<tag>.ae` shapes extend the suffix family
without changing the "any dot-prefixed `.ae` file is a target" rule.
Multiple build files in the same directory get distinct DAG nodes
via a `:tag` suffix on their visited-set key (preserved in
human-display labels, stripped before deriving filesystem paths).

### Named target sets (`.presubmit.ae`) — a convention, not a feature

A dot-prefixed `.ae` file whose body is nothing but `build.dep(...)` lines
is a **named set of targets**; `aeb .presubmit.ae` builds the set. This
needed no engine change — it falls out of three rules already in force:
any dot-prefixed `.ae` is a node, `build.dep()` is a runtime no-op whose
edges are extracted textually, and the filename is the route (so
`.presubmit.ae` self-classifies as type `presubmit` and routes to
`target/presubmit/` with no classification-table entry). A node with no
builder does no work of its own; its edges ARE its contribution.

The name is not privileged — `.merge-queue.ae`, `.smoke.ae`,
`.nightly.ae` behave identically, and sets may depend on sets (visited-set
dedup means shared members build once). **Do not special-case the name in
the runner**; if `.presubmit.ae` ever behaves differently from
`.nightly.ae`, the convention is broken.

A set's body may also carry `meta.desc(b, "...")` (says what the set is
for; `lib/meta` is orthogonal to building, so it works unchanged on a
node that produces no artifact) and — where a gate genuinely belongs to
the set rather than to any member — an inline guard failed via
`build.fail`. The rule of thumb: **a set's own body should only ever say
no.** If it makes something, it is a build target, not a set.

**Guards: reproducible only.** A guard is fine when what it asserts is
stable and repo-independent (a tool the whole set needs is missing). It
is NOT fine when its answer depends on the developer's incidental
workspace state — a `git status --porcelain` check is the canonical
mistake: it was wrong against the first repo it ever ran in (aeb's own
`target/` dirtied the tree) and it is red most often when it is least
informative, which trains people to ignore red gates. That belongs in a
pre-push hook, not a set. Write probes with `os.system` (returns the exit
code), **not** `os.exec` — `os.exec`'s second return is an execution
error, not a non-zero exit status, so `if string.length(err) > 0` never
fires for a command that runs and exits 1. Same silent-green family as
the `_ =` trap; both are pinned by round 4 of the itest.

Verified end-to-end by `itests/presubmit-smoke.sh` (members run,
aggregator topo-sorts last, self-classification, green→0, red→non-zero
with per-member attribution, plus `meta.desc` + an inline
`git status --porcelain` guard passing clean / failing dirty). The one
trap: a set is only as honest as its members — a hand-rolled node doing
`_ = os.system(...)` discards the exit code and reports success
regardless, so a set depending on it can report green while proving
nothing. Prefer an SDK builder.

**Don't ship a `git() { no_untracked_files() }` grammar** — asked and
declined. `os.exec` + `build.fail` already compose; the check is
non-reproducible (it passes in clean CI, fails for anyone holding a
scratch file); and a `git` builder would be the first place aeb hardcodes
one VCS when root discovery already honours `.avn`/`.hg`/`.svn`/`.bzr`/
Fossil/Pijul. Policy gates (approval, attestation, external status) have
a home in `lib/approval`. Full write-up:
`docs/presubmit-target-sets.md`.

### Entrypoint: `aeb(cap)` (or legacy `main()`)

A build node's entrypoint is `aeb(cap) { b = build.start() ... }`. `cap`
is the build context/capability handle the trusted aeb host injects — the
build *receives* its authority, it does not construct it (this is the same
handle that backs `--sandbox`; see docs/capability-entrypoint.md). aeb's
`transform-ae` lowers `aeb(cap)` and the legacy `main()` to the same
context-receiving function, so both work; `aeb(cap)` is the current
convention. Don't migrate a regular Aether *program* (a `*_test.ae`, a CLI
`main.ae`) — only dot-prefixed build *nodes* take `aeb(cap)`.

### Addressing a target on the CLI

- `aeb path/to/.name.ae` — the primary form (a real file path).
- `aeb <a> <b> <c>` — multiple positional targets: each is seeded into the
  SAME DAG (BFS from all of them, deps deduped by a shared visited set), so
  one invocation builds every named target plus their transitive deps, topo-
  sorted together. Independent nodes still run concurrently under the driver.
  This is plain-build-mode only — a modal flag (`--graph`, `--since`, a query
  subcommand, `--preflight`) consumes exactly one target directive and treats
  later args as the flag's own arguments, not more targets. (Multi-target was
  once silently dropped — only the first built — see the ask
  `asks/aeb-multi-target-and-failure-exit-code-bugs.md`; fixed in aeb-main's
  arg parse + BFS seeding.)
- `aeb path/to:name` (or bare `:name` in the cwd) — synonym sugar; resolves
  to `path/to/.name.ae` and echoes `aeb synonym match: <path>`.
- `aeb --scan '<glob>'` — scan mode: build every node whose basename matches
  (glob required; bare `aeb` with no target/scan is an error).
- A bare `aeb` (no target, no `--scan`) does NOT build the whole tree — it's
  an error. Scoping is always explicit.

### How the DAG is actually drawn

`build.dep(b, "path/to/.foo.ae")` is the only edge-declaration
mechanism. Each call inside a `.build.ae`/`.tests.ae`/`.dist.ae`
adds one edge from the calling file to the named file.
`tools/extract-deps.ae` greps for these calls statically (a regex
pass, no Aether evaluation required) — the same shape as Bazel's
`BUILD` files where dep relationships are visible to text tools, not
hidden behind macro expansion. Three points worth knowing:

1. **Edges are file-to-file, not module-to-module.** Two
   `.build*.ae` in the same directory are distinct nodes via the
   tag-disambiguation rule above. `dep("foo/.build-seed.ae")` is a
   different edge from `dep("foo/.build.ae")`.
2. **No reverse edges, no fan-out queries.** The DAG is constructed
   top-down from the target inwards, like a recursive-descent
   walk. "Who depends on X" requires a separate scan of the entire
   tree (the `gcheckout` walker is an example of doing this for
   sparse-checkout purposes).
3. **`build.dep()` is a runtime no-op.** It does nothing at execution
   time; the DAG is built entirely from textual extraction *before*
   any `.ae` file runs. Like `BUILD` rules, deps are data, not
   procedure.

## How to anchor aeb against build systems you already know

Think of it as: **Bazel's DAG shape + a per-language SDK pattern
(more like Buck) + Aether closures as the configuration DSL.**

**Directed-graph style, like Bazel — more so than depth-first-recursive
like Maven.** Maven's reactor traverses `<modules>` depth-first and
walks each module through its lifecycle (validate → compile → test →
package → install) before moving on; one module's `package` happens
before the next module's `compile` even if there's no dep edge.
aeb scans the whole tree first, builds a directed graph from
`build.dep("path/to/.build.ae")` edges (greppable, statically
extractable, like Bazel BUILD files), topo-sorts, and produces every
artifact in dependency order. Modules with no edge between them
have no implied ordering — and independent nodes DO build
concurrently: `tools/aeb-driver.ae` emits a Makefile from the DAG
(one target per node, dep edges as prerequisites) and runs
`make -jN` (N = `nproc`, override with `AEB_JOBS`; `-k` keeps going
past a failure). `AEB_JOBS=1` or a missing `make` falls back to the
sequential loop. (Parallelism is across NODES — each node is a whole
toolchain invocation — not within a node; that's the orchestrator's
correct grain. An older note here called parallelism "a TODO"; it
shipped — verify in aeb-driver.ae before repeating that claim.)

- **NOT Make/CMake** — no targets-as-rules, no shell-scriptlets in
  build files. Each `.build.ae` is an Aether program with a `main()`
  that calls `build.start()` then a language SDK builder.
- **NOT Bazel** — no rule definitions, no Skylark, no remote
  execution. Closer to Buck's "languages have opinionated SDKs" but
  the SDK is hand-written Aether under `lib/<lang>/module.ae`, not
  starlark.
- **NOT Maven/Gradle** — but it can read `aether.toml [[bin]]` for
  Aether targets (the shell-out path), and `lib/maven/` resolves
  Maven coordinates against `~/.m2` for Java targets. Maven config
  still travels in `pom.xml` for projects that have it; aeb's
  Java SDK doesn't try to replace Maven's resolver.
- **NOT Nix** — and the overlap is shallower than it looks. Nix is
  whole-system: it packages a derivation closure (compiler, libc,
  every transitive dep) and is hermetic by construction (sandbox,
  content-addressed store, reproducible bit-for-bit). aeb operates
  inside an already-cloned repo, uses whatever's on `PATH`, and has
  per-module mtime caching. Nix's value comes from the closure;
  aeb's comes from the per-module DSL ergonomics. Could aeb emit
  Nix derivations from `.build.ae` files in the future? Mechanically
  yes — `.build.ae` is already the declarative description Nix
  would need. Practically: nobody's done it, and the value-add
  over "use Nix directly with Nix's own language" is unclear.
  The natural shape if it ever happens is an `aeb-to-nix`
  exporter, not re-architecting the runtime around the Nix store.
- **DSL shape is closure-with-setters** — same idiom as Aether's
  `actor { state ... receive { ... } }` blocks:
  `aether.program(b) { source("main.ae") output("hello") regen("...") }`.
  Setters are plain functions that take an invisible `_ctx` first
  arg; aeb reads the populated map after the block runs.

### Scope coverage — honest scoring

What modern build systems claim, and how aeb measures up today.
"Scope" here means the dimension that system most prizes; "aeb
status" is the unembellished current state, not the roadmap.

| Dimension                          | What "good" looks like                                          | aeb status                                                                                              |
|------------------------------------|-----------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| Build-graph topology               | Real DAG, statically extractable, greppable                     | ✓ Done. File-based DAG via `build.dep("path/.build.ae")` lines, scanned without compilation.            |
| Multi-language polyglot            | First-class for >=5 languages, real cross-language deps         | ✓ Done. 20+ SDKs (Java, Kotlin, Go, Rust, TS, Scala, Clojure, .NET, Python, Dart, MoonBit, Gleam, Ruby, Aether, Bash, Container, …).   |
| Cross-language FFI artifacts       | JNI / cdylib / shared-library handoff between SDKs              | ✓ Done. Java→Rust (JNI), Java→Kotlin, Java→Go (.so), TS→Go, C#→Rust, Python→Rust (ctypes) all wired.    |
| Local incremental cache            | Skip work when inputs unchanged                                 | ✓ Content-addressed cache (`lib/cache`, sha256+zlib) wired into every artifact-producing SDK: maven, aether, java, kotlin, scala, ts, dotnet, go, rust, clojure. `lib/python` is n/a by design (venv non-portable). Shared helpers in `lib/build`; per-SDK `_cache_key_for_*` tested by `tests/test_*_cache.ae`. Remote cache still TODO. |
| Remote build cache                 | Share artifacts across machines (Bazel, Gradle, Turborepo)      | ✗ TODO. Roadmap entry; `target/<module>/` artifact metadata files are the natural cache units.         |
| Affected-target detection          | `git diff` → reverse-dep walk → only-build-changed              | ✓ Done. `aeb --since <ref>` builds only targets impacted by changes; `aeb --print-affected <ref>` lists them. Source-to-target ownership: nearest enclosing dir with a build file. |
| Hermetic toolchains                | Pinned compiler/runtime per build, downloaded if missing        | ✗ Uses whatever's on `PATH` (selects, never provisions). Deliberate divergence — see `docs/aeb-vs-bazel.md` (hermeticity tier) + `docs/toolchain-selection-and-locks.md`. |
| Dependency resolution (transitive) | Maven / npm / Cargo / NuGet closures resolved + classpath built | ✓ Done for Maven (via `tools/aeb-resolve.jar`), npm (pnpm), NuGet, Cargo, Python wheels.                 |
| Lockfiles for reproducibility      | Pin every transitive dep to exact version + hash                | ✗ TODO. Resolver computes the closure but doesn't write/check a lockfile.                                |
| Test orchestration                 | Discover, run, report, parallelise, isolate                     | ◐ Partial. `bash.test` (jobs/pre/post hooks), `*.junit5` etc. exist; per-target pass/fail counts feed `[telemetry]` block (`14/14 PASS` / `28/30 FAIL`). Structured XML reports TODO. |
| Artifact publishing                | Push to npm / Maven Central / NuGet feed / OCI registry         | ✗ TODO. `shade()` builds fat jars; no `.dist`-side publish step yet.                                    |
| Build graph visualisation          | DOT / Mermaid / interactive graph                               | ✓ Done. `aeb --graph` (DOT) / `aeb --graph mermaid`. Pipe to `dot -Tsvg` or paste into a Markdown fence. |
| IDE / LSP integration              | Editor knows about build targets, jump-to-source                | ✗ TODO. No `aeb-lsp` yet; `.build.ae` files use the Aether LSP for syntax only.                          |
| Watch mode                         | Rebuild on file change                                          | ✓ Done. `aeb --watch [target]` watches source dirs (Linux: inotifywait, macOS: fswatch); change events flow through the affected-target walk and a narrowed rebuild fires. Composes with cache + telemetry. |
| Sandboxing / isolation             | Build steps see only declared inputs                            | ✓ `aeb --sandbox` runs the build under Aether `spawn_sandboxed` (LD_PRELOAD, deny-by-default grants, no tcp; whole subtree contained at the libc boundary). Plus `aeb --vet` static supply-chain veto (AST + external-tool + agent-side rules). See docs/build-veto-and-sandbox.md. (Linux; needs aether >= 0.230.0.) |
| Supply-chain build veto            | Treat the build script + tree as an untrusted surface           | ✓ `aeb --vet [--veto-policy <f>]` (AST deny-rules + coordinate allowlist), `--vet-tool '<cmd>'` (bring-your-own SAST), agent-side Tier-A rules (secrets, binding.gyp, pre/postinstall, curl\|sh, tree-size cap). Out-of-tree operator policy; fail-closed. |
| Sparse checkout for monorepos      | Fetch only the modules a target needs                           | ✓ Done via `aeb gcheckout` (DAG walk → `git sparse-checkout`).                                          |
| Configuration DSL ceiling          | Expressive without escape hatches into bash/python/Skylark      | ✓ Closure-with-setters, fully Aether-native, no eval'd config.                                          |
| Migration story                    | Add to existing repo without big-bang rewrite                   | ✓ Per-module `.build.ae`, coexists with whatever's there. itests prove this against real repos.        |
| Cross-compilation                  | Build for non-host OS/arch                                      | ✗ TODO. Roadmap.                                                                                         |
| Build telemetry                    | Per-module timing, cache hit rates, bottleneck analysis         | ◐ Partial. Per-module wall-time + cache outcome as `[telemetry]` block at end of every build (in-memory records, stdout renderer). Failed nodes render `FAILED` on their row and are named in a roll-up after `total:` (issue #13 — before that a gcc/link failure rendered the *identical* line a success renders, so `aeb \| tail` read green while no binary existed). Future renderers (file dump, web view) plug in via `build.render_telemetry` and the records list. |
| CI system integration              | Auto-detects GHA/GitLab/Jenkins, sets outputs, tags artifacts   | ✗ Deliberately CI-agnostic today; "is this CI" detection is a roadmap line item.                        |

Overall pattern: **graph, multi-language, and dependency resolution
are solid** (the load-bearing axes for "is this a real build system").
**Caching, publishing, IDE, and observability are the cluster of
weaknesses** that distinguish a young tool from a mature one. aeb is
~6 months in and maintained by one human and a sequence of session-
scoped LLMs; the gaps are honest, not hidden.

## How `aeb` actually works

Runtime flow (one `aeb` invocation):

1. **Bash trampoline** (`./aeb`, ~635 lines) sets `AETHER`, `AEB_HOME`,
   `ROOT`, optional `DOCKER_HOST` for podman. Routes `--init` /
   `gcheckout` / `--version` to subcommand-specific binaries; falls
   through to `tools/aeb-main` for normal builds.
2. **`tools/aeb-main`** parses args, walks the tree via
   `tools/scan-ae-files`, picks targets (specific path or every
   `.*.ae` under cwd), then exec's `tools/aeb-link`.
3. **`tools/aeb-link`** is the heavy lifting per-build: per-file
   `transform-ae` (rewrites user `.ae` to embed the orchestrator's
   visited-set guard), `aetherc src.ae src.c` per file,
   `gen-orchestrator` to emit one driver `.ae` calling each
   module fn, then **one `gcc`** linking everything into
   `target/_ae_build_all`. That single binary takes a `<label>`
   selector arg — `_ae_build_all <root> <label>` runs *just that one
   node* (its module fn + that fn's transitive deps, deduped by the
   visited-set guard).
4. **`tools/aeb-driver`** schedules the nodes: it reads the edges
   file and, by default, emits a Makefile (one target per node, each
   recipe = `_ae_build_all <root> <label>`, dep edges as
   prerequisites) and runs `make -jN`, so independent nodes run as
   **parallel subprocesses**, each writing a `.rc` marker the driver
   collects for the final `[telemetry]` render. `AEB_JOBS=1` or no
   `make` → a sequential loop calling the same binary per label.
   Within a node, module functions are `static` per TU and the
   visited map dedups multi-imported modules.

   **Two status vocabularies, both live.** The driver writes records with
   `status` = `"pass"` / `"fail"` / `"skipped"` (the words it also emits in
   the telemetry JSON), while the in-process orchestrator writes
   `"passed"` / `"failed"` (the words `build.status_of` returns). Anything
   reading a record's `status` must accept both — `build._status_is_failed`
   and `build._telemetry_status` exist for exactly that reason. Matching
   only one silently under-reports on whichever path loses.

The trampoline lazy-builds tools at first use (cached in `tools/*`
binaries, gitignored). `make install` pre-builds them and copies the
runtime tree to `$PREFIX/share/aeb/`, with a wrapper at
`$PREFIX/bin/aeb` that pins `AEB_HOME`.

## Files/dirs worth knowing

- `aeb` — bash trampoline. ~635 lines (env setup, the full flag grammar,
  lazy-build dispatch, and the build-supervision tail). Read it first if
  anything about trampoline behaviour confuses you. (A native Aether port
  is hedged — see TODO.md § "Full Aether CLI entrypoint" +
  `../aether/aeb-process-supervision-primitives.md`.)

  **The supervision tail is more complete than "process group + timeout"
  suggests, and it is verified.** The whole build runs as one backgrounded
  job that `set -m` puts in its own process group; INT/TERM are forwarded
  to the group; the group is reaped unconditionally afterwards (TERM →
  10×100ms grace → KILL), so a step that leaks a backgrounded server does
  not outlive the build. `--timeout N` / `AEB_TIMEOUT=N` adds a watchdog
  (TERM, 5s, KILL) reporting the coreutils-conventional exit 124.
  Measured against a fixture that leaks a background grandchild: Ctrl-C →
  exit **130**, grandchild killed, 0 survivors; `--timeout 8` → exit
  **124**, grandchild killed, 0 survivors. Don't re-litigate "does aeb
  clean up on Ctrl-C" — it does, including grandchildren.

  **Known gap: `--timeout` is whole-build only.** One slow node can eat
  the budget and every other node dies with it, with no indication of the
  culprit. Per-node caps are unbuilt (nothing in `tools/aeb-driver.ae`;
  the `timeout(300)` in TODO.md's DSL sketch is an illustrative junit
  setter, not a shipped feature). See
  `asks/halting-guarantees-and-build-termination.md`.

  **Don't make the config language non-Turing-complete** — asked and
  declined, same ask doc. The Starlark-style "prove the config halts" bet
  targets the wrong layer: `build.dep()` is a runtime no-op and the DAG is
  extracted textually, so config evaluation is already ~straight-line and
  finishes in microseconds. Builds hang in `os.system("mvn ...")`, across
  a fork/exec boundary no totality checker reaches. aeb bounds termination
  *dynamically* instead, which is strictly stronger here because it also
  bounds the opaque toolchain child — and it would cost the
  `docs/inline-build-steps.md` escape hatch that the configuration-DSL-
  ceiling ✓ depends on.
- `tools/aeb-link.ae` — the per-build orchestration. THE largest
  Aether file. If a build fails between scan and link, the bug is
  here.
- `tools/aeb-graph.ae` — `aeb --graph` renderer. Reads
  `target/_aeb/_edges.txt` and emits DOT (default) or Mermaid.
  Pure-render: no I/O beyond reading the edges file. Pattern model
  for future render-from-edges tools (e.g. telemetry).
- `lib/meta/module.ae` — distribution metadata SDK. Setters
  (`desc`, `homepage`, `license`, `version`, `url`, `sha256`,
  `maintainer`) record into the build map on `b`; orthogonal to
  building. Source-of-truth for downstream exporters.
- `lib/brew/module.ae` — Homebrew exporter SDK. `brew.formula(b)`
  closure in a `.dist.ae` reads `meta.*` plus its own setters
  (`aeb_target`, `binary`, `class_name`, `test_assertion`) and
  writes `target/<module>/<binary>.rb`. Pattern model for future
  exporter SDKs (`nix.derivation`, `deb.control`): each is just
  another `builder` that consumes the shared `meta` map. **No
  CLI flag** — distribution is a target type, not a switch.
- `tools/aeblabel/module.ae` — the single canonical implementation
  of build-file label/tag derivation (`file_to_label`, `extract_tag`,
  `infer_type`, `dirname_pure`, `basename_pure`) that disambiguates
  multiple `.build*.ae` per directory. `tools/file-to-label.ae` (a
  thin CLI), `tools/gen-orchestrator.ae` and `tools/aeb-link.ae` all
  `import aeblabel`; `tests/test_file_to_label.ae` imports the same
  module, so the test exercises the real build-path code. Tool
  builds pass `--lib tools` (Makefile `AEFLAGS`, plus the lazy-build
  commands in `aeb-main`/`aeb-link`) so the import resolves. This was
  three drifting copies until the multi-`--lib` (aether 0.150)
  consolidation — see `TODO.md` § Three-copy `file_to_label`.
- `lib/build/module.ae` — the core API: `build.start()`,
  `build.begin()`, `build.dep()`, `build._get()`, artifact helpers.
  Every language SDK depends on this. Also hosts shared **fixture
  synthesis** (`_synth_fixture_pre`, `_synth_fixture_post`,
  `_has_fixtures`) — test SDKs that need spawn/seed/cleanup
  lifecycle (today: `bash.test`, future: `aether.driver_test`)
  populate `fixture_seeds` / `fixture_servers` records on their
  builder map and call these helpers to lower them into shell
  statements. The shell-quoting traps are nontrivial — read the
  docstrings before adding a new caller.
- `lib/<lang>/module.ae` — language SDKs. Java, Kotlin, Go, Rust,
  TypeScript, Scala, Clojure, .NET, Python, Aether (native programs),
  Bash (test runner — note the builder is `bash.run`, not
  `bash.script`: a builder must not share a name with a function in
  its module — both mangle to `<module>_<name>` and collide. As of
  **aether 0.178.0 this is a compile error** (`duplicate definition
  of '<name>': a builder and a function cannot share a name`), so the
  rule is now enforced, not just a convention to remember. It used to
  silently dispatch to one of them: `lib/ruby`'s `gem` setter vs a
  former `gem` builder collided this way and the builder was renamed
  to `package`; under 0.178+ that collision would have failed the
  build immediately), Maven (resolver), pnpm/jest/webpack/angular,
  Container (OCI/LXC). Each SDK exposes `<lang>.<verb>(b) { ... }`
  builders.
- `lib/webhook/module.ae` — outbound webhook trigger SDK (core, not
  language-specific). `webhook.fire(b) { url(...) on(...) }` invokes
  a URL when a pipeline node is reached — aeb as the producer side
  of a webhook-centric automation system. `{{...}}` context
  interpolation, `on()` environment gates, native `std.http`. Hosts
  the `_detect_ci()` consumer; `_detect_ci` itself lives in
  `lib/build`. Usage: `docs/webhook-triggers.md`; design:
  `asks/webhook-outbound-trigger.md`.
- `lib/container/module.ae` — container SDK. `container.image` builds
  OCI images; `container.run(b) { image_ref(...) command(...) }` runs
  a one-shot container and RETURNS its captured pid-1 stdout — the
  first slice of a container-as-step grammar. aeb's two ways to run a
  guest language — `container.run` (a separate process) vs Aether's
  in-process `contrib.host.<lang>` hosting — and the isolation/cost
  tradeoff between them are written up in `docs/guest-languages.md`.
  In-process hosting from a `.build.ae` is not wired yet: `aeb-link`
  would need to link the `contrib.host.<lang>` C bridge into the
  orchestrator (the `tests/test_host_lua.build.sh` sidecar does this
  for the test).
- `lib/aether/module.ae` — the Aether-program SDK.
  `aether.program(b)` shells out to `ae build` by default; declaring
  `extra_source(...)` / `link_flag(...)` / `regen(...)` opts into the
  manual `aetherc + gcc` path. Also hosts `aether.program_test` (a
  compiled-binary unit test), `aether.driver_test` (a compiled
  driver binary that exercises a *separate* binary-under-test, with
  the same fixture grammar as `bash.test`), and `aether.csrc` (a
  distributable C-SOURCE package via `ae build --emit=csrc`, aether
  0.357: `<name>.c` + `<name>.h` catalog header, no gcc/.so;
  publishes `c_source`/`c_header`/`c_header_dirs`/
  `c_needs_aether_runtime` so `c.program` consumes it without
  special-casing; setters `source`/`output`/`caps`). Driver tests
  work with `std.spec` (the aeocha successor; see the driver_test
  report-transport note below) or anything that uses exit code as
  PASS/FAIL.
- `lib/bash/module.ae` — bash test runner. `bash.test(b)` with
  `script(...)`, `jobs(N)`, `pre_command(...)`, `post_command(...)`,
  and structured server fixtures (`fixture_seed`, `fixture_server`).
  Parallel mode via `xargs -P` (jobs(0) = nproc/2). Hooks AND
  fixtures force sequential.
- `tests/` — string-builder unit tests, one `test_*.ae` per
  command-string-builder. Each asserts the exact string passed to
  exec. Run with `./tests/run.sh` (pattern arg filters).
- `itests/` — integration tests against real-world projects (Spring
  Boot, Angular, .NET eShop, Rust workspaces, etc.). Upstream
  sources fetched via `itests/fetch-upstream.sh`, not committed.
  **Partially passing — see `itests/README.md` for the status
  table.** Headline numbers: spring-data-examples is 68+/90 modules
  compiling, the Rust projects fail (RocksDB C++ build issue,
  upstream crate incompatibility with current rustc). Don't treat
  itests as "all green = ship it"; treat them as "real-world
  scaffolding for ongoing SDK development." Several have
  `AEB_MIGRATION_STATUS.md` files with per-project gap notes.
- `asks/` — feature-request docs, one per ask. Format isn't
  prescribed; recent ones happen to be from a downstream port but
  the directory is general-purpose. Each ask doc captures
  motivation, sketch, what's-not-being-asked, acceptance criteria.
  Ship-or-decline decisions live in commit messages alongside the
  implementation (or absence thereof).
- `TODO.md` — roadmap + known gaps. Section "Test coverage gaps"
  documents two deferred items (regen pass integration, parallel +
  hooks); the third — three-copy `file_to_label` — is now resolved
  by the `tools/aeblabel` consolidation.
- `Makefile` — `make build` (pre-build tools), `make install`
  (proper copy install to `$PREFIX/share/aeb` + wrapper),
  `make uninstall`, `make clean`.

## Idioms that keep biting

- **Build scripts can share a source module across directories via a
  root-relative dotted import.** A `.build.ae` in one dir can import an
  Aether source module living in another dir by naming it as a path from
  the repo root: `import gen.genengine` resolves
  `<reporoot>/gen/genengine/module.ae` (flat `gen/genengine.ae` works
  too), called namespaced by the LAST segment: `genengine.generate()`.
  This works from ANY invocation dir (incl. a subdir), because
  `tools/aeb-link.ae` discovers the project root (`_discover_repo_root`)
  and appends it to the aetherc `--lib` path for the per-file +
  orchestrator compiles (`compile_lib = <aeb_lib>:<repo_root>`). Discovery
  is two-pass and preference-ordered: an `.aeb` marker wins regardless of
  depth (walk the whole way up for `.aeb` first, so an aeb project root
  out-anchors a deeper VCS marker like a nested git submodule); failing
  that, the nearest VCS/working-copy marker (`.avn`, `.git`, `.hg`,
  `.svn`, `.bzr`, Fossil, Pijul). If NO marker is found anywhere up the
  tree, discovery returns "" and aeb adds NOTHING to `--lib` — cwd is
  already an implicit aetherc search root so same-dir imports still work,
  and there's no principled root to widen cross-dir resolution to. Why it needs help: aetherc
  resolves imports against its search roots (cwd + `--lib`), NOT the
  input file's own dir — and aeb compiles a relocated copy under
  `target/_aeb/`, so the script's authored location is never a search
  root. Two gotchas inherited from Aether's module model: (a) a *bare*
  `import foo` only reaches a `foo` reachable from a search root — it
  does NOT walk to a sibling dir on its own; express cross-dir shares as
  the dotted path from the repo root. (b) Whole-module `import x.y` →
  call `y.fn()` (namespaced by last segment); `import x.y (fn)` →
  call `fn()` (bare). Mismatching the two is `E0301`, not a bug. The
  shared module is a normal Aether source module, not an aeb SDK — no
  `.aeb/lib` symlink, no `--init` registration. Came from
  `asks/sibling-imports-in-build-scripts.md` (mquickjs's two codegen
  scripts sharing one generator engine).
- **Aether is fixed-arity — but NOT no-default-args.** Setters that
  "want" *variadic* args (`extra_sources("a", "b", "c")` — genuinely
  variable count — won't compile) are still repeated single-arg calls
  (`extra_source("a"); extra_source("b"); ...`; same for `script(...)`,
  `regen(...)`, `pre_command(...)`, `link_flag(...)`; each appends to a
  list in the builder map). **The overstatement to retire:** a function
  CAN take an OPTIONAL trailing argument via a default value, and it
  resolves correctly through **UFCS method-call chaining** — verified
  and now shipped in aether #1576/0.543 (`std.spec`'s fluent matchers
  gained an optional `msg`: `expect_int(x).to_equal(y, "why it matters")`
  with the no-msg form byte-identical). So "add an optional param" is a
  real alternative to a doubled `*_variant` or a breaking required-arg
  sweep — the trade-off #1576 chose. aeb itself doesn't use the fluent
  surface (never has), but SDK-setter design here previously cited
  fixed-arity to justify never adding optional args; that justification
  is gone. Genuine variable-COUNT still needs the repeat-call idiom.
- **`_builder` is magic, only in scope inside `builder { ... }`
  bodies.** Plain helpers can't see it. Pass through as
  `builder_map: ptr` parameter from the call site. See
  `_compile_and_link` in `lib/aether/module.ae` for the pattern.
- **The two-`import` requirement for bare setters.** Inside a
  `receiver.method(b) { block }` body, identifiers in `block` are
  resolved as plain top-level calls, not against the receiver's
  namespace. So `bash.test(b) { script("...") }` won't find
  `script` unless `import bash (script)` is also at the top of the
  file. Same for every SDK. Documented in README's "note on the
  two import lines" callout. Real bug filed and pushed back as
  not-a-bug — `asks/aether-program-bare-setters-bug.md`.
- **`${...}` interpolation eats bash parameter expansions.**
  Aether's string interpolation grabs `${...}` at parse time, so
  embedding a literal `${1%%|*}` in a string literal silently
  fails to make it to the file. Workaround: build the string via
  `string.concat` with `$` and `{` separated. See
  `bash_runner_body()` in `lib/bash/module.ae` for the pattern.
- **`path.join` is naive.** `path.join("/foo", "/abs/x.c")` returns
  `/foo//abs/x.c`, not `/abs/x.c`. Aether's `path.join` doesn't
  honour the python-shaped "absolute-right-wins" rule. To
  conditionally resolve relative-vs-absolute, gate on a leading-`/`
  check first. See `extra_source`'s consumption loop in
  `lib/aether/module.ae`.
- **`file.exists` vs `dir.exists` vs `fs.exists`.** `file.exists`
  returns 0 for directories. `dir.exists` returns 0 for files.
  `fs.exists` is path-agnostic. Most aeb code uses `dir.exists`
  for directory probes, `fs.exists` for file/dir agnostic checks.
  Got bitten once during this session; documented in README.
- **`os.system` returns the POSIX exit code directly** (not the
  wait-status word). Don't shift right by 8.
- **`continue` is not a keyword in Aether.** Use a `needs_X = 1`
  flag and gate the trailing block. See `_run_regen_pass` in
  `lib/aether/module.ae`.
- **Multi-return is one-call-side destructure only.** `_, b =
  list.get(l, i)` works; declaring a function `-> (string, int)`
  doesn't ergonomically chain. Use a map or split-accessor pattern
  for >1 return value.
- **`E0301 Undefined function 'x.y'` often means a failed `import`,
  not a typo.** aetherc silently tolerates an `import` that resolves
  to nothing and only errors at each *use* site. A wall of E0301
  across `target/_aeb/*.ae` after a build is almost always the SDK
  `--lib` path being wrong, not the SDK being broken. aeb resolves
  the SDK as `<root>/.aeb/lib` (the per-project `aeb --init`
  symlink), falling back to `$AEB_HOME/lib` when that is absent or a
  dangling symlink — so `aeb --init` is effectively optional now
  (`aeb-main.ae`, fix `9689862`, originally an avn-reported blocker).
  If you touch the orchestrator `--lib` handoff, an `itests/c-*` run
  is the fast check: those itests have no `.aeb/lib`, so they
  exercise the fallback path directly.
- **Two import namespaces in `aether.program_test` / `driver_test`
  (the "toolchain-module" gotcha; historically "the aeocha gotcha").**
  aeb's cache-key + regen closure resolves **project** imports
  (`import myproj.foo`) by walking the test source's own dir + ancestors
  (`_resolve_import_ae`, `lib/aether/module.ae:521`; roots from
  `_ancestor_dirs`, `:484`).
  It **deliberately returns "" for `std.*` and `contrib.*`** — `:522-524`
  — because those are **toolchain** modules: resolved by `ae build`
  itself (which knows `--lib`), and cache-tracked via the
  *toolchain-version* component of the key, not file-hashed from the
  repo tree. So the statement "aeb resolves imports from
  `source_dir`/ancestors, not from `--lib aether`" is true **only for
  project modules**; `std.spec` and the stdlib ride the toolchain side
  of the split. Two consequences a sibling trips on:
  (a) a test that `import std.spec` needs the **toolchain** to have it
  (it's stdlib as of aether 0.538 — always present; the old
  `import contrib.aeocha` + `make install-contrib` dance is retired);
  (b) aeb's ancestor-walk is *ancestor-only* — a
  project module in a true **sibling** dir (not a parent) won't be
  picked up by the cache hasher, so editing it may not bust a
  consumer's key (express cross-dir shares as a repo-root dotted path,
  per the "share a source module across directories" idiom above).
  **With or without a test framework:** `program_test`/`driver_test`
  work fine with NO `std.spec` import — plain exit code is PASS/FAIL;
  `std.spec` only *adds* the granular per-`it()` report, which aeb reads
  from the `AE_SPEC_REPORT` file (`build._parse_aeocha_report`, the
  report format is still the versioned "aeocha-v1" contract). Don't
  assume a framework is required.

## SDK extension shape

Adding a language SDK or a new builder follows a fixed pattern.
Look at `lib/bash/module.ae` for the simplest complete example.

1. **Setters** at the top — pure data accumulation into the builder
   map. One arg per call. `_ctx: ptr` is the magic first parameter.
2. **Pure command-string builders** in the middle — `*_cmd(opts) ->
   string`. These are what `tests/test_*_cmd.ae` exercise. Keep
   them I/O-free.
3. **Builder functions** at the bottom — `builder verb(ctx: ptr)`.
   Read the builder map, call the pure builders, `os.system` the
   result, write artifact metadata to `target/<module>/`.
4. **Register the module name** in `tools/aeb-init.ae`'s
   `shipped_modules()` list. `aeb --init` reads that list to
   create the `.aeb/lib/<name>` symlinks in consumer repos.
5. **Optional: ship `lib/<name>/<name>.help.md`** — authoring-mistake
   hints `ae help` surfaces (``Pattern: literal-name `setter` ``
   sections fire when `setter(` appears in a `.build.ae`). It lives
   inside the module dir, so the `.aeb/lib/<name>` symlink carries
   it for free. Only worth it for genuine footguns — a hint fires on
   every occurrence of its name, so don't key one to a name whose
   plain use is fine. See `lib/bash/bash.help.md` for the shape.

The string-builder pattern (the `*_cmd(...)` helpers) is load-bearing
for testability. Every command that gets `os.system`'d should go
through one. Inline assembly in builder bodies isn't testable in
isolation.

## Out-of-repo SDKs (consumer-local libs)

Not every SDK belongs in `lib/<name>/` here. A consumer repo that
wants domain-specific build/test grammar can ship its own SDK
in-tree at `.aeb/lib/<name>/module.ae`, tracked in that repo:

```
.gitignore:
  /.aeb/lib/*
  !/.aeb/lib/<name>/
```

`aeb --init` writes the shipped-SDK symlinks but explicitly skips
non-symlink paths it finds at `.aeb/lib/<x>/`, so a tracked
consumer SDK coexists fine.

Typical shape: the consumer SDK's setters wrap aeb's generic
primitives (especially `pre_command(...)` / `post_command(...)`
from `lib/bash`) with domain-specific lifecycle, then call into
the consumer's own bash helpers. The bash glue lives in the
consumer repo (e.g. `tests/lib.sh`), invoked via
`pre_command("source tests/lib.sh && my_fixture_helper ...")`.

Example in the wild: **svn-aether** (~/scm/subversion/subversion)
ships `.aeb/lib/svnae/module.ae` with setters like
`svn_server(NAME, PORT)` and `empty_repo_with_algos(NAME, ALGOS)`
that wrap its Subversion-server fixture lifecycle. The .tests.ae
files there read as canonical aeb DSL; the bash plumbing
(server spawn, repo seed, kill/wait) lives in `tests/lib.sh`
under the surface.

This is the pressure-relief valve for the "don't accept
domain-specific into core" rule. If a downstream's domain isn't
generic, the SDK lives in its tree, not ours. aeb's core stays
small; consumer ergonomics still ratchet up.

## Design principles when extending aeb

A handful of recurring decisions shape what gets accepted into the
core SDKs versus pushed back to user-side helper scripts. None of
these are absolute, but skipping them tends to produce regrets.

1. **Generic vs domain-specific.** aeb takes generic build/test
   orchestration. Domain-specific lifecycle (e.g. an application's
   daemon spawning, a particular database's seed format) belongs
   in the consumer's own helper scripts, sourced via `pre_command`
   or invoked from a builder. The shape "spawn a binary, set env,
   run script, kill" is generic; "spawn *aether-svnserver* with
   `--superuser-token` and export `${PRIMARY_PORT}`" is not.
2. **Closure-DSL grammar over external config.** Where the first
   instinct is "let aeb read someones-config.toml", the better
   answer is usually native setters in `.build.ae`. aeb stays out
   of TOML/YAML/JSON parsing; external formats are honoured only
   via shell-outs to tools that already parse them (e.g. `ae build`
   for `aether.toml`). See `regen(...)` / `regen_with(...)`.
   Note this principle targets *parsing external formats*, NOT
   expressiveness inside the closure DSL — don't cite it to reject a
   native-Aether feature. The bar for those is the load-bearing
   principle (file-as-truth) instead.

   **Value override / merge: setters already do it.** Scalars are
   last-write-wins (`map.put` overwrites; verified observably —
   `jobs(4)` then `jobs(1)` runs sequentially, the reverse order runs
   parallel), lists append (`list.add`). That IS merge-with-bias, spelled
   as evaluation order, and it's the *eager* (after-evaluation) form.
   If someone asks for config override: first check sequential setters
   don't already cover it (they usually do — a helper sets defaults, the
   caller overrides after); ship the eager form if a real gap remains;
   **refuse the lazy/before-evaluation (dynamic-binding) form** — its
   justification is circular references between live entities, which a
   build DAG doesn't have, and it buys an override silently changing a
   derived value somewhere unrelated. See
   `asks/merge-with-bias-and-config-override.md`.
3. **Single-arg-per-call setters.** A multi-field keyword sketch like
   `fn("name", port: 9540, timeout: 1500)` still doesn't compile — land
   it as `fn("name"); fn_port("name", 9540); fn_timeout(...)` or similar
   split-setter shapes. But note the "fixed-arity" caveat above: a
   single OPTIONAL trailing arg with a default DOES work (and resolves
   through UFCS chaining, aether #1576), so a one-off optional need not
   become a whole second setter.
4. **Pure command-string builders.** Every command that gets
   `os.system`'d should be assembled by a pure helper that takes
   inputs and returns a string, with the actual exec done by the
   builder body. Tested in isolation in `tests/test_*_cmd.ae`.
   Inline assembly in builder bodies is not testable.
5. **Two-layer verification.** String-builder tests in `tests/`
   cover the exec-string regression surface; `/tmp/aeb-*-smoke`
   end-to-end runs verify the integration. Both should pass
   before a change ships. Smokes are not committed; they're
   session-local scaffolding.
6. **Capture the trade-off in commit messages.** "Going with X,
   not Y, because Z" reads better six months later than a diff
   alone. Past commit bodies are the design archive; skim them
   when a similar question comes up.

## Branching: there isn't any

Nic and Paul commit and push **direct to `main`**. No feature branches, no
PRs, no fork-and-merge — this repo is small and the two of them are the only
committers, so a branch is pure ceremony.

If you are an assistant working here: put the commit on `main` and push it.
Do NOT helpfully create a topic branch "to be safe" — that just leaves work
stranded somewhere nobody looks.

The discipline that replaces branch review is the checklist below: the tests
are green *before* the push, not after.

## What to verify before saying "done"

- `make install` ran, runtime tree at `~/.local/share/aeb/` matches
  `lib/` and `tools/` in the dev tree (`diff -q`).
- `./tests/run.sh` is green. Currently 33/33; new SDK additions
  should grow this.
- One `/tmp/aeb-*-smoke` end-to-end run succeeded.
- README updated if the user-visible surface changed.
- Commit message captures the trade-off, not just the diff.
- `asks/<name>.md` (if any) committed alongside the implementation
  so the trail is in-tree.

## What NOT to do

- Don't add aeb-side parsers for external config formats (TOML,
  YAML, JSON manifest) when a setter would do. The `aether.toml`
  shell-out is the one exception and it delegates to `ae build`,
  which already parses it.
- Don't add domain-specific builders to generic SDKs. If three
  downstreams want the same shape, factor; until then, push back.
- Don't re-inline `file_to_label` / `extract_tag` logic into a
  tool. `tools/aeblabel/module.ae` is the one canonical copy; a tool
  that needs it does `import aeblabel (...)` and is built with
  `--lib tools`. The historical three-copy duplication is gone —
  keep it that way.
- Don't break the visited-set dedup contract. Two `.build*.ae` in
  the same dir get distinct labels via the `:tag` suffix; strip
  the tag before deriving filesystem paths but keep it in the
  human-display label.
- Don't `--no-verify` or skip hooks. There aren't pre-commit hooks
  in this repo today, but the principle stands.

## Known upstream Aether issues affecting aeb

- **macOS link step fails with duplicate symbols.** Compiler emits
  imported module functions into every TU without `static`. GNU ld
  hides this via `-Wl,--allow-multiple-definition` (currently
  hard-coded in `tools/aeb-link.ae`); macOS ld64 rejects the flag.
  Tracked in TODO.md § Aether compiler issues.
- Most other upstream gaps are documented inline in TODO.md.

Resolved upstream issues that aeb used to work around (kept here
because the workarounds left traces in commit history / older
LLM-session notes — if you see one in a diff, it's probably stale):

- ~~**0.180 heap-string aliasing regression**~~ — a
  `rest = content; … rest = string.substring(rest, …)` loop corrupted
  the original `content` heap string: the alias-move `dest = src`
  disowned `src` even when read again, so the loop's next reassignment
  freed the shared buffer. Filed as `../aether/180-regression.md`;
  broke `tools/extract-deps`'s scan pass + runtime `build.scan` when
  those tools were rebuilt under 0.180. **Fixed in aether 0.181.0**
  (commit `0dd4396`, "defensive-copy heap-string alias when source
  stays live"). aeb's toolchain bumped to 0.181.0 and the defensive
  `rest = string.concat(content, "")` copies in `tools/extract-deps`
  and `tools/scan-ae-files` were removed (back to plain `rest =
  content`). If you're on a pre-0.181.0 `ae` and rebuild those tools,
  scan will break again — bump the toolchain.
- ~~`tools/gcheckout` doesn't link~~ — was a manual `extern` block
  for stdlib symbols (the same anti-pattern aeocha hit, see
  `../aether/extern_mistake.md`). Migrated to idiomatic
  `import std.{string,file,os,list,map}` + dot-form calls. Now
  builds and is in `INSTALL_TOOLS`.
- ~~Defensive `string.concat(x, "")` copies in `gcheckout`'s
  dep-walk loop~~ — were a workaround for aether 0.147 Regression A
  (heap-string alias passed to `list.add` not escape-marked, freed
  by the next reassign-wrapper). Fixed upstream: 0.149.0 +
  0.151.0 made heap-string alias-into-`list.add` transfer ownership
  cleanly. Copies removed; `list.add(queue, dword)` is direct now.

## Recent upstream Aether features aeb could lean on

Tracked here so future sessions know what's available without
re-reading the upstream changelog. Not "must consume," just "this
exists if a need arises."

- **0.115 `#line` directives in generated C** — gcc errors now
  point at `.ae` source lines rather than post-merge C. The
  manual-path gcc invocation in `lib/aether/_compile_and_link`
  benefits automatically; nothing for aeb to do beyond knowing
  user-facing error quality has improved.
- **0.116 `@aether` per-param extern annotation** — for externs
  whose receiver is Aether-emitted (e.g. another `--emit=lib`
  module), the annotation preserves the AetherString header so
  `string.length` doesn't strlen-truncate at embedded NULs. aeb
  has zero such externs today (all our externs cross into naive
  C runtime, where the v0.98.0 auto-unwrap is correct); flagged
  in case future SDK additions cross Aether-to-Aether boundaries.
- **0.111 `make install-contrib`** — installs prebuilt static
  libs for sqlite + host bridges at `$(PREFIX)/lib/aether/`.
  aeb users can `link_flag("-laether_sqlite")` instead of pointing
  `extra_source` at the C file. aeb's existing `-L` includes that
  dir; no change needed. **As of 0.123 this also ships
  `contrib/aeocha/module.ae`** under
  `$(PREFIX)/share/aether/contrib/aeocha/` (was deleted post-copy
  in 0.111; see the 0.123 entry below).
- **0.111 `string.glob_match`** — POSIX fnmatch surface in
  stdlib. Useful if aeb grows pattern-based source discovery
  (e.g. a glob form of `extra_source(...)`); not consumed today.
- **0.111 `std.config` + `std.actors`** — process-global KV +
  actor registry. Relevant when aeb grows multi-thread or
  multi-process telemetry (Tier 1+ in TODO § telemetry vision).
- **0.115 `ae build --coverage`** — gcc instrumentation injected
  into user-program build, `.gcda` at runtime, `.ae.gcov`
  reports. **Now consumed**: `aeb --coverage` is a CLI flag (set
  by trampoline as env var `AEB_COVERAGE=1`); `lib/aether` honors
  it on both shell-out and manual paths. Cache key segregates
  coverage from non-coverage builds. Other test SDKs (jacoco,
  jest --coverage, etc.) not yet wired — tracked in TODO.
- **0.118 `contrib.aeocha` integration-shape matchers** —
  describe/it/before_each + `expect_*` matchers that absorb
  bash-shaped "spawn / capture / awk-and-compare" idioms into
  single Aether calls. Process surface (`expect_exit`,
  `expect_no_spawn_error`, `expect_stdout_contains`,
  `expect_stdout_line_field`, `expect_stdout_line_count`,
  `expect_stdout_matches`) consumes the `(stdout, exit, err)`
  triple from `os.run_capture`; HTTP surface
  (`expect_http_status` / `_no_error` / `_body_contains` /
  `_header` / `_body_json_field`) consumes a `resp: ptr` from
  `http.get` / `client.send_request`. Drivers written for
  `aether.driver_test(b)` should reach for these by default —
  they're what the porter's ask was anticipating.
- **0.123 `expect_stdout_line_field` tokenises on whitespace
  runs (awk semantics)** — was single-space splits, broke against
  column-aligned output like `Revision:    3`. Now indexes 0-based
  on non-whitespace spans regardless of padding. Also new:
  **`expect_stdout_line_after`** for "value after a `Key:` line"
  with embedded spaces (svn/git-style log-line idiom).
- **0.123 closure-extern-ordering fix in aetherc codegen** —
  closure bodies that called imported externs (e.g.
  `callback { argv = list.new() }` where `list_new` is `extern`'d
  in `contrib.aeocha`) emitted into the generated C *before* the
  imported-module extern prototypes, so gcc rejected with
  "conflicting types for 'list_new'". Fix hoists extern emission
  before closure discovery. Workaround for ae < 0.123 (wrap the
  extern call in a local helper) is no longer needed.
- **0.124 `std.ipc` + `os.run_pipe*` — child-to-parent IPC
  back-channel**. Parent uses `os.run_pipe(prog, argv, env)` (or
  the deadlock-free convenience
  `os.run_pipe_drain_and_wait(prog, argv, env) -> (payload,
  exit_code, err)`) to spawn a child with an inherited pipe at
  fd 3 (env var `AETHER_IPC_FD` carries the number, so the
  contract isn't the literal 3). Child uses
  `ipc.parent_channel() -> int` to get the fd, writes via
  `ipc.write_close(fd, bytes)`. POSIX-only; Windows returns
  "unsupported." Three rounds of design discussion led to the v1
  surface; the four-doc dialogue retired from `asks/` after the
  feature shipped. **Now consumed**: `aether.driver_test` uses
  `os.run_pipe_drain_and_wait` to spawn the driver and read a
  structured per-it() report from the back-channel.
- **0.124+ `contrib.aeocha` emits structured per-it() report
  through the back-channel** — when invoked under a parent that
  opened an IPC channel, `aeocha.run_summary` writes a `version=1`
  KV-header report (`total/passed/failed/errored/duration_ms`) +
  `---` + tab-packed per-it() rows before exit. Gated on
  `parent_channel() >= 0`, so `ae run foo.ae` directly is
  unchanged. **Now consumed**: aeb parses the header in
  `lib/aether/driver_test` (via `build._parse_aeocha_report`)
  and reports real granularity in the `[telemetry]` block —
  e.g. `2/3 FAIL` instead of binary-level `0/1 FAIL`. Hand-rolled
  drivers (no Aeocha) emit no report; aeb falls back to
  exit-code mapping (`0 → 1/0`, non-zero → `0/1`).
  **SUPERSEDED (0.538 / aeb `009c830`):** aeocha is retired, absorbed
  into `std.spec` (stdlib). The report now travels via a FILE, not the
  IPC pipe — `driver_test` sets `AE_SPEC_FORMAT=aeocha AE_SPEC_REPORT=<f>`
  on the child and reads `<f>` when the pipe drains empty. Same
  `version=1` "aeocha-v1" format (now a versioned contract in aether
  `docs/testing.md`), so `build._parse_aeocha_report` is unchanged. The
  pipe read stays as a back-compat branch for any old-aeocha child. The
  IPC-back-channel entry above is kept as the historical record of how
  it worked 0.124–0.537.
- **0.146 `@heap` on single-value extern returns** —
  `extern foo(...) -> string @heap` opts a malloc'd-buffer-returning
  extern into the heap-string tracker so the caller's free fires.
  aeb has no such externs today (every SDK shells out via
  `os.system`); flagged for future SDK work that binds a C library
  directly.
- **0.147–0.161 heap-string ownership hardening** — a long run of
  aetherc codegen fixes to the heap-string lifetime tracker (alias
  ownership transfer, return-escape, cross-fn recursion,
  interp-as-arg, `bytes.finish` return-value leak). Net effect for
  aeb: the `string.concat` accumulator loops across the SDKs (e.g.
  `bash_runner_body`, `_csv_split`, fixture-line emission) are
  reclaimed correctly and no longer UAF or leak. aeb's two filed
  0.147 regressions (A and B) are closed — see TODO.md § Aether
  compiler issues. Nothing to consume; rebuilding under 0.161 just
  gets correct memory behaviour.
- **0.150 `ae help <script>` + post-0.162 `--lib` support** — offline
  closure-DSL diagnostics: Levenshtein typo matches, YAML/HCL→call-form
  rewrites, missing-import detection, plus library-author hint files.
  A library ships a `<name>.help.md` next to its `module.ae` whose
  ``Pattern: literal-name `name` `` sections fire when `name(` appears
  in a script. The 0.150 release was stdlib-only; the `--lib` fix
  (aether `[current]`, filed by aeb via
  `../aether/aeb-ae-help-and-toolchain-feedback.md`) made `ae help`
  accept `--lib` and probe `--lib` roots for hint files. **Now
  consumed**: aeb ships `lib/bash/bash.help.md`,
  `lib/aether/aether.help.md`, `lib/build/build.help.md`; they ride
  inside the module dirs so `aeb --init`'s `.aeb/lib/<name>` symlinks
  carry them. Two residual `ae help` quirks (still open): namespaced
  library calls are reported as `undefined function` even with
  `--lib`, and a hint fires once per `import` of its module — so
  aeb's mandatory two-import idiom doubles each hint. See TODO.md.
- **0.150 multi-entry `--lib` search path** — `--lib a --lib b` or
  PATH-style `--lib a:b`; `AETHER_LIB_DIR` takes a list too. **Now
  consumed**: `tests/run.sh` builds with `--lib lib --lib tools`,
  which let the three-copy `file_to_label` duplication consolidate
  into the single `tools/aeblabel` module (see § Files/dirs and
  TODO.md § Three-copy `file_to_label`). Tool builds also thread
  `--lib tools` via the Makefile `AEFLAGS`.
- **0.152 `std.lzf`** — one-shot LZF compress/decompress. aeb's
  `lib/cache` uses sha256 + zlib; LZF is a lighter
  (size-vs-speed-tilted) alternative if cache-blob compression ever
  becomes a bottleneck. Not consumed.
- **0.153 `uint64` + wide prefixed-integer literals** — first-class
  `uint64`; `0x`/`0o`/`0b` literals no longer truncated by an
  intermediate `strtol`. Relevant if aeb ever grows 64-bit hashing
  inline (today sha256 is a shelled-out tool). `-Wstrict-prototypes`-
  clean codegen also landed — aeb-generated programs compile clean
  under stricter gcc.
- **0.159 + 0.161 `std.strbuilder`** — amortised-O(1) string builder
  (`new` / `append` / `length` / `finish`), the proper fix for the
  O(N²) `out = string.concat(out, chunk)` loop idiom. v2 (0.161)
  adds `append_long`, `append_hex`, `append_format`, `truncate`,
  `clear`, and binary-safe `finish_with_length`. **Partly consumed**:
  the per-build / per-scan accumulator loops that scale with repo
  size now use it — `tools/scan-ae-files.ae` (the monorepo-wide
  `.ae`-file buffer), `tools/aeb-graph.ae` (`dot_render` /
  `mermaid_render` / `mermaid_id`), and the file-list / object-list
  loops in `tools/aeb-link.ae`. The fixed-arity per-command builders
  in `lib/<lang>/` were deliberately left on `string.concat` — N is
  small and constant there, so strbuilder would add verbosity for no
  algorithmic gain. Adopt it for a new loop only when N genuinely
  scales.
- **0.160 variadic externs, typed C function-pointers,
  `extern struct`, `std.mem`** — FFI-heavy additions (raw-pointer
  access, declared C struct layouts, `fn(T) -> R` typed
  fn-pointers). aeb does no direct C FFI in its SDKs (everything
  shells out), so these are off aeb's path today; noted for
  completeness.
- **0.161 `@extern("sym")` declarations cross the `import` boundary
  and may be variadic** — an `@extern`-annotated binding is now part
  of a module's public surface. Same "no aeb consumer today" note as
  the 0.160 FFI cluster.
- **0.162 + `[current]` — four fixes aeb filed upstream** (see
  `../aether/aeb-ae-help-and-toolchain-feedback.md`). 0.162: `make
  install` warns when a stale `$PREFIX/current` symlink would shadow
  a fresh install (the bug that made `import std.strbuilder` fail at
  link). `[current]` (post-0.162, dev builds report 0.162.0):
  `ae help` accepts `--lib`; `*.help.md` hint files read from `--lib`
  roots; bare `_` is a per-use discard, not one type-bound variable
  (`_ = os.system(...)` after a string-typed `_` destructure no
  longer fails codegen); `ae build` warns on a compiler/`libaether.a`
  version mismatch instead of failing cryptically at link.
- **0.178 builder-vs-function name collision is now a compile error**
  (consumed: it's why the LLM.md `bash.run`/`lib/ruby gem→package`
  note above says "now enforced"). aeb filed it as
  `../aether/builder-function-name-collision-silent-dispatch.md`;
  `[current]` generalises it to `E1001` (any user function forging an
  imported export's mangled symbol). Nothing to consume beyond
  knowing aetherc now catches an SDK-authoring footgun aeb used to
  only document.
- **`[current]` `--emit=lib` artifacts are first-class imports** —
  `import foo` with no `foo` source but a `libfoo.so` on the search
  path synthesises an Aether stub (`@extern` per function export +
  a trailing-block `builder` wrapper per builder entry point) from
  the lib's `aether_lib_meta()` catalog, with the builder DSL
  reconstructed at full fidelity (v2 closure-context records, same
  release). **Not consumed; flagged as a future direction.** Today
  aeb ships SDKs as source `lib/<lang>/module.ae` + `.aeb/lib`
  symlinks, recompiled into every orchestrator build. A future aeb
  could precompile the SDKs to `.so` once and consume them as binary
  imports — faster per-build, and the closure metadata means the
  `<lang>.<verb>(b) { ... }` builder grammar survives the boundary.
  The value-add over the current source-symlink model is unproven
  (the recompile is cheap; the symlink model is simple), so this is
  "exists if a need arises," not a roadmap commitment.
- **0.442 `os.spawn_proc` / `os.wait` / `os.wait_any` — cross-platform
  non-blocking spawn + reap, Windows included.** The fan-out/fan-in pair
  a native parallel build scheduler needs: `spawn_proc(prog, argv, env)
  -> (token, err)`, `wait(token) -> (exit_code, err)`,
  `wait_any(tokens) -> (token, exit_code, err)`. No IPC pipe (that was
  the only part keeping `run_pipe` POSIX-only), so it works on Windows;
  handles live in an int-token→HANDLE table with non-recycled tokens, so
  PID reuse can't misattribute a reap. `spawn_proc` not `spawn` — the
  latter is the reserved actor keyword. **Not consumed yet, and it is
  the unblock for a real change**: aeb currently schedules nodes by
  emitting `target/.aeb/build.mk` and shelling to `make -jN`, with a
  sequential in-process loop as fallback. `make` buys exactly ONE
  capability (concurrency) at the cost of POSIX-shell recipes through
  the Windows chokepoint, `$$`-escaping that differs between the two
  modes, two schedulers that can silently diverge, and an external dep
  whose absence silently halves throughput. With these primitives the
  native scheduler is ~80–120 lines on the already-topo-sorted DAG, on
  every platform. Plan: `AEB_SCHED=native` as a third mode, green on
  Linux + winbaz, then flip the default and delete the Makefile path.
  Needs `ae >= 0.442.0`. Smoke-tested on Linux 0.442.0: 4×`sleep 2` in
  2 s (concurrent), completion-order reap, faithful exit codes. **Two
  gotchas**: `argv` EXCLUDES `argv[0]` (passing the program name again
  makes it an argument), and a failed exec is NOT reported at spawn time
  — a nonexistent binary yields a valid token and empty err, surfacing
  only as exit 127 from `wait`. So "spawn returned no error" does not
  mean "the node started". **Consumed**: `AEB_SCHED=native` in
  `tools/aeb-driver.ae`. See `asks/halting-guarantees-and-build-
  termination.md` § Postscript and
  `../aether/asks/os-run-pipe-on-windows-for-parallel-build-scheduling.md`.
- **0.357 `ae build --emit=csrc`** — emits portable generated C +
  a catalog header and stops (no gcc, no host `.so`): the
  compile-on-install / source-registry primitive. **Now consumed**:
  `aether.csrc(b)` in `lib/aether` (see § Files/dirs). Same release
  fixes `--emit=lib` catalog exports on Windows MinGW
  (`-Wl,--export-all-symbols`) — relevant to the winbaz Axis-2 path,
  nothing for aeb to change.

A note on resolution order (general, still true): an `ae` binary
installed under `~/.local/bin/` will pick up `contrib.*` modules from
`/usr/local/share/aether/contrib/` if its own prefix doesn't have them,
so `make install-contrib` from the Aether source tree (typically sudo)
suffices even for a per-user toolchain. This was originally verified
with `import contrib.aeocha` on `ae 0.118` — now moot for that module
specifically (**aeocha is retired**; its successor `std.spec` is stdlib,
not contrib, so it needs no `install-contrib`), but the prefix-fallback
mechanism holds for any surviving `contrib.*`.

## Two Aethers: pinned toolchain vs declared dep (PROPOSED)

There is ONE `$AETHER` knob today doing TWO unrelated jobs: compiling
aeb's own machinery (`transform-ae`, the orchestrator, `aeb-link`,
`aeb-driver` — trampoline line 16) and compiling the USER'S program
(`lib/aether/module.ae:1101`, inside `aether.program`). Conflating them
is why winbaz died with `E0301: Undefined function 'os.spawn_proc'`:
its ae was 0.413.0, aeb's driver needs 0.442, and the failure surfaced
as a compile error in a generated file rather than "this aeb needs
ae >= 0.442".

Agreed shape (Paul's framing) — **Role 1 shipped, Role 2 not yet**:

- **aeb's own compilation is PINNED to the aeb release**, and aeb may
  **quietly go-get that Aether for its own private use** — into aeb's
  cache dir (`~/.cache/aeb/toolchain/aether-<ver>/`), never on `PATH`,
  never in a system or user prefix. `which ae` must answer the same
  before and after aeb runs; the user's `ae` is what `aether.program`
  uses and is never touched. This does NOT contradict "never provisions":
  that rule is about the UNBOUNDED case (every toolchain × distro ×
  version). aeb fetching its OWN single pinned dependency is bounded and
  known at release time.

  **Role 1 SHIPPED** (the trampoline, `aeb:~100-230`). It tries the
  **prebuilt release asset** for the node's platform first (<1 s, no C
  compiler needed), then falls back to upstream's `get.sh` — which is a
  **source** installer (~69 s). Both are needed: there is no
  `linux-arm64` asset, so ARM Linux nodes take the source path. A
  downloaded prebuilt is staged in a temp dir and must pass a
  **compile probe** before it is moved into the cache — `--version`
  is not enough (v0.449.0's `aetherc` needed GLIBC_2.38 and died on
  Debian 12 while the banner succeeded), and since upstream publishes
  **no `.sha256`**, that probe is also the only integrity gate. Escape
  hatch: `AEB_FETCH_SOURCE=1`.
- **A target that builds Aether code DECLARES its Aether**, via the
  existing `prereq(b, "aether:0.410")`. `aether` becomes a canonical
  token beside `jdk`/`node`/`rust` (with `ae` a rejected misname), so
  `--prereqs`, `--preflight`, `agent.prereq_to_image` and the agent's
  `/ping` version all cover it for free — that `/ping` version is
  currently advisory and consumed by nothing.
- **The two may differ**, deliberately: same shape as building a Java 8
  target on a Java 21 JVM.

Still NO installer — states needs, observes presence, never provisions
(`docs/build-prerequisites-and-provisioning.md`).

**IMPLEMENTED (2026-07-27)** for Role 1, as TWO files, because two
different clocks were being conflated:

- **`AETHER_PIN`** — the FLOOR: oldest Aether that can compile aeb's own
  sources. Moves only when aeb starts calling a primitive an older
  Aether lacks; historically ~4 times across hundreds of releases
  (0.410, 0.413, 0.442-ish, 0.447, and 0.463 for `string.replace_all`).
  Bump it in the same commit that introduces the call.
- **`AETHER_FETCH`** — WHICH known-good release to download when the
  floor is unmet. MUST be >= the PIN (a lower value would fetch a
  toolchain that cannot compile aeb, "succeeding" and then failing with
  E0301 in a generated file). Can be newer for non-language reasons
  (today: glibc —
  releases built on ubuntu-latest carry a GLIBC_2.38 floor whose
  `aetherc` dies on Debian 12, while `ae --version` still succeeds).

Conflating them bites immediately: bumping the PIN to chase a nicer
release forces a needless fetch on everyone between the two versions
(seen live — this box on 0.451 was told it needed 0.452). The cache dir
is keyed on the FETCH version, not the floor, or a bumped AETHER_FETCH
silently reuses the stale tree.

**Cadence policy**: Aether cuts releases fast (seven on 2026-07-26).
Don't chase it. aeb has no downstream user community yet, so staying
near HEAD is cheap; when that changes, slow `AETHER_FETCH` down to
soaked releases and leave `AETHER_PIN` as the sparse evidence-driven
floor it already is. No mechanism change needed for that — only
discipline about when the numbers move.

The live objection: a hand-maintained floor DRIFTS, and a stale floor is
worse than none. Mitigation is derive-don't-declare — the primitives aeb
calls are greppable, so a test can assert they all exist in the pinned
floor. Without that, this makes the error message nicer and the accuracy
worse. Full write-up:
`asks/two-aethers-pinned-toolchain-vs-declared-dep.md`.

## The load-bearing principle

**The dot-prefixed `.ae` file is the single source of truth for
what aeb does for its target.** External config files
(`aether.toml`, `pom.xml`, `Cargo.toml`, etc.) are honoured via
shell-outs to tools that already parse them, but aeb itself doesn't
parse them. When in doubt, prefer adding a setter that the user
calls inside the `.ae` file over adding a parser to aeb. This is
what keeps the build-graph extraction text-only and the
configuration typeable / IDE-friendly / introspectable from `grep`.

Setters can come from aeb's `lib/` (the generic SDKs we ship) or
from a consumer's own `.aeb/lib/<name>/module.ae` (domain-specific
SDKs that wrap our primitives). Both feed the same `.ae`-as-truth
contract; the boundary between them is generic-vs-domain, not
core-vs-extension.
