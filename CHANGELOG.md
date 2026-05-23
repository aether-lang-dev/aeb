# Changelog

## Unreleased

### Added

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
