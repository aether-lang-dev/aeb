# Selenium → aeb Migration — Status

Upstream: https://github.com/SeleniumHQ/selenium (shallow `--depth 1`
clone via `itests/fetch-upstream.sh`).

## Not a test of record

This is a **fringe experiment**, not part of aeb's canonical test
surface. Cloning the aeb repo and running `tests/run.sh` exercises
every grammar addition offline without fetching upstream. The
overlay files in this directory illustrate aeb's shape against a
real polyglot, Bazel-managed codebase; they're not what guarantees
SDK correctness.

## Why Selenium is an interesting target

Where PyTorch's interest is its codegen-with-hand-maintained-DEPENDS
problem (CMake-shaped), Selenium's interest is the **polyglot DAG**
itself.

Selenium ships client bindings in Java, Python, JavaScript/Node,
Ruby, C#/.NET, plus a Rust manager binary and a C++ IEDriver. Each
language has its own subtree; the build is graph-shaped through
Bazel's `BUILD.bazel` files. The migration question isn't "can
aeb express this" — clearly it can — it's "how many of aeb's existing
SDKs slot in cleanly, and where does the grammar gap show up?"

Count of upstream `BUILD.bazel` files by language tree:

| Tree         | BUILD.bazel files | aeb SDK             |
|--------------|-------------------|---------------------|
| `java/`      | 173               | `lib/java`          |
| `rb/`        | 32                | none yet (Ruby SDK is a gap) |
| `javascript/`| 15                | `lib/ts`, `lib/pnpm`|
| `dotnet/`    | 10                | `lib/dotnet`        |
| `rust/`      | 3                 | `lib/rust`          |
| `py/`        | 2                 | `lib/python`        |
| `cpp/`       | 2                 | `lib/c`             |

237 BUILD.bazel files total at the time of the snapshot. The dual
heaviness on Java (173) and Ruby (32) tells you where Selenium's
real engineering volume lives.

## Scope of this pass

Not a full conversion. The migration aims to:

- Express the layout cleanly as an `AEB_MIGRATION_STATUS.md` plus a
  small set of overlay `.build.ae` files, demonstrating one leaf per
  language tree wherever an aeb SDK exists today.
- Surface the cross-language wiring questions Selenium would ask
  (e.g., is there real Java↔Python artifact sharing? Mostly no —
  each binding compiles independently; the cross-language behaviour
  is at runtime, over the WebDriver wire protocol).
- Document the **Ruby gap** — Selenium has 32 Ruby BUILD files and
  aeb has no Ruby SDK. The honest answer is "either add `lib/ruby`
  or skip Ruby."
- Document the **rules_jvm_external mismatch** — Selenium pins
  Maven deps via `rules_jvm_external`'s `maven_install.json`, not
  via Maven's BOM mechanism that aeb's `lib/maven` consumes. Mostly
  a translation problem; the underlying coordinates are equivalent.

## Per-language status

### Python (`py/`)

Selenium's Python client has the simplest leaf: a single
`pyproject.toml`-driven setuptools package. The grammar gap that
PyTorch didn't expose — **`python.package(b)` regenerates and
overwrites pyproject.toml destructively** — surfaces cleanly here.
Selenium's `py/pyproject.toml` ships hand-tuned `[build-system]`
(`setuptools-rust`), `[project]` classifiers + license-files, and a
`[tool.setuptools-rust]` section that builds the Selenium Manager
Rust binary into the wheel. Regenerating would silently drop all
of that.

**Gap closed in a follow-up:** `python.package_existing(b)` (added
to lib/python alongside this migration) runs `python -m build`
against the upstream pyproject.toml unchanged. Setter
`pyproject_path(...)` overrides the default `<source_dir>/pyproject.toml`.

Demo: `itests/selenium/py/.dist.ae` calls `python.package_existing(b)`
with no setters. Shape is valid (ae build clean); end-to-end
execution needs the Rust toolchain on PATH for setuptools-rust to
compile the Selenium Manager binary.

### Java (`java/`)

Selenium uses **rules_jvm_external** for Maven dep resolution.
`maven_install.json` is the pinned closure. Each `java_library`
target declares deps via Bazel labels like
`artifact("org.jspecify:jspecify")` plus internal labels like
`//java/src/org/openqa/selenium:core`.

aeb's `lib/java` + `lib/maven` SDK pair handles the same problem
through a different mechanism: a `.bom.ae` declares the BOM and
repositories, then `build.dep(b, "org.coord:artifact")` routes to
Maven; `build.dep(b, "../sibling/.build.ae")` routes to internal
file-path deps. The model is equivalent, the **translation** is
mechanical:

- `rules_jvm_external` artifact → aeb Maven coord with explicit
  version (Selenium's coords sometimes lack version; resolved from
  `maven_install.json`'s pinned closure).
- Bazel internal label → relative `.build.ae` path.
- `java_library` → `java.javac(b)` with no source_layout (the
  Bazel-flat layout matches lib/java's default mode: *.java in the
  same dir as .build.ae).

**Three leaves converted, two patterns demonstrated:**

| Leaf | Pattern | Sources | Externals |
|------|---------|---------|-----------|
| `status/.build.ae`        | inline `dep(b, "g:a:v")` | 2 | jspecify |
| `io/.build.ae`            | `load_bom_file` + inline `dep(b, "g:a:v")` | 7 | jspecify |
| `grid/jmx/.build.ae`      | `load_bom_file` + inline `dep(b, "g:a:v")` | 5 | jspecify |

The new `java/selenium-deps.bom.ae` file is the hand-authored
**pin set** for selenium-java's headline third-party coords (18
coords today: jspecify, guava, byte-buddy, opentelemetry-*, jackson,
slf4j-*, jcommander, gson, jackson-databind, redis, protobuf-java,
javaparser-core, jboss-marshalling). Each coord pinned to the
version upstream uses, transcribed from `java/maven_install.json` at
fetch-upstream.sh snapshot time. Leaves consume it via
`maven.load_bom_file` from `lib/maven`.

**Why not bridge `maven_install.json`:** see
`itests/selenium/Aeb_vs_Bazel.md` for the full musing. The short
form: aeb doesn't parse external config formats (LLM.md's
load-bearing principle). The `.bom.ae` is the idiomatic-aeb shape;
it's more verbose at scale but every dep edge is a literal string
in source, greppable, and translatable without consulting
rules_jvm_external's data model.

Converting the rest of Java is mechanical work that doesn't add
proof-of-concept value beyond what three leaves already show.

**Two-import gotcha:** all three leaves declare both
`import maven` and `import maven (load_bom_file)`. The bare-setter
two-import rule (LLM.md) applies because aeb's orchestrator-generated
file only inherits the selective import; lib/java's internal
`maven.classpath()` calls then can't resolve without the bare
`import maven` also being declared at the leaf.

### Ruby (`rb/`)

**`lib/ruby` now exists** (added downstream of this migration). 32
`BUILD.bazel` files use `rules_ruby_gem` shapes plus `ruby_library`
/ `ruby_test`. The aeb SDK ships `ruby.install(b)` (bundle install),
`ruby.rspec(b)` (bundle exec rspec), `ruby.rubocop(b)`, and
`ruby.gem(b)` (gem build from a .gemspec). Project-local gem
isolation via `.aeb/bundle/`, parallel to `lib/python`'s
`.aeb/venv/`.

A `rb/.build.ae` plus `rb/.tests.ae` is the next-natural conversion
target; selenium's Gemfile + selenium-webdriver.gemspec map directly
onto the new grammar. Not converted in this pass, but the
**SDK-side gap is closed** — running `aeb` against a hand-written
`.build.ae` for `rb/` would work once the Ruby toolchain plus
required browsers are present.

**Now converted:** `rb/.build.ae` calls `ruby.install(b)` then
`ruby.gem(b) { gemspec("selenium-webdriver.gemspec") }`;
`rb/.tests.ae` calls `ruby.rspec(b)` + `ruby.rubocop(b)` with a
`build.dep` on the install step. Smoke run on this box reaches the
expected upstream-environmental failures:

  - `bundle install` ran (after a `lib/ruby` patch to use
    `bundle config set --local path` instead of the now-removed
    `--path=` flag; verified in `tests/test_ruby_cmd.ae`), then
    failed at `psych` native-gem compile (missing `libyaml-dev`
    on this Debian host).
  - `gem build selenium-webdriver.gemspec` requires LICENSE and
    NOTICE files in the rb/ directory, which upstream Bazel stages
    via `copy_file` rules from the repo root. aeb has no canonical
    `copy_file` SDK today; a `bash.run(b) { pre_command("cp ...") }`
    preamble would work, but isn't wired here. Tracking as a
    pre-build-staging gap (see also the `./go format` note in
    `Aeb_vs_Bazel.md`).

Both failures are environmental / upstream-staging, not SDK gaps.
The aeb-side grammar is verified-correct in
`tests/test_ruby_cmd.ae` (26 assertions).

### JavaScript/Node (`javascript/`)

Mix of pnpm workspaces (`selenium-webdriver/`) and Bazel-driven
JS targets using `aspect_rules_js`. **Two converters landed** in
a follow-up pass:

- `itests/selenium/.build.ae` — `pnpm.install(b)` with
  `frozen_lockfile()` at the workspace root. Honours the upstream
  `pnpm-workspace.yaml` + `pnpm-lock.yaml`.
- `itests/selenium/javascript/selenium-webdriver/.build.ae` —
  `pnpm.run(b, "lint")` for the eslint script declared in the
  subpackage's `package.json`. `build.dep` edge on the workspace
  install so node_modules is in place first.

The Bazel-rules-js-specific bits (rollup config inside Bazel,
esbuild pipelines) would still need per-pipeline conversion;
neither converted here.

SDK additions this required: `pnpm.install(b)` and `pnpm.run(b, script)`
(closure-DSL with `frozen_lockfile()` and repeatable
`script_arg(...)`). See `tests/test_pnpm_cmd.ae`.

### .NET (`dotnet/`)

10 BUILD files. **One leaf converted** in a follow-up:
`itests/selenium/dotnet/src/webdriver/.build.ae` runs
`dotnet.build_project_existing(b)` against the upstream
`Selenium.WebDriver.csproj` (Microsoft.NET.Sdk, custom signing
via `Selenium.snk`, AssemblyInfo templating, paket-pinned
NuGet deps).

SDK addition this required: `dotnet.build_project_existing(b)` —
non-destructive variant that doesn't regenerate
`.{name}.generated.csproj`. Closes the same shape of gap that
PyTorch surfaced for python.package and Selenium surfaced for
rust.cargo_project. Setter `csproj_path(...)` for non-default
locations. See `tests/test_dotnet_cmd.ae`.

### Rust (`rust/`)

3 BUILD files. Selenium's Rust subtree builds the **Selenium
Manager** binary that the Python `selenium` package vendors via
`setuptools-rust`. **Binary crate converted** in a follow-up:
`itests/selenium/rust/.build.ae` runs
`rust.cargo_project_existing(b)` with `binary_name("selenium-manager")`
against the upstream `Cargo.toml`. Cargo's transitive dep
resolution runs unchanged; the `Cargo.lock` is honoured.

SDK addition this required: `rust.cargo_project_existing(b)` —
non-destructive variant that doesn't regenerate `Cargo.toml` from
setters. Optional setter `binary_name(name)` writes a
`cargo_binary` artifact for downstream consumers (e.g., the Python
wheel that vendors selenium-manager via setuptools-rust would
read this path). See `tests/test_cargo_cmd.ae`.

**Test rules:** `rust.cargo_test_existing(b)` added as the pair
to `cargo_project_existing` — runs `cargo test` against the
upstream Cargo.toml. Tests in `rust/tests/` are picked up by
cargo automatically. Not wired into a separate `rust/.tests.ae`
in this pass, but the grammar is available.

### C++ (`cpp/`)

2 BUILD files; mostly the legacy IEDriver (Windows-only). Not
relevant on this Linux dev box; skipped.

## Codegen surface (`py/generate_*.py`)

Selenium has three Python codegen scripts:

- `py/generate.py` — the original DevTools Protocol generator
  (forked from python-chrome-devtools-protocol). Reads
  `common/devtools/*/browser_protocol.json` + `js_protocol.json`,
  writes the CDP Python bindings.
- `py/generate_bidi.py` — reads WebDriver BiDi CDDL specs (which
  Bazel fetches as external repos via `MODULE.bazel`'s
  `bazel_dep` / `http_file` rules), writes BiDi command modules.
- `py/generate_api_module_listing.py` — walks `selenium/` and emits
  `py/docs/source/api.rst`. Reads its inputs by walking the
  filesystem (no explicit input declaration in the Bazel rule
  either).

**Natural fits for `python.codegen`**, the builder added alongside
the PyTorch migration. The first two map cleanly: declared YAML/JSON
inputs, declared `.py` outputs. The third doesn't — it walks
arbitrary source trees and doesn't take args. It would need either
a `codegen_input_dir(b, "selenium")` (lossy — every .py change
re-runs the gen) or a small refactor of the upstream script to take
an explicit input list.

**Now converted:** `itests/selenium/py/.api-listing-codegen.ae`
drives `generate_api_module_listing.py` via `python.codegen(b)`
with `codegen_input_dir("selenium")` + `codegen_output("docs/source/api.rst")`.
End-to-end verified on this snapshot: deleting `api.rst` and
running `aeb .api-listing-codegen.ae` regenerates it (5.8 KB of
Sphinx autodoc directives covering 30+ selenium submodules); a
subsequent `touch selenium/__init__.py` triggers a re-run.

This required wiring `codegen_input_dir` into `_codegen_can_skip` —
the MVP gap recorded in lib/python that ignored directory inputs
for staleness. Now the staleness check walks every input_dir
recursively via `_dir_newest_mtime` (Aether-native `dir.list` +
`file.mtime`, no shell-out to `find -printf`), folding the newest
file mtime in the tree into the standard "newest input vs oldest
output" comparison. Cross-platform; works on macOS without the
GNU-find dependency. See `lib/python/module.ae` `_dir_newest_mtime`
+ `_codegen_can_skip` extension.

## What this pass actually produced

Running tally across the multi-session conversion:

| File / Artifact                                                            | Status   |
|----------------------------------------------------------------------------|----------|
| `itests/selenium/AEB_MIGRATION_STATUS.md`                                  | This file. |
| `itests/selenium/Aeb_vs_Bazel.md`                                          | Polyglot-DAG musing doc, sibling to the PyTorch one. Includes the "why not bridge maven_install.json" reasoning. |
| `itests/selenium/.build.ae`                                                | Workspace-root pnpm install (`pnpm.install` + `frozen_lockfile`). |
| `itests/selenium/java/selenium-deps.bom.ae`                                | Hand-pinned 18-coord BOM for the headline selenium-java third-party deps. |
| `itests/selenium/java/src/org/openqa/selenium/status/.build.ae`            | Java leaf #1: inline pinned dep. |
| `itests/selenium/java/src/org/openqa/selenium/io/.build.ae`                | Java leaf #2: BOM-loaded + inline pinned dep, 7 sources. |
| `itests/selenium/java/src/org/openqa/selenium/grid/jmx/.build.ae`          | Java leaf #3: BOM-loaded + inline pinned dep, 5 sources. |
| `itests/selenium/rb/.build.ae`                                             | Ruby leaf: `ruby.install` + `ruby.gem`. |
| `itests/selenium/rb/.tests.ae`                                             | Ruby tests: `ruby.rspec` + `ruby.rubocop`. |
| `itests/selenium/py/.dist.ae`                                              | `python.package_existing` (non-destructive wheel build). |
| `itests/selenium/py/.bidi-spec.ae`                                         | `fetch.file` of the CDDL spec, sha256-pinned. |
| `itests/selenium/py/.bidi-codegen.ae`                                      | `python.codegen` driving `generate_bidi.py`. |
| `itests/selenium/py/.api-listing-codegen.ae`                               | `python.codegen` with `codegen_input_dir` walking `selenium/` recursively. End-to-end verified. |
| `itests/selenium/javascript/selenium-webdriver/.build.ae`                  | `pnpm.run` for the eslint script. |
| `itests/selenium/dotnet/src/webdriver/.build.ae`                           | `dotnet.build_project_existing` against upstream csproj. |
| `itests/selenium/rust/.build.ae`                                           | `rust.cargo_project_existing` for selenium-manager binary. |

Plus SDK upgrades and unit-test additions (off-tree from
`itests/selenium/` but driven by this exercise):

| SDK upgrade                                                                | Where |
|----------------------------------------------------------------------------|-------|
| `python.codegen` honors `codegen_input_dir` in staleness check via `_dir_newest_mtime` | `lib/python/module.ae` |
| `lib/ruby` `bundle_install_cmd` switched to `bundle config set --local path` (bundler 2.x removed `--path=`) | `lib/ruby/module.ae` |
| `lib/fetch` extracted `_format_to_flags` + `_format_is_zip` pure helpers from inline format-override mapping | `lib/fetch/module.ae` |
| `lib/dotnet` extracted `_resolve_csproj_path` pure helper from inline csproj-path resolution | `lib/dotnet/module.ae` |

Unit-test additions (all pure command-string-builder assertions):

| Test file                              | Before → after assertions |
|----------------------------------------|---------------------------|
| `tests/test_python_codegen_cmd.ae`     | 21 → 26 |
| `tests/test_ruby_cmd.ae`               | 21 → 26 |
| `tests/test_dotnet_cmd.ae`             | 7  → 12 |
| `tests/test_fetch_cmd.ae`              | 27 → 43 |
| `tests/test_cargo_cmd.ae`              | 12 → 14 |

Full test suite remains green: **62 tests, 853 assertions**.

## How to drive a partial build

```bash
# Once: fetch the upstream snapshot
./itests/fetch-upstream.sh

# Compile the Java leaf:
cd itests/selenium/java/src/org/openqa/selenium/status
aeb .build.ae
```

**Verified on this snapshot:** the leaf compiles cleanly. `lib/maven`
resolves `org.jspecify:jspecify:1.0.0` from `~/.aeb/repo/`,
`lib/java` calls `javac` with the resolved classpath, writes
`HasReadyState.class` + `package-info.class` to
`target/classes/org/openqa/selenium/status/`. Both classfiles are
real Java 17 bytecode (`javap` shows the
`public interface org.openqa.selenium.status.HasReadyState` surface
intact).

## Gaps recorded by this pass

1. ~~`python.package_existing_pyproject` builder is missing.~~
   **Closed** — `python.package_existing(b)` added in a follow-up
   (`lib/python/module.ae`, `tests/test_python_cmd.ae` extended
   with setter-accumulation assertions). `itests/selenium/py/.dist.ae`
   is the demonstration target.
2. ~~`lib/ruby` doesn't exist; Selenium's Ruby tree can't be
   converted.~~ **Closed** — `lib/ruby` added in a follow-up
   (`tests/test_ruby_cmd.ae`, 21 assertions). Selenium's rb/
   conversion is now a mechanical .build.ae write, not an
   SDK-shaped gap.
3. ~~Selenium's external-fetch pattern (BiDi CDDL via Bazel
   `bazel_dep`/`http_file`) has no aeb analogue.~~ **Closed** —
   `lib/fetch` added. `fetch.file(b)` (sha256-verified download)
   and `fetch.archive(b)` (extract .tar.gz / .tar.bz2 / .tar.xz /
   .zip with strip_components + format-inference fallback).
   `itests/selenium/py/.bidi-spec.ae` demonstrates against the
   exact upstream pinning (118 KB CDDL fetched from
   `raw.githubusercontent.com/w3c/webref/<sha>/ed/cddl/`,
   sha256-verified). 27 assertions in `tests/test_fetch_cmd.ae`.
4. ~~`rules_jvm_external`'s `maven_install.json` pinning isn't
   directly readable by `lib/maven`.~~ **Closed by hand-authoring**
   instead of bridging: `java/selenium-deps.bom.ae` carries the
   pinned headline set. See `Aeb_vs_Bazel.md` § "Why aeb won't parse
   `maven_install.json`" — bridging an external config format would
   crack LLM.md's load-bearing principle. The hand-authored shape
   is the idiomatic-aeb answer.

5. **Pre-build file-staging gap.** Selenium's Bazel build uses
   `copy_file` rules to stage LICENSE / NOTICE / per-OS
   `selenium-manager` binaries into the rb/, py/, dotnet/ trees at
   build time. aeb has no canonical `lib/copy.file(b)` SDK; a
   `bash.run(b)` preamble works but isn't ergonomic. Roadmap item
   — would also subsume the `./go format`-shaped pre-build chains
   mentioned in `Aeb_vs_Bazel.md`.

6. **`./go format`-shaped multi-language formatter chains.** Same
   roadmap entry as #5; a `lib/format` SDK or a canonical phase
   shape would cover both.
