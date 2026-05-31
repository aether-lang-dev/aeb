# Changelog

## Unreleased

### Added

- **Remote-aeb: `aeb-agent` + `agent.dispatch` (walking skeleton).** A
  sovereign build-agent server and the originator dispatch to it — the
  first running slice of the run-policy / cloud-leverage design
  (`docs/run-policy-class-and-cloud-leverage.md`). `aeb-agent` is a
  **standalone binary** (installed at `$PREFIX/bin/aeb-agent`), NOT an
  `aeb agent` subcommand — so a sysop probes "does this machine have the
  agent capability" by whether `aeb-agent` is on `PATH`.
  `aeb-agent --port N --accept '<glob>' --workdir DIR [--max-jobs N]
  --tokens <file>` listens over HTTP; on `POST /dispatch
  {guid,target,purpose}` it **authenticates** (see below), decides
  **accept / busy / reject** against its scope (purpose glob + job-slot
  cap), runs `aeb <target>` on the bare host, and returns a terse verdict.
  The agent's ability to refuse is what makes it a sovereign peer, not a
  worker — aeb is never a fleet control plane. The originator side is
  `agent.dispatch(b) { endpoint(...) target(...) purpose(...) token(...) }`
  in a fan-out `.ae` target: it fires the request, awaits the verdict, and
  folds pass/fail into `build.fail`/`any_failed` (trustworthy only because
  of the silent-green fix — the remote `aeb` actually reddens on failure).
  v1: synchronous request/response, scope from CLI flags, busy/reject/
  unreachable fail back to the user. Composable scope-tree data model
  (`run_on("host")` now; `podman`/`vm` kinds slot in later). Shared
  decision core in `lib/agent` (`_decision`, scope-glob match, slot cap,
  wire payloads, token parse/check), unit-tested offline in
  `tests/test_agent_scope.ae` (36 assertions).

  **Naive `--tokens` auth (interim, fail-closed).** The agent takes
  `--tokens <file>` (one bearer token per line, `#` comments); a dispatch
  must present a token (`X-AEB-Token` or `Authorization: Bearer`) that is
  in the file. **No `--tokens` file → the agent refuses ALL dispatches**
  (fail-closed) with a clear startup line. This is shared-secret auth only
  — NO signing, expiry, embedded/verified scope, or per-principal
  issuance; the interim stand-in for the designed claim→verify→veto /
  purpose-in-the-token model, giving a sysop a real on/off today.
  Deliberately still NOT: cache partitioning, fire-async + webhook-back +
  `details_url` split, the `.ae` closure-DSL agent config (all designed,
  flagged as thickenings).

### Fixed

- **Silent-green follow-up: don't trust the node fn's implicit return.**
  The first cut of the silent-green fix captured `_rc = <node>(s)` and
  `record_status(_rc)`. But a `.build.ae main()` whose last statement is a
  bare trailing-block builder call with no explicit `return` (the common
  shape, e.g. `aether.program(b) { ... }`) yields that block-expression's
  value as the fn's implicit return — which is NOT the builder's rc and
  can be garbage-nonzero (verified: `aether.program` tail-call → garbage
  1, while `c.program` → 0 — builder-dependent and latent). That
  spuriously failed PASSING builds. Fixed: the orchestrator no longer
  reads/records the node return; failures redden solely via the EXPLICIT
  `build.fail()` channel (every SDK builder calls it on `os.system`
  failure — the sweep), which the `any_failed` exit gate reads. Verified:
  a passing trailing-block build exits 0, a real compile failure still
  exits 1, clean builds stay 0.

- **Silent-green eliminated: a failed build step now reddens the build.**
  Previously a failed `javac`/`gcc`/test exited 0 — `gen-orchestrator`
  discarded each node's outcome and never exited non-zero, and builders
  swallowed their own return code (a `.build.ae main()` calls
  `java.javac(b)` without `return`). A test target whose compile dep
  failed would run against no classes, report `0/0 PASS`, and the whole
  build went green. Fixed in two coordinated parts: (1) the orchestrator
  now captures each node's rc, calls `build.record_status`, and
  `exit(1)`s on `build.any_failed` (outside the per-node selector guard,
  so it fires in both per-node and `--in-process` modes); (2) every
  `os.system`-failure / missing-required-setter site inside a `builder`
  body across all 16 SDKs now calls `build.fail(ctx, reason)` — the
  channel that reaches the shared session, since the return path is
  swallowed. ~69 sites swept (java, python, ruby, c, kotlin, scala,
  clojure, jest, ts, pnpm, webpack, bash, copy, webhook, approval).
  Verified: a broken compile dep now exits non-zero in both modes, the
  driver prints `FAILED (see <log>)`, dependents are skipped, and a clean
  build still exits 0. Design: `asks/node-failure-propagation.md`.

### Added

- **`no_closure_regen()` setter for `aether.program(b)`** — opt out of
  the transitive import-closure regen pass for the "thin Aether over a C
  backend" shape, where a module's Aether bodies are `extern`
  declarations of a C ABI (e.g. a GUI toolkit's `ui.ae` over a
  GTK/AppKit/Win32 backend). Such modules can't be `--emit=lib`'d
  standalone — aetherc fails with a wall of `E0301 Undefined function`
  because the externs are only resolved once linked with the C backend.
  With this flag the manual path compiles the entry with plain
  `aetherc entry.ae entry.c` (tolerating unresolved externs, exactly as
  `ae build` does for a plain program) and links the declared
  `extra_source` C + `link_flag`s, without attempting `--emit=lib` on any
  import. The import closure still feeds the cache key (imported `.ae`
  content is hashed independently of the regen list), so staleness
  tracking is unaffected; explicit `regen(...)` / `regen_with(...)`
  entries still run. Counterpart opt-out to the
  transitive-regen-expansion auto-expansion. Ask:
  `asks/thin-aether-over-c-backend.md`.

- **`java.select_jdk("21")` — select among installed JDKs.** Pick which
  JDK compiles a module by major version (exact `"21"` or floor `"21+"`),
  independent of which `javac` is on `PATH`. Discover-select-or-fail: aeb
  probes `/usr/lib/jvm` (and macOS `/Library/Java/...`) for a matching
  JDK and runs `javac` from that home; if none matches it prints an
  actionable message naming what *is* installed. Never downloads — install
  the JDK yourself (sdkman/apt/setup-java). Orthogonal to `release(...)`
  (the bytecode/API level): `select_jdk` picks the compiler, `release`
  picks the target level. The selected JDK home + its probed version fold
  into the javac cache key. Generic version-match/selection core lives in
  `lib/build` (`_match_major_version`, `_select_jvm_home`,
  `_jvm_dir_major`, …), shared so other SDKs can reuse it. Also adds
  `build.lock_validate(...)` — the consume-side check for a future
  generated, hash-stamped lock node (a lock declares the hash of the BOM
  it was generated from and hard-fails if that BOM drifted). Design:
  `docs/toolchain-selection-and-locks.md`,
  `asks/versioned-bom-and-self-validating-lock.md`.

### Changed

- **Per-node output is now the default; `aeb --in-process` opts out.**
  aeb runs each build node as its own subprocess and redirects that
  node's tool output (javac/junit/jest/…) into
  `target/.aeb/logs/<label>.log`, so aeb's own stdout carries only its
  framing + the telemetry summary instead of interleaving every tool's
  chatter. Same results/summary as before (validated on
  `google-monorepo-sim`: identical `32 compile + 2 dist + 22 test`, zero
  tool-noise on stdout). `--in-process` (or `AEB_IN_PROCESS=1`,
  `AEB_PER_NODE=0`) runs the older all-in-one in-process orchestrator —
  simplest to debug, fine for small builds. Design:
  `docs/nodes-as-subprocesses.md`.

- **Per-node builds run in parallel** (`make -jN` as the scheduler). aeb
  emits a Makefile (one target per node, prerequisites from the dep DAG)
  and lets make schedule dep-respecting concurrency; `AEB_JOBS=<n>` caps
  it (default `nproc`; `1` = sequential), and it falls back to a
  sequential loop if `make` isn't present. On `google-monorepo-sim` the
  build-execution phase dropped from 85.7s (all-in-one) / 114.6s
  (sequential per-node) to **40.4s** (~2× faster than the old default) —
  so per-node is now both cleaner *and* faster.

### Fixed

- **`lib/webhook`: `client.set_timeout` now takes a `Duration` literal.**
  A newer Aether type-checker rejects a bare int for the timeout arg;
  `set_timeout(req, 10)` → `set_timeout(req, 10s)`. Unblocks
  `tests/test_webhook_fire`.

- **Transitive-regen no longer shadows explicit `regen_with` caps**
  (`lib/aether` `_expand_transitive_regens`). An explicit
  `regen_with("../x/module.ae", caps)` (relative) was re-added by the
  import-closure walk as an absolute path with weaker auto-detected caps,
  because the dedup compared paths as raw strings; aetherc 0.190's
  `--emit=lib` cap-gate then rejected the duplicate. Now dedups by a
  canonical path (`_canonical_path`, collapsing `.`/`..`), so the
  explicit entry stands and its caps win
  (`asks/transitive-regen-caps-shadowed-by-duplicate.md`;
  `tests/test_aether_canonical_path.ae`).

### Added

- **`install.sh` + `docs/bootstrap-from-source.md`** — a `curl … | sh`
  installer (`AEB_REF`/`PREFIX`/`AETHER` knobs; defaults to the latest tag
  and `~/.local`, no sudo) that fetches the GitHub source tarball for a
  pinned ref and `make install`s it, plus a consumer bootstrap guide
  (one-liner, clone, in-tree `./aeb`, pinning aeb in CI, tracking HEAD).
  README gains an Installing section.

- **Auto-tagging on push to `main`** (`.github/workflows/autotag.yml`).
  Every push gets the next sequential `v0.NNN` tag — a human-ordered,
  pinnable ref (GitHub serves a source tarball per tag), so a downstream
  repo can pin aeb to `AEB_REF=v0.042` rather than an anonymous SHA.
  Pinnable markers, not sem-ver promises (see CONTRIBUTING.md).

- **Build-level process-group reaping + `aeb --timeout`** (the `aeb`
  trampoline). The whole build now runs in its own process group and is
  group-reaped (`TERM` → grace → `KILL`) on completion, so a step that
  backgrounds a server or leaks a helper can't leave a process lingering
  into aeb's exit — which under a sandboxed agent/CI harness can poison
  the exit code. The
  reap is always on and a no-op when a build leaks nothing. `--timeout N`
  / `AEB_TIMEOUT=N` (seconds) caps total wall-clock and exits 124 on
  overrun. Bazel-style; per-step isolation is a deferred design
  (`lifecycle_plan.md` §9).

- **`fixture_server` teardown hardened** (`lib/build`): servers launch
  with stdin detached and tear down `TERM` → grace-poll → `KILL` → reap,
  so a server is gone before the step returns even if it ignores `TERM`.

- **`lib/copy`: file/directory-staging SDK** (`copy.file(b)`,
  `copy.tree(b)`) — Bazel `copy_file` / `copy_directory` analogue.
  Closure-DSL setters `from(...)` / `to(...)`; mtime-skip when the
  destination is fresher than the source. The canonical pre-build
  staging primitive (e.g. Selenium's Ruby gemspec needs LICENSE /
  NOTICE staged from the repo root before `gem build`). Pure helpers
  `cp_file_cmd` / `cp_tree_cmd` / `_resolve_path` + setter
  accumulation covered by 17 assertions in `tests/test_copy_cmd.ae`.
  Registered in `tools/aeb-init.ae` `shipped_modules()`.

- **`lib/scala`: `scala.assembly(b)` fat-jar builder**. The
  no-scala-cli / no-sbt analogue of sbt-assembly: stages compiled
  classes + scala-library + every transitive dep (unzips each
  classpath jar, copies each class dir) into a tree, writes a
  Main-Class manifest, and `jar cfM`s it. Setters `main_class(...)`
  (required) + `output_jar(...)`. Pure helpers
  (`assembly_unzip_jar_cmd` / `assembly_copy_classes_cmd` /
  `assembly_jar_cmd` / `_ends_with_jar`) covered in
  `tests/test_scala_cmd.ae` (4 → 18 assertions). Demo:
  `itests/scala-cli-multi-module-demo/module-1/.dist.ae`.

- **`lib/clojure`: `clojure.uberjar(b)` builder**. The no-leiningen
  analogue of `lein uberjar`: AOT-compiles `main_ns` (a `(:gen-class)`
  namespace), stages `src/` so non-AOT namespaces load at runtime,
  unzips clojure.jar + maven deps, writes a Main-Class manifest (with
  Clojure's dash→underscore munging), and packages it. Setters
  `main_ns(...)` + `output_jar(...)`. `tests/test_clojure_cmd.ae`
  4 → 16 assertions. Demo:
  `itests/clojure-multiproject-example/projects/example_app/.dist.ae`.

- **`lib/build`: public path accessors for inline build steps** —
  `build.target_dir(b)` / `build.source_dir(b)` / `build.root(b)` /
  `build.mkdirs(path)`. Lets inline Aether between SDK builders read
  the module's paths without reaching into the internal `_get`.

- **`docs/inline-build-steps.md` + runnable example**
  (`docs/examples/inline-git-changelog/`). Documents that a
  `.build.ae` is an Aether program: between idiomatic SDK builders you
  can run any Aether — shell out, parse stdout, transform, write
  artifacts — calling same-file or imported functions. Worked example:
  an inline step that runs `git log --oneline -10`, reformats it via
  an adjacent helper, and writes an artifact a sibling `.dist.ae`
  pulls in. Closes with the one-off-inline → repo-local-module →
  core-`lib/<name>` promotion path.

- **`itests/selenium/Aeb_vs_Bazel.md`** — polyglot-DAG musing
  (sibling to the PyTorch one), including the rationale for *not*
  bridging `maven_install.json`. Plus a hand-pinned
  `java/selenium-deps.bom.ae` and two more Java leaves (`io/`,
  `grid/jmx/`) demonstrating BOM-loaded dep resolution.

- **`itests/selenium/py/.api-listing-codegen.ae`** — closes the
  `generate_api_module_listing.py` gap via `python.codegen` with
  `codegen_input_dir`. `lib/python`'s `_codegen_can_skip` now walks
  declared input directories recursively (`_dir_newest_mtime`,
  Aether-native, no GNU-`find` dependency) so dir inputs participate
  in the staleness check.

### Changed

- **`lib/java`: `shade(b)` fat-jar rewritten to a staging-dir
  approach** (matching `scala.assembly` / `clojure.uberjar`). The old
  `jar -C <entry> .` per-classpath-entry form was broken for real dep
  sets — it can't `-C` into a `.jar` (only directories), and the
  per-entry echo emitted embedded newlines that split the jar command
  into separate shell lines (`sh: -C: not found`). Now extracts each
  dep jar, copies each class dir, drops native `.so` files at the jar
  root, writes the manifest, and packages the staging tree.

- **`lib/kotlin`: compiler and stdlib resolved from one install**.
  New `_kotlin_home()` (probe `KOTLIN_HOME` → snap → apt, first with a
  real `kotlin-stdlib.jar`) + `_kotlinc_bin()` (the home-local
  `kotlinc`, not bare PATH). Fixes "incompatible version of Kotlin"
  when a box has an old `/usr/bin/kotlinc` alongside a newer stdlib.
  Unifies the three builders (`kotlinc` / `kotlinc_test` /
  `kotlin_test`) onto one resolution path.

- **`lib/aether`: `aether.program(b)` auto-links shared-library
  deps**. A `build.dep` on a Rust cdylib (or any lib emitting a
  `shared_library_deps_including_transitive` artifact) the program
  FFIs into now takes the manual gcc path automatically (with
  `-L`/`-l` + `-Wl,-rpath`), even without an explicit
  `extra_source`/`link_flag`. Previously the default `ae build`
  shell-out left such externs unresolved (`undefined reference`).

- **SDK-lib resolution: fast-fail on a dangling `.aeb/lib`**
  (`tools/aeb-main`). An absent `.aeb/lib` still falls back to
  `$AEB_HOME/lib` (keeps `aeb --init` optional for a fresh clone), but
  a `.aeb/lib` whose symlinks are dangling now errors loudly instead
  of silently swapping in the global SDK — silent fallback on a broken
  pin can build against a different/stale SDK than the project
  declares. `aeb --init` re-points dangling links.

- **`make install` force-rebuilds every `tools/*.ae` binary** before
  copying the runtime tree. The lazy-built tool binaries (topo-sort,
  extract-deps, …) are gitignored and the pattern rule can't tell a
  binary is stale vs the *toolchain* (only vs its source mtime); a
  stale `topo-sort` built under an older aetherc shipped a wrong DAG
  order and cascaded into repo-wide build failures.

### Fixed

- **`tools/extract-deps`: same-directory deps now resolve**. A
  `dep(b, ".build.ae")` (no path prefix — e.g. a `.dist.ae` depending
  on its sibling `.build.ae`) was emitted as the bare string
  `.build.ae`, which never matched its node (`foo/.build.ae`): in
  target mode the sibling never built; in scan mode the ordering edge
  was silently dropped. Deps are now resolved relative to the
  depending file's directory when they aren't valid repo-root-relative
  paths, supporting both conventions. The dep DAG is aeb's core, so
  this was a real dropped-edge bug.

- **`tools/resolve-imports.sh`: selective imports no longer mask
  transitive bare imports**. A user's `import maven (load_bom_file)`
  suppressed the bare `import maven` that lib/java's internal
  `maven.classpath()` calls need at orchestrator-link time, producing
  repo-wide `E0301 Undefined function 'maven.classpath'`. Only bare
  `import X` lines now count as "already covered".

- **`tools/extract-deps` + `tools/scan-ae-files`: ae 0.180
  heap-string workaround**. A `rest = content; … rest = substring(…)`
  loop corrupts the aliased `content` heap string under ae 0.180
  (filed upstream as `180-regression.md`), making a freshly-built
  extract-deps return an empty `scan()` expansion. Defensive
  `string.concat(content, "")` copies dodge it.

- **`lib/scala`: `scalac`'s classpath artifact now includes
  transitive deps**. The `jvm_classpath_deps_including_transitive`
  artifact omitted the `build.dep` classpath, so a downstream fat jar
  lost cross-module classes (e.g. `common/SharedCode`).

- **`lib/ruby`: three fixes**. `bundle_install_cmd` uses
  `bundle config set --local path` then `bundle install` (Bundler 2.x
  removed `--path=`); `gem_build_cmd` runs from the gemspec's directory
  (so relative `s.files` resolve) then moves the `.gem` to dist;
  the `gem` *builder* renamed to `package` — it collided at C-mangle
  time with the `gem` *setter* (Gemfile-line append), silently routing
  `ruby.gem(b)` into the setter and skipping the build.

- **`lib/fetch` / `lib/dotnet`: pure helpers extracted** for
  unit-testability — `_format_to_flags` / `_format_is_zip` (fetch
  archive format override) and `_resolve_csproj_path` (dotnet csproj
  path). `tests/test_fetch_cmd.ae` 27 → 43, `tests/test_dotnet_cmd.ae`
  7 → 12, `tests/test_cargo_cmd.ae` 12 → 14,
  `tests/test_python_codegen_cmd.ae` 21 → 26,
  `tests/test_ruby_cmd.ae` 21 → 26.

- **`lib/rust`: `rust.cargo_test_existing(b)` builder**.
  Pair to `rust.cargo_project_existing(b)` — runs `cargo test`
  from source_dir against the upstream `Cargo.toml`, no
  regeneration. Optional `features` / `jobs` / `extra` setters
  pass through to the test command the same way they do for
  `cargo_build_cmd`. New pure helper `cargo_test_cmd(source_dir,
  opts)`. Test coverage in `tests/test_cargo_cmd.ae` extended
  from 6 to 9 assertions.

- **`itests/selenium/py/.bidi-codegen.ae`**: end-to-end
  demonstration of the `fetch.file` → `python.codegen` chain.
  Reads the CDDL spec fetched by `itests/selenium/py/.bidi-spec.ae`,
  runs `generate_bidi.py` against it with declared inputs (CDDL +
  manifest) and declared outputs (the BiDi command modules
  generated under `selenium/webdriver/common/bidi/`). This is the
  full integration Selenium's upstream Bazel needs `http_file` +
  a custom `generate_bidi.bzl` macro to express; aeb does it with
  two canonical `.ae` files (one per SDK) and a `build.dep` edge
  between them.

- **`lib/dotnet`: `dotnet.build_project_existing(b)` builder**.
  Non-destructive .NET packaging: runs `dotnet build` against the
  upstream `.csproj` as-is, never regenerates a
  `.{name}.generated.csproj`. The right choice for projects with
  hand-tuned upstream csprojs (Microsoft.NET.Sdk customisations,
  signing config, multi-targeting, paket-managed deps). Setter
  `csproj_path(path)` for non-default locations; single-csproj
  source_dirs auto-detect. Test coverage in
  `tests/test_dotnet_cmd.ae` extended to 7 assertions (was 4).
  Demo: `itests/selenium/dotnet/src/webdriver/.build.ae`.

- **`lib/rust`: `rust.cargo_project_existing(b)` builder**.
  Non-destructive cargo build: runs `cargo build --release` against
  the upstream `Cargo.toml` as-is, never regenerates. The right
  choice for porting real-world crates as aeb leaves (workspace
  links, dev-deps, platform-specific deps, [[bin]] declarations
  aeb's TOML generator doesn't model). Optional setter
  `binary_name(name)` writes a `cargo_binary` artifact for
  downstream consumers. Test coverage in `tests/test_cargo_cmd.ae`
  extended to 6 assertions (was 4). Demo:
  `itests/selenium/rust/.build.ae` for the Selenium Manager
  binary crate.

- **`lib/pnpm`: `pnpm.install(b)` + `pnpm.run(b, script)` builders**.
  The two missing core operations for Bazel-rules-js projects
  with an in-tree `package.json` + `pnpm-lock.yaml` +
  `pnpm-workspace.yaml`. `pnpm.install(b)` runs `pnpm install`
  from source_dir; optional `frozen_lockfile()` setter forces
  CI-mode (`--frozen-lockfile`). `pnpm.run(b, "script")` runs a
  `scripts:` entry from package.json; repeatable `script_arg(...)`
  appends args after the `--` separator. Two new pure command
  builders (`pnpm_install_cmd`, `pnpm_run_cmd`) plus the existing
  `pnpm_spec_from_dep` and `pnpm_add_cmd` are covered by 15
  assertions in `tests/test_pnpm_cmd.ae` (was 8). Demos:
  `itests/selenium/.build.ae` (workspace install) and
  `itests/selenium/javascript/selenium-webdriver/.build.ae`
  (pnpm run lint).

- **`lib/fetch`: external-resource SDK** (`fetch.file(b)`,
  `fetch.archive(b)`) — Bazel `http_file` / `http_archive`
  analogue. Closes the gap surfaced by Selenium's BiDi codegen
  (CDDL specs fetched as Bazel external repos). Setters:
  `url(...)`, `sha256(...)`, `output_to(...)` (file builder),
  `extract_to(...)`, `strip_components(N)`, `format(...)` (archive
  builder). Sha256 verified on every run; mismatch fails loud and
  removes the bad blob. Archive format inferred from URL suffix
  (`.tar.gz` / `.tgz` / `.tar.bz2` / `.tar.xz` / `.zip`); query
  strings tolerated. Cached archive lives in
  `target/<mod>/_fetch/` and skips re-download on subsequent
  invocations. Pure helpers (`fetch_curl_cmd`,
  `sha256_verify_cmd`, `tar_extract_cmd`, `zip_extract_cmd`,
  `_infer_archive_flags`, `_is_zip_url`, `_ends_with_p`) and
  setter accumulation covered by 27 assertions in
  `tests/test_fetch_cmd.ae`. Verified end-to-end against the
  Selenium upstream pinning:
  `itests/selenium/py/.bidi-spec.ae` fetches the 118 KB
  WebDriver BiDi CDDL from `raw.githubusercontent.com/w3c/webref`
  at the same commit Selenium's `common/webref_cddl.bzl` pins to.
  Registered in `tools/aeb-init.ae` `shipped_modules()`.

- **`lib/python`: `python.package_existing(b)` builder**.
  Non-destructive Python packaging: runs `python -m build` against
  the upstream `pyproject.toml` as-is, never regenerates or
  overwrites it. Pairs with the existing `python.package(b)`
  builder, which is the right choice when aeb owns the metadata;
  the new builder is the right choice when the upstream
  `pyproject.toml` is the source of truth (selenium ships
  `setuptools-rust` + classifiers + license-files that
  aeb-side regeneration would silently drop). Optional setter:
  `pyproject_path("alt/pyproject.toml")` for non-default locations.
  Test coverage in `tests/test_python_cmd.ae` extended with
  setter-accumulation assertions (9 total, was 7). The exec-string
  surface (`build_package_cmd`) is shared with the existing
  builder, so no new pure helper. Demo:
  `itests/selenium/py/.dist.ae`.

- **`lib/ruby`: Ruby SDK** for Bundler + RSpec + RuboCop + `gem`
  packaging. Closes the gap surfaced by Selenium (32 Ruby BUILD
  files unreachable without this). Project-local isolation via
  `.aeb/bundle/` (parallel to `lib/python`'s `.aeb/venv/`). Builders:
  `ruby.install(b)` (bundle install), `ruby.rspec(b)` (bundle exec
  rspec), `ruby.rubocop(b)` (bundle exec rubocop), `ruby.gem(b)`
  (gem build from a `.gemspec`). Setters: `gem(line)`, `gemfile`,
  `gemspec`, `bundle_path`, `rspec_arg`, `rubocop_config`,
  `ruby_version`. Pure command builders (`bundle_install_cmd`,
  `bundle_exec_cmd`, `rspec_cmd`, `rubocop_cmd`, `gem_build_cmd`) +
  the seven grammar setters are covered by 21 assertions in
  `tests/test_ruby_cmd.ae`. Registered in `tools/aeb-init.ae`'s
  `shipped_modules()` list so `aeb --init` symlinks it into
  consumer repos.

- **Selenium integration test scaffolding** (`itests/selenium/`).
  Adds `https://github.com/SeleniumHQ/selenium.git` to
  `itests/fetch-upstream.sh`. Per-file ignore overlay added to
  `itests/.gitignore` (5098 file entries, no bare-directory
  shadows). One Java leaf converted as the demonstration:
  `java/src/org/openqa/selenium/status/.build.ae` translates
  upstream's `java_library(srcs=glob(["*.java"]),
  deps=[artifact("org.jspecify:jspecify")])` into a 6-line aeb DSL
  call; verified compiles `HasReadyState.class` +
  `package-info.class` as real Java 17 bytecode after `lib/maven`
  resolves jspecify 1.0.0. `AEB_MIGRATION_STATUS.md` records the
  scope, the per-language status (Java / Python / Ruby / JS / .NET
  / Rust / C++), and four grammar gaps surfaced by Selenium that
  weren't visible from PyTorch alone:
    1. `python.package_existing_pyproject` builder missing —
       `lib/python.package` always regenerates pyproject.toml, which
       is destructive for projects with tuned upstream metadata.
    2. `lib/ruby` doesn't exist; Selenium's 32 Ruby BUILD files can't
       be converted.
    3. No grammar for "fetch external file at build time" — Selenium's
       BiDi codegen reads CDDL specs that Bazel fetches via
       `MODULE.bazel`'s `bazel_dep`/`http_file` rules.
    4. `rules_jvm_external`'s `maven_install.json` pinning isn't
       directly readable by `lib/maven`; selenium-scale Java
       conversion would benefit from a converter.

- **`lib/python`: `python.codegen` builder** for codegen-driver
  scripts (PyTorch's `torchgen.gen`, gRPC's `protoc-gen-py`, sqlalchemy
  migrations). DSL closure with explicit input declaration
  (`codegen_input` / `codegen_input_dir`), declared outputs
  (`codegen_output` — verified after the run), arg list
  (`codegen_arg`), and module-form / script-form drivers
  (`codegen_driver` / `codegen_script`). Skips when every declared
  output is newer than every declared input (mtime-driven, same
  shape as `aether.regen`). Fails the build if any declared output
  is missing after the run — catches CMake's silent-partial-
  generation trap. Pure command builder
  (`python_codegen_cmd`) AND the eight grammar setters
  (`codegen_driver` / `codegen_script` / `codegen_input` /
  `codegen_input_dir` / `codegen_arg` / `codegen_output` /
  `codegen_cwd` / `codegen_python`) are covered by 21 assertions in
  `tests/test_python_codegen_cmd.ae`. These are the canonical tests
  of record for the grammar; the `itests/pytorch/` end-to-end
  demonstration is a fringe experiment that requires fetching
  upstream source via `itests/fetch-upstream.sh` and is not part of
  the required test surface.

- **PyTorch integration test scaffolding** (`itests/pytorch/`,
  documented in `itests/pytorch/AEB_MIGRATION_STATUS.md`). Three
  overlay files on top of an upstream shallow clone:

  - `aten/src/ATen/.codegen.ae` — drives `python -m torchgen.gen`
    over `native_functions.yaml` + `tags.yaml` + templates with
    explicit `codegen_input` declarations. Replaces upstream's
    `cmake/Codegen.cmake` `add_custom_command` block plus the
    `file(GLOB_RECURSE all_python "torchgen/*.py")` CONFIGURE_DEPENDS
    backstop. Verified end-to-end: torchgen runs (15s), produces 102
    real C++ source/header files, second invocation is a 40ms
    mtime-skip.

  - `c10/util/.build.ae` — explicit 39-file source list (out of 42
    upstream `.cpp` files) compiled by `c.compile` with `g++
    -std=c++20`. Demonstrates the no-glob contract: upstream
    `file(GLOB C10_SRCS CONFIGURE_DEPENDS *.cpp …)` would silently
    rope in `env.cpp` / `signal_handler.cpp` / `tempfile.cpp` which
    pull in `<fmt/format.h>` that isn't wired yet. The explicit list
    makes those 3 omissions a visible TODO instead of a build
    failure. Produces 39 ELF `.o` objects.

  - `torchgen/.whl.ae` — declares torchgen as an installable Python
    package via `python.wheel_registry`, so downstream `.build.ae`
    consumers can `build.dep` on it.

  Plus `itests/.gitignore` adjustments to allow `.codegen.ae` and
  `*.whl.ae` overlay files through the gitignore allowlist.

- **`lib/aether`: extern link-failure diagnostic hint** (Option B from
  `asks/transitive-regen-extern-followup.md`). When gcc fails with
  `undefined reference to <sym>` during a manual aether.program link,
  aeb now scans every `module_generated.c` under the workspace root,
  groups any symbols that resolve to sibling Aether modules, and emits
  a `regen_with("<path>", "<caps>")` hint line per defining sibling.
  Symbols that don't resolve to a project module (libc, runtime libs)
  produce no hint — true C externs aren't false-flagged. Covered by
  `tests/test_aether_extern_diagnostics.ae`.
