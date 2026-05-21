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

**One leaf converted in this pass:**
`java/src/org/openqa/selenium/status/.build.ae` — 2 .java files,
1 Maven dep (`org.jspecify:jspecify:1.0.0`), no internal deps.

Converting the rest of Java is mechanical work that doesn't add
proof-of-concept value beyond what one leaf already shows.

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

### JavaScript/Node (`javascript/`)

Mix of pnpm workspaces (`selenium-webdriver/`) and Bazel-driven
JS targets using `aspect_rules_js`. `lib/pnpm` covers the pnpm side;
`lib/ts` could cover TypeScript compilation. The
Bazel-rules-js-specific bits (rollup config inside Bazel, esbuild
pipelines) would need translation to direct pnpm script
invocation — a fit for `lib/pnpm`'s existing `pnpm.run(b, script)`
shape.

Not converted in this pass.

### .NET (`dotnet/`)

10 BUILD files. `lib/dotnet` handles the build shape (`dotnet build`
plus reference resolution); the conversion would be mechanical for
a leaf. Not converted in this pass.

### Rust (`rust/`)

3 BUILD files. Selenium's Rust subtree builds the **Selenium
Manager** binary that the Python `selenium` package vendors via
`setuptools-rust`. `lib/rust` handles cargo-based builds; the
Bazel side wraps `cargo` through `rules_rust`, so a translation to
`lib/rust` is direct.

Not converted in this pass.

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

Not converted in this pass; recorded as low-hanging fruit.

## What this pass actually produced

| File                                                                | Status   |
|---------------------------------------------------------------------|----------|
| `itests/selenium/AEB_MIGRATION_STATUS.md`                          | This file. |
| `itests/selenium/java/src/org/openqa/selenium/status/.build.ae`    | Single Java leaf, 2 sources, 1 Maven dep. Expected to compile clean given `org.jspecify:jspecify:1.0.0` resolves through `~/.m2`. |

The .build.ae is the demonstration; the migration status is the
honest accounting of what's deferred.

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
4. `rules_jvm_external`'s `maven_install.json` pinning isn't
   directly readable by `lib/maven`; translating selenium-scale
   Java deps would benefit from a converter that reads it.
