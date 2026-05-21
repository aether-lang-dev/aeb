# Changelog

## Unreleased

### Added

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
