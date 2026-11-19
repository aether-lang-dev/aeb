# SDK ladder: what aeb does itself, per language

aeb's intent is to replace the per-language build tools, with a terse grammar
for each major language. Handing a whole step to Maven, Cargo, Gradle, MSBuild
and friends is meant to be the user's chosen fallback, not the default. The
feature table in the [README](../README.md) is by feature; this page is the same
truth by language: which rungs of the build ladder aeb climbs itself, and which
it hands to the language's own build tool.

Every cell below was graded from the SDK's code (`lib/<sdk>/module.ae`), not
from the README. The [appendix](#appendix-evidence) gives, for
every non-`none` cell, the line where the tool is invoked and the grammar entry
that reaches it. `tools/check-sdk-ladder.py` fails if the table, the appendix
and `lib/` drift apart.

## The rungs

| Rung | Meaning |
|---|---|
| compile | aeb invokes the compiler or interpreter toolchain (javac, kotlinc, tsc, cc, dmd, erlc, `nim c`, ...) on a source set it computed. |
| test | aeb runs the test runner and reads the result itself. |
| resolve | Transitive dependency resolution. |
| package | jar, wheel, crate, nupkg, binary, bundle. |
| publish | Upload to a registry. |
| incremental | Work skipped below whole-module granularity. `module-only` means only the content-addressed cache skips a whole module; `none` means no skipping at all. |
| cache | The SDK is wired into `lib/cache` (content-addressed, whole module). |
| coverage | The SDK offers a coverage step. |

## The grades

| Grade | Meaning |
|---|---|
| `aeb` | aeb does the step, driving the low-level tool: `javac`, `kotlinc`, `tsc`, `dmd`, `cc`, `erlc`, `pytest`, `jar`, its own resolver. |
| `lockfile` | resolve only: a native lockfile goes in, aeb does the rest. |
| `delegated` | A native build tool does the whole step: `cargo build`, `mvn`, `gradle`, `dotnet build` (MSBuild), `npm`/`pnpm run`, `go build`, `swift build`, `zig build`, `mix`, `cabal`, `gleam`, `moon`, `nimble`, `rebar3`, `jpm`, `ng build`. `go build` and `cargo build` count as build tools (graph plus compile), not compilers. |
| `none` | Not offered. |
| `n/a` | The rung does not apply. |

`x / y` in a cell means the SDK offers two forms, a direct one and a fallback
one; the first grade is the one named first in the `forms` column. For
`incremental` and `cache` the values are `aeb`, `delegated`, `module-only`,
`none` and `yes`/`no`. Nothing in any SDK publishes, so `publish` is `none`
throughout, which agrees with the README ("Artifact publishing: TODO").
`coverage` is `delegated` only for `aether` (`AEB_COVERAGE` passes `--coverage`
to `ae build`).

## The table

Rows are SDK directories under `lib/`. Ecosystem pieces (`maven`, `pnpm`,
`jest`, `webpack`, `angular`) have their own rows because they have their own
directories; read them with their language (`maven` with the JVM languages,
the other four with `ts`/`javascript`).

| SDK | compile | test | resolve | package | publish | incremental | cache | coverage | forms |
|---|---|---|---|---|---|---|---|---|---|
| `aether` | delegated / aeb | aeb | none | aeb | none | module-only / delegated | yes | delegated | direct (aetherc + cc): `aether.program` with regen/extra_source/link_flag; default: `aether.program`/`shared_lib`/`csrc` shell out to `ae build` |
| `angular` | aeb / delegated | none | delegated | none | none | none | no | none | direct: `angular.ngc`; fallback: `angular.ng_build` |
| `bash` | none | aeb | none | none | none | none | no | none |  |
| `c` | aeb | aeb | none | aeb | none | module-only | no | none |  |
| `clojure` | aeb | aeb | aeb | aeb | none | module-only | yes | none |  |
| `cpp` | aeb | aeb | none | aeb | none | none | no | none |  |
| `crystal` | none | delegated | none | none | none | none | no | none |  |
| `d` | aeb | aeb | none | none | none | none | no | none |  |
| `dart` | aeb | aeb | delegated | aeb | none | none | no | none |  |
| `dotnet` | delegated | delegated | delegated | delegated | none | delegated | yes | none | both forms delegated: `dotnet.build_project` (generated csproj), `dotnet.build_project_existing` |
| `elixir` | delegated | delegated | delegated | none | none | delegated | no | none |  |
| `erlang` | aeb / delegated | aeb / delegated | none | none | none | none | no | none | direct: `erlang.nif` (cc + erlc), `erlang.eunit` with escript/test_module; fallback: `erlang.compile`, default `erlang.eunit` (rebar3) |
| `gleam` | delegated | delegated | delegated | none | none | delegated | no | none |  |
| `go` | delegated | delegated | delegated | delegated | none | delegated | yes | none |  |
| `groovy` | aeb | aeb | aeb | none | none | module-only | yes | none |  |
| `haskell` | delegated | delegated | delegated | none | none | delegated | no | none |  |
| `janet` | delegated | aeb / delegated | delegated | aeb | none | none | no | none | direct: `janet.test` with script(); fallback: `janet.test` without script (jpm test), `janet.deps`/`jpm_build` |
| `java` | aeb / delegated | aeb / delegated | aeb | aeb | none | module-only | yes | none | direct: `java.javac`, `javac_test`, `junit5`; fallback: `java.mvn_project` |
| `javascript` | delegated | delegated | delegated | delegated | none | none | no | none |  |
| `jest` | none | aeb | delegated | none | none | none | no | none |  |
| `julia` | none | aeb | none | none | none | none | no | none |  |
| `kotlin` | aeb | aeb | aeb | none | none | module-only | yes | none |  |
| `lfe` | aeb | aeb | none | none | none | none | no | none |  |
| `lua` | aeb | aeb | none | none | none | none | no | none | `lua.c_extension` (cc), `lua.test` (busted), `lua.conformance` |
| `maven` | n/a | delegated | aeb | delegated | none | delegated | yes | none | direct: `maven.resolve`; fallback: `maven.test`, `maven.install` (mvn) |
| `moonbit` | delegated | delegated | delegated | none | none | delegated | no | none |  |
| `nim` | aeb / delegated | aeb / delegated | delegated | delegated | none | delegated | no | none | direct: `nim.build` and `nim.test` with test_file() (`nim c`, `nim c -r`); fallback: `nim.build` and `nim.test` without test_file (nimble) |
| `pharo` | none | aeb / delegated | delegated | none | none | none | no | none | direct: `pharo.sunit`; fallback: `pharo.test` (project script) |
| `php` | none | aeb | none | none | none | none | no | none |  |
| `pnpm` | delegated | none | delegated / lockfile | none | none | none | no | none | `pnpm.resolve` (union add), `pnpm.install` (honours pnpm-lock.yaml), `pnpm.run` |
| `python` | none | aeb / delegated | delegated | delegated | none | none | no | none | direct: `python.pytest`; fallback: `python.test`, `python.package_existing` |
| `ruby` | none | aeb | delegated | aeb | none | none | no | none |  |
| `rust` | delegated | delegated | delegated | delegated | none | delegated | yes | none | both forms delegated: `rust.cargo_project` (generated Cargo.toml), `rust.cargo_project_existing` |
| `scala` | aeb | aeb | aeb | aeb | none | module-only | yes | none |  |
| `swift` | delegated | delegated | delegated | delegated | none | delegated | no | none |  |
| `ts` | aeb | aeb | delegated | none | none | module-only | yes | none | `ts.tsc` (cached), `ts.tsc_files`, `ts.mocha` |
| `webpack` | none | none | delegated | aeb | none | none | no | none |  |
| `zig` | delegated | delegated | delegated | delegated | none | delegated | no | none |  |

Not languages (no row): `agent`, `approval`, `bldr` (the core API every SDK
uses), `brew`, `cache`, `container`, `copy`, `fetch`, `meta`,
`provision`, `sandbox`, `veto`, `veto_trace_os`, `webhook`.

## Summary

Grades here are for the direct (non-fallback) form where an SDK has two.

**Fully `aeb` on compile + test + resolve + package:** `java`, `scala`,
`clojure`. All three resolve through `lib/maven` (aeb's own resolver jar, Eclipse
Aether, not `mvn`).

**`aeb` on compile + test + resolve, no package step:** `kotlin`, `groovy`.

**`aeb` on compile + test + package, no resolver (there is no dependency model):**
`c`, `cpp`. `d` and `lfe` are `aeb` on compile + test only; `lua` is `aeb` on
a C-extension compile and on test (busted/interpreter) only.

**Test-only (no compile step aeb performs):** `bash`, `julia`, `php`, `jest`.
`crystal` is test-only but delegated (`crystal spec`).

**Mixed (some rungs `aeb`, some delegated):**

| SDK | aeb | delegated |
|---|---|---|
| `ts` | compile (`tsc`), test (mocha via node) | resolve (`pnpm add`) |
| `dart` | compile (`dart compile`), test, package | resolve (`dart pub get`) |
| `python` | test (`pytest` in an aeb venv) | resolve (`pip`), package (`python -m build`), no compile |
| `ruby` | test, package (`gem build`) | resolve (`bundle install`), no compile |
| `erlang` | `erlang.nif`: cc + `erlc`; escript tests | `erlang.compile`, default `eunit` (`rebar3`) |
| `nim` | `nim c -r` when `test_file()` is set | default: `nimble build`/`test`, resolve, package |
| `janet` | test with `script()`, package (stages files) | compile, resolve (`jpm`), test without `script()` |
| `pharo` | test (`pharo.sunit`) | baseline load (Metacello) |
| `aether` | manual path (aetherc + C compiler), test, package | default path: `ae build` |
| `angular` | `ngc` | `ng build`, resolve (pnpm) |
| `webpack` | package (runs `webpack`) | resolve (pnpm) |

**Fully delegated:** `rust`, `go`, `dotnet`, `swift`, `zig`, `elixir`, `haskell`,
`gleam`, `moonbit`, `javascript`. (`pnpm` is the delegated resolver/script
runner for the JS family.) For these, aeb adds the graph, the cache (where
wired), result capture and cross-language artifact handoff, but not the
compile.

### What a direct form would need

Brief and factual; this is a map, not a design.

| SDK | Delegated to | Direct form would need |
|---|---|---|
| `rust` | `cargo build/check/test` | `rustc` per crate with `--extern`/`-L` for every dependency; a resolver (cargo's index/registry, `Cargo.lock` as the lockfile input); `build.rs` and proc-macros must be built and run during the build (code execution at build time, build-script output directives). |
| `go` | `go build`, `go test`, `go mod tidy` | `go tool compile`/`link` driven per package in import order; `go.mod`/`go.sum` as lockfile input (module download and verification); cgo and `go:generate` run build-time code. |
| `dotnet` | `dotnet build/test` (restore implicit) | `csc` (Roslyn) with references; NuGet resolution from `packages.lock.json` or aeb's own resolver; MSBuild targets, analyzers and source generators run in the build. |
| `swift` | `swift package resolve/build/test` | `swiftc` per module in dependency order; `Package.resolved` as lockfile; `Package.swift` manifests, plugins and macros execute code. |
| `zig` | `zig build`, `zig build test` | `zig build-exe`/`build-lib` on a computed root; `build.zig.zon` hashes are already a lockfile; `build.zig` is arbitrary Zig run at build time. |
| `elixir` | `mix compile/test/deps.get` | `elixirc` over a computed file set; `mix.lock` as lockfile; `mix.exs` and compile-time macros run code. |
| `haskell` | `cabal build/test` | `ghc --make` or per-module `ghc -c`; resolver for Hackage (`cabal.project.freeze` as lockfile); `Setup.hs` and Template Haskell run code. |
| `gleam` | `gleam build/test/deps` | `gleam compile-package`-level driving plus `erlc`/`node`; `manifest.toml` as lockfile; target-specific FFI. |
| `moonbit` | `moon check/test/build/install` | `moonc` on a computed package graph; `moon.mod.json` and mirrors for resolution; `moon.pkg.json` prebuild rules. |
| `javascript` | `npm install/test/pack` | No compiler; the rung is a resolver (`package-lock.json` as lockfile) plus running tests; npm lifecycle scripts (pre/postinstall) run unsandboxed. |
| `ts` (resolve) | `pnpm add` | A lockfile reader for `pnpm-lock.yaml` and a tarball fetcher; install scripts of dependencies. |
| `python` | `pip`, `python -m build` | A wheel resolver (PyPI JSON/simple index, hash-pinned requirements as lockfile); a PEP 517 build runs the backend (`setup.py`) as arbitrary code. No compile step to add (`py_compile` is optional). |
| `ruby` | `bundle install` | A resolver over `Gemfile.lock`; `gemspec` is Ruby code and native extensions run `extconf.rb`. |
| `dart` (resolve) | `dart pub get` | Resolution from `pubspec.lock`; `build_runner` generators run code. |
| `nim` (default) | `nimble` | `nim c` with `--path` per dependency (already used with `test_file()`); nimble lockfile; nimscript tasks. |
| `erlang` (project form) | `rebar3` | `erlc` plus `.app` resolution (exists for `erlang.nif`); `rebar.lock` as lockfile; rebar3 plugins, pre-hooks, parse transforms. |
| `janet` | `jpm` | `janet` on a computed load path; native C modules need `cc`; `project.janet` is Janet code. |
| `aether` (default) | `ae build` | The manual path already exists (aetherc then `$CC`); `regen` runs `aetherc --emit=lib` at build time. |
| `angular` | `ng build` | `ngc` already exists as the direct form; the app build (bundling, `angular.json` configuration) has no direct form. |
| `crystal` | `crystal spec` | `crystal build` on a computed entry file; `shard.lock` as lockfile; macros run at compile time. |
| `java` (fallback) | `mvn` via `mvn_project` | Already replaced by `javac` + `lib/maven`; annotation processors run inside `javac`. |

## Appendix: evidence

One block per SDK: its grammar entries, then one row per non-`none` cell. The
`evidence` column is `file:line`; the `tool string` is a literal substring of
that line. `tools/check-sdk-ladder.py` re-verifies every row. An extra `cache`
row cites the line that calls `lib/cache`.

### aether

Grammar: aether.program, aether.program_test, aether.driver_test, aether.csrc, aether.shared_lib, aether.emit_binary_package, aether.tinygo_lib, aether.binary_under_test, aether.fixture_seed, aether.fixture_server

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| aether | compile | delegated | lib/aether/module.ae:1759 | `${ae_bin} build` | aether.program (default shell-out) |
| aether | compile | aeb | lib/aether/module.ae:2778 | `${aetherc}` | aether.program (manual aetherc+gcc path) |
| aether | compile | aeb | lib/aether/module.ae:1975 | `${_link_cc()}` | aether.program (manual link) |
| aether | compile | aeb | lib/aether/module.ae:1857 | `${aetherc} --emit=lib` | aether regen (manual path) |
| aether | test | aeb | lib/aether/module.ae:3745 | `test_run_cmd` | aether.program_test |
| aether | package | aeb | lib/aether/module.ae:3638 | `cryptography.sha256_file` | aether.emit_binary_package |
| aether | coverage | delegated | lib/aether/module.ae:1692 | `AEB_COVERAGE` | aether.program (ae build --coverage) |
| aether | incremental | delegated | lib/aether/module.ae:1759 | `${ae_bin} build` | aether.program (default shell-out) |
| aether | cache | yes | lib/aether/module.ae:2699 | `cache.available` | aether.program (manual path) |
| aether | cache | yes | lib/aether/module.ae:2979 | `cache.put` | aether.program (manual path) |

### angular

Grammar: angular.ngc, angular.ng_build, angular.tsconfig, angular.skip_lib_check

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| angular | compile | aeb | lib/angular/module.ae:30 | `${ngc_bin}` | angular.ngc |
| angular | compile | delegated | lib/angular/module.ae:47 | `${ng_bin} build` | angular.ng_build |
| angular | resolve | delegated | lib/angular/module.ae:64 | `pnpm.resolve` | angular.ngc |

### bash

Grammar: bash.test, bash.run, bash.fixture_seed, bash.fixture_server

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| bash | test | aeb | lib/bash/module.ae:328 | `"bash ${script_path}"` | bash.test |
| bash | test | aeb | lib/bash/module.ae:748 | `bash_chain_cmd` | bash.test |

### c

Grammar: c.compile, c.program, c.tests, c.aether_objects, c.generated_header (plus DSL setters sources/include/cflag/cc/output_file)

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| c | compile | aeb | lib/c/module.ae:480 | `${compiler}` | c.compile |
| c | compile | aeb | lib/c/module.ae:908 | `${compiler}` | c.program |
| c | test | aeb | lib/c/module.ae:1080 | `bldr._sh(cmd)` | c.tests |
| c | package | aeb | lib/c/module.ae:1001 | `${compiler}` | c.program |
| c | incremental | module-only | lib/c/module.ae:465 | `_sources_changed` | c.compile |

### clojure

Grammar: clojure.compile, clojure.run_main, clojure.test, clojure.uberjar; setters main_ns, min_jdk, skip_below_jdk, jvm_flag, test_timeout, source_layout, output_jar

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| clojure | compile | aeb | lib/clojure/module.ae:78 | `clojure.main` | clojure.compile |
| clojure | test | aeb | lib/clojure/module.ae:91 | `clojure.test/run-tests` | clojure.test |
| clojure | resolve | aeb | lib/clojure/module.ae:279 | `maven.classpath(ctx)` | clojure.compile |
| clojure | package | aeb | lib/clojure/module.ae:119 | `jar cfM` | clojure.uberjar |
| clojure | incremental | module-only | lib/clojure/module.ae:295 | `cache.available()` | clojure.compile |
| clojure | cache | yes | lib/clojure/module.ae:336 | `cache.put(` | clojure.compile |

### cpp

Grammar: cpp.program, cpp.tests (plus DSL source/include/cxxflag/cxx/std/output)

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| cpp | compile | aeb | lib/cpp/module.ae:138 | `'${cxx}'` | cpp.program |
| cpp | compile | aeb | lib/cpp/module.ae:186 | `"c++"` | cpp.program |
| cpp | test | aeb | lib/cpp/module.ae:337 | `_sh_tee` | cpp.tests |
| cpp | package | aeb | lib/cpp/module.ae:138 | `-o '${out}'` | cpp.program |

### crystal

Grammar: crystal.test, crystal.generate_manifest (emits shard.yml)

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| crystal | test | delegated | lib/crystal/module.ae:109 | `spec` | crystal.test |

### d

Grammar: d.test, d.consumer_example (no standalone build/package builder)

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| d | compile | aeb | lib/d/module.ae:102 | `-run` | d.test |
| d | test | aeb | lib/d/module.ae:67 | `"dmd"` | d.test |
| d | test | aeb | lib/d/module.ae:139 | `run_test_cmd` | d.test |

### dart

Grammar: dart.pub_get, dart.analyze, dart.test, dart.test_existing, dart.compile, dart.codegen, dart.consumer_example, dart.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| dart | compile | aeb | lib/dart/module.ae:375 | `compile ${fmt}` | dart.compile |
| dart | package | aeb | lib/dart/module.ae:375 | `compile ${fmt}` | dart.compile (exe/snapshot output) |
| dart | test | aeb | lib/dart/module.ae:333 | `test${args_part}` | dart.test |
| dart | test | aeb | lib/dart/module.ae:975 | `"dart test"` | dart.test_existing |
| dart | resolve | delegated | lib/dart/module.ae:302 | `pub get` | dart.pub_get |

### dotnet

Grammar: dotnet.build_project, dotnet.build_project_existing, dotnet.test, dotnet.test_existing, dotnet.pack, dotnet.nuget_registry, dotnet.nuget_vendored

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| dotnet | compile | delegated | lib/dotnet/module.ae:165 | `dotnet build` | dotnet.build_project |
| dotnet | compile | delegated | lib/dotnet/module.ae:165 | `dotnet build` | dotnet.build_project_existing |
| dotnet | test | delegated | lib/dotnet/module.ae:191 | `dotnet test` | dotnet.test |
| dotnet | test | delegated | lib/dotnet/module.ae:1268 | `dotnet test` | dotnet.test_existing |
| dotnet | resolve | delegated | lib/dotnet/module.ae:165 | `dotnet build` | dotnet.build_project (implicit restore; nuget_registry only declares) |
| dotnet | package | delegated | lib/dotnet/module.ae:200 | `dotnet pack` | dotnet.pack |
| dotnet | incremental | delegated | lib/dotnet/module.ae:165 | `dotnet build` | dotnet.build_project |
| dotnet | cache | yes | lib/dotnet/module.ae:606 | `cache.get` | dotnet.build_project |
| dotnet | cache | yes | lib/dotnet/module.ae:634 | `cache.put` | dotnet.build_project |

### elixir

Grammar: elixir.compile, elixir.test, elixir.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| elixir | compile | delegated | lib/elixir/module.ae:216 | `mix compile` | elixir.compile |
| elixir | test | delegated | lib/elixir/module.ae:190 | `mix test` | elixir.test |
| elixir | resolve | delegated | lib/elixir/module.ae:184 | `mix deps.get` | elixir.test (deps_get_first) |
| elixir | incremental | delegated | lib/elixir/module.ae:216 | `mix compile` | elixir.compile |

### erlang

Grammar: erlang.nif, erlang.compile, erlang.eunit, erlang.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| erlang | compile | aeb | lib/erlang/module.ae:328 | `${cc} -O2 -fPIC` | erlang.nif |
| erlang | compile | aeb | lib/erlang/module.ae:350 | `erlc -o` | erlang.nif |
| erlang | compile | delegated | lib/erlang/module.ae:395 | `rebar3 compile` | erlang.compile |
| erlang | test | delegated | lib/erlang/module.ae:409 | `rebar3 eunit` | erlang.eunit |
| erlang | test | aeb | lib/erlang/module.ae:459 | `erl -noshell` | erlang.eunit (test module form) |
| erlang | test | aeb | lib/erlang/module.ae:162 | `escript` | erlang.eunit (escript form) |

### gleam

Grammar: gleam.deps, gleam.check, gleam.test, gleam.test_existing, gleam.build, gleam.codegen, gleam.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| gleam | compile | delegated | lib/gleam/module.ae:307 | `build${target_flag}` | gleam.build |
| gleam | test | delegated | lib/gleam/module.ae:301 | `test${target_flag}` | gleam.test |
| gleam | test | delegated | lib/gleam/module.ae:840 | `"gleam test"` | gleam.test_existing |
| gleam | resolve | delegated | lib/gleam/module.ae:289 | `deps download` | gleam.deps |
| gleam | incremental | delegated | lib/gleam/module.ae:307 | `build${target_flag}` | gleam.build |

### go

Grammar: go.go_build, go.go_test, go.check, go.generate_manifest (emits go.mod), go.consumer_example

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| go | compile | delegated | lib/go/module.ae:151 | `go build` | go.go_build |
| go | compile | delegated | lib/go/module.ae:376 | `go build` | go.check |
| go | test | delegated | lib/go/module.ae:232 | `go test` | go.go_test |
| go | resolve | delegated | lib/go/module.ae:448 | `go mod tidy` | go.go_build |
| go | package | delegated | lib/go/module.ae:151 | `go build` | go.go_build |
| go | incremental | delegated | lib/go/module.ae:290 | `go build` | go.go_build |
| go | cache | yes | lib/go/module.ae:432 | `cache.get` | go.go_build |

### groovy

Grammar: groovy.groovyc, groovy.groovyc_test; setters source_layout, target_bytecode, min_groovy, min_jdk, skip_below_groovy, skip_below_jdk, main_class, run_script, jvm_flag

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| groovy | compile | aeb | lib/groovy/module.ae:119 | `groovyc_bin` | groovy.groovyc |
| groovy | compile | aeb | lib/groovy/module.ae:657 | `groovyc_cmd(` | groovy.groovyc_test |
| groovy | test | aeb | lib/groovy/module.ae:765 | `run_cmd` | groovy.groovyc_test |
| groovy | test | aeb | lib/groovy/module.ae:604 | `groovy.ui.GroovyMain` | groovy.groovyc_test |
| groovy | resolve | aeb | lib/groovy/module.ae:296 | `maven.classpath(ctx)` | groovy.groovyc |
| groovy | incremental | module-only | lib/groovy/module.ae:315 | `cache.available()` | groovy.groovyc |
| groovy | cache | yes | lib/groovy/module.ae:358 | `cache.put(` | groovy.groovyc |

### haskell

Grammar: haskell.build, haskell.test, haskell.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| haskell | compile | delegated | lib/haskell/module.ae:181 | `cabal build` | haskell.build |
| haskell | test | delegated | lib/haskell/module.ae:205 | `cabal test` | haskell.test |
| haskell | resolve | delegated | lib/haskell/module.ae:181 | `cabal build` | haskell.build |
| haskell | incremental | delegated | lib/haskell/module.ae:181 | `cabal build` | haskell.build |

### janet

Grammar: janet.run, janet.test, janet.deps, janet.install, janet.jpm_build, janet.package

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| janet | test | aeb | lib/janet/module.ae:127 | `'${janet}' '${scr}'` | janet.test / janet.run |
| janet | test | delegated | lib/janet/module.ae:236 | `"test"` | janet.test (no script) |
| janet | compile | delegated | lib/janet/module.ae:342 | `"build", "build"` | janet.jpm_build |
| janet | resolve | delegated | lib/janet/module.ae:318 | `"deps", "deps"` | janet.deps |
| janet | package | aeb | lib/janet/module.ae:369 | `cp -f` | janet.package |

### java

Grammar: java.javac, java.javac_test, java.junit, java.junit5, java.java_main, java.package_jar, java.shade (setter inside a builder block, uses jar cfM), java.thin_jar, java.jar_vendored, java.jar_pinned, java.mvn_repo, java.jar_registry_finalize, java.mvn_project, java.consumer_example; setters incl. release, select_jdk, processor, processor_path, source_layout, classpath_file

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| java | compile | aeb | lib/java/module.ae:240 | `javac_bin = "javac"` | java.javac |
| java | compile | aeb | lib/java/module.ae:1415 | `javac_cmd(` | java.javac_test |
| java | compile | delegated | lib/java/module.ae:705 | `"compile"` | java.mvn_project |
| java | test | aeb | lib/java/module.ae:391 | `org.junit.runner.JUnitCore` | java.junit |
| java | test | aeb | lib/java/module.ae:1709 | `org.junit.platform.console.ConsoleLauncher` | java.junit5 |
| java | test | aeb | lib/java/module.ae:1851 | `-ea` | java.java_main |
| java | test | delegated | lib/java/module.ae:718 | `"test"` | java.mvn_project |
| java | resolve | aeb | lib/java/module.ae:964 | `maven.classpath(ctx)` | java.javac |
| java | resolve | aeb | lib/java/module.ae:624 | `cryptography.sha256_file` | java.jar_pinned |
| java | package | aeb | lib/java/module.ae:1336 | `jar --create` | java.package_jar |
| java | package | aeb | lib/java/module.ae:2046 | `jar cfM` | java.shade |
| java | package | aeb | lib/java/module.ae:2160 | `jar cfM` | java.thin_jar |
| java | incremental | module-only | lib/java/module.ae:1055 | `cache.available()` | java.javac |
| java | cache | yes | lib/java/module.ae:1065 | `cache.get(` | java.javac |

### javascript

Grammar: javascript.build, javascript.test, javascript.pack, javascript.consumer_example, javascript.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| javascript | compile | delegated | lib/javascript/module.ae:156 | `npm install` | javascript.build |
| javascript | test | delegated | lib/javascript/module.ae:171 | `npm test` | javascript.test |
| javascript | test | delegated | lib/javascript/module.ae:138 | `npx jest` | javascript.test (jest_on) |
| javascript | resolve | delegated | lib/javascript/module.ae:130 | `npm install` | javascript.test/pack npm_install |
| javascript | package | delegated | lib/javascript/module.ae:251 | `npm pack` | javascript.pack |

### jest

Grammar: jest.test, jest.timeout

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| jest | test | aeb | lib/jest/module.ae:27 | `${jest_bin}` | jest.test |
| jest | resolve | delegated | lib/jest/module.ae:51 | `pnpm.resolve` | jest.test |

### julia

Grammar: julia.test, julia.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| julia | test | aeb | lib/julia/module.ae:173 | `--color=no` | julia.test |

### kotlin

Grammar: kotlin.kotlinc, kotlin.kotlinc_test, kotlin.kotlin_test; setters jvm_target, api_version, language_version, source_layout, min_jdk, skip_below_jdk, jvm_args, compiler_plugin

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| kotlin | compile | aeb | lib/kotlin/module.ae:86 | `kotlinc_bin` | kotlin.kotlinc |
| kotlin | compile | aeb | lib/kotlin/module.ae:513 | `kotlinc_cmd(` | kotlin.kotlinc_test |
| kotlin | test | aeb | lib/kotlin/module.ae:639 | `-ea` | kotlin.kotlin_test |
| kotlin | resolve | aeb | lib/kotlin/module.ae:315 | `maven.classpath(ctx)` | kotlin.kotlinc |
| kotlin | incremental | module-only | lib/kotlin/module.ae:349 | `cache.available()` | kotlin.kotlinc |
| kotlin | cache | yes | lib/kotlin/module.ae:396 | `cache.put(` | kotlin.kotlinc |

### lfe

Grammar: lfe.test (header documents it as run_main; setters src, test_src, pa, run_main), lfe.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| lfe | compile | aeb | lib/lfe/module.ae:163 | `lfec -o` | lfe.test |
| lfe | test | aeb | lib/lfe/module.ae:123 | `lfe -noshell` | lfe.test |

### lua

Grammar: lua.c_extension, lua.conformance, lua.test, lua.consumer_example

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| lua | compile | aeb | lib/lua/module.ae:162 | `${cc} ${ccflags}` | lua.c_extension |
| lua | test | aeb | lib/lua/module.ae:299 | `"busted"` | lua.test |
| lua | test | aeb | lib/lua/module.ae:228 | `${interp} '${conf}'` | lua.conformance |

### maven

Grammar: maven.test, maven.install (project forms: drive an existing pom.xml); library functions (not builders): maven.resolve(ctx), maven.classpath(ctx), maven.load_bom_file, maven.pom_xml, maven.mvn_lifecycle_cmd; maven_dep/maven_bom/maven_repo are bldr-level verbs feeding it

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| maven | resolve | aeb | lib/maven/module.ae:61 | `java -jar ${resolver_jar}` | maven.resolve |
| maven | test | delegated | lib/maven/module.ae:442 | `mvn -q test` | maven.test |
| maven | package | delegated | lib/maven/module.ae:449 | `mvn -q -DskipTests install` | maven.install |
| maven | incremental | delegated | lib/maven/module.ae:449 | `mvn -q` | maven.install |
| maven | cache | yes | lib/maven/module.ae:329 | `cache.available()` | maven.resolve |

### moonbit

Grammar: moonbit.install, moonbit.check, moonbit.test, moonbit.build, moonbit.codegen

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| moonbit | compile | delegated | lib/moonbit/module.ae:201 | `build${target_flag}` | moonbit.build |
| moonbit | test | delegated | lib/moonbit/module.ae:195 | `test${pkg_part}` | moonbit.test |
| moonbit | resolve | delegated | lib/moonbit/module.ae:183 | `install` | moonbit.install |
| moonbit | incremental | delegated | lib/moonbit/module.ae:201 | `build${target_flag}` | moonbit.build |

### nim

Grammar: nim.build, nim.test, nim.generate_manifest (emits .nimble), nim.consumer_example

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| nim | compile | aeb | lib/nim/module.ae:218 | `nim_c_cmd` | nim.build (test_file) |
| nim | compile | aeb | lib/nim/module.ae:146 | `nim c -r ` | nim.test |
| nim | compile | delegated | lib/nim/module.ae:199 | `nimble build` | nim.build (no test_file) |
| nim | test | delegated | lib/nim/module.ae:246 | `nimble test` | nim.test (no test_file) |
| nim | test | aeb | lib/nim/module.ae:269 | `nim_c_run_cmd` | nim.test (test_file) |
| nim | resolve | delegated | lib/nim/module.ae:199 | `nimble build` | nim.build (no test_file) |
| nim | package | delegated | lib/nim/module.ae:199 | `nimble build` | nim.build (no test_file) |
| nim | incremental | delegated | lib/nim/module.ae:199 | `nimble build` | nim.build (no test_file) |

### pharo

Grammar: pharo.sunit, pharo.test

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| pharo | test | aeb | lib/pharo/module.ae:151 | `test --junit-xml-output` | pharo.sunit |
| pharo | test | delegated | lib/pharo/module.ae:170 | `"./run-tests.sh"` | pharo.test |
| pharo | resolve | delegated | lib/pharo/module.ae:135 | `Metacello new baseline` | pharo.sunit |

### php

Grammar: php.test (setters phpunit_phar, phpunit_phar_url, phpunit_phar_sha256, config, ini, env)

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| php | test | aeb | lib/php/module.ae:91 | `${runner}${config_part}` | php.test |
| php | test | aeb | lib/php/module.ae:152 | `"phpunit"` | php.test (step() fallback) |

### pnpm

Grammar: pnpm.resolve (helper called by ts/jest/webpack/angular), pnpm.install, pnpm.run, pnpm.script_arg, pnpm.frozen_lockfile

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| pnpm | resolve | delegated | lib/pnpm/module.ae:49 | `pnpm add` | pnpm.resolve (helper) |
| pnpm | resolve | lockfile | lib/pnpm/module.ae:335 | `pnpm install` | pnpm.install |
| pnpm | compile | delegated | lib/pnpm/module.ae:345 | `pnpm run` | pnpm.run |

### python

Grammar: python.install, python.wheel_registry, python.wheel_vendored, python.pytest, python.test, python.lint, python.typecheck, python.package, python.package_existing, python.codegen, python.consumer_example

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| python | test | aeb | lib/python/module.ae:202 | `-m pytest` | python.pytest |
| python | test | delegated | lib/python/module.ae:1238 | `python3 -m pytest -q` | python.test |
| python | resolve | delegated | lib/python/module.ae:222 | `install -q` | python.install |
| python | package | delegated | lib/python/module.ae:217 | `-m build` | python.package |
| python | package | delegated | lib/python/module.ae:930 | `build_package_cmd` | python.package_existing |

### ruby

Grammar: ruby.bundle (setters install/rspec/minitest/rubocop), ruby.mri, ruby.rake, ruby.gem, ruby.consumer_example, ruby.generate_manifest

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| ruby | test | aeb | lib/ruby/module.ae:314 | `'${ruby_bin}' ${load}` | ruby.mri |
| ruby | test | aeb | lib/ruby/module.ae:284 | `exec rspec` | ruby.bundle (rspec) |
| ruby | test | aeb | lib/ruby/module.ae:300 | `exec ruby` | ruby.bundle (minitest) |
| ruby | test | delegated | lib/ruby/module.ae:336 | `${runner}` | ruby.rake |
| ruby | resolve | delegated | lib/ruby/module.ae:278 | `install` | ruby.bundle (install) |
| ruby | package | aeb | lib/ruby/module.ae:328 | `build '${gemspec_basename}'` | ruby.gem |

### rust

Grammar: rust.cargo_project, rust.cargo_project_existing, rust.cargo_build, rust.cargo_test_existing, rust.cargo_workspace (manifest only), rust.cargo_crate (manifest only), rust.check, rust.check_workspace, rust.test, rust.test_workspace, rust.build_crate, rust.crate_vendored, rust.crate_registry, rust.crate_registry_features, rust.consumer_example

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| rust | compile | delegated | lib/rust/module.ae:1343 | `cargo build` | rust.cargo_project |
| rust | compile | delegated | lib/rust/module.ae:1231 | `cargo_build_cmd` | rust.cargo_project_existing |
| rust | compile | delegated | lib/rust/module.ae:1610 | `cargo build -p` | rust.build_crate |
| rust | compile | delegated | lib/rust/module.ae:915 | `cargo check --workspace` | rust.check_workspace |
| rust | compile | delegated | lib/rust/module.ae:1524 | `cargo check -p` | rust.check |
| rust | test | delegated | lib/rust/module.ae:1278 | `cargo test` | rust.cargo_test_existing |
| rust | test | delegated | lib/rust/module.ae:936 | `cargo test --workspace` | rust.test_workspace |
| rust | test | delegated | lib/rust/module.ae:1565 | `cargo test -p` | rust.test |
| rust | resolve | delegated | lib/rust/module.ae:1003 | `rust_registry_deps_including_transitive` | rust.crate_registry |
| rust | resolve | delegated | lib/rust/module.ae:1380 | `crates-io` | rust.cargo_project_existing |
| rust | package | delegated | lib/rust/module.ae:1343 | `cargo build` | rust.cargo_project |
| rust | incremental | delegated | lib/rust/module.ae:818 | `cargo has its own` | rust.cargo_project |
| rust | cache | yes | lib/rust/module.ae:1120 | `cache.available` | rust.cargo_project |
| rust | cache | yes | lib/rust/module.ae:1458 | `cache.available` | rust.cargo_build |

### scala

Grammar: scala.scalac, scala.scalac_test, scala.munit, scala.assembly; setters scala_version, source_layout, main_class, min_jdk, skip_below_jdk, jvm_flag, output_jar

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| scala | compile | aeb | lib/scala/module.ae:89 | `dotty.tools.dotc.Main` | scala.scalac |
| scala | compile | aeb | lib/scala/module.ae:473 | `scalac_cmd(` | scala.scalac_test |
| scala | test | aeb | lib/scala/module.ae:95 | `munit_cmd` | scala.munit |
| scala | test | aeb | lib/scala/module.ae:572 | `bldr._sh(run_cmd)` | scala.scalac_test |
| scala | resolve | aeb | lib/scala/module.ae:147 | `java -jar ${resolver_jar}` | scala.scalac |
| scala | package | aeb | lib/scala/module.ae:123 | `jar cfM` | scala.assembly |
| scala | incremental | module-only | lib/scala/module.ae:306 | `cache.available()` | scala.scalac |
| scala | cache | yes | lib/scala/module.ae:347 | `cache.put(` | scala.scalac |

### swift

Grammar: swift.resolve, swift.build_pkg, swift.test, swift.generate_manifest (emits Package.swift)

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| swift | compile | delegated | lib/swift/module.ae:89 | `build${config_flag}` | swift.build_pkg |
| swift | test | delegated | lib/swift/module.ae:94 | `test${config_flag}` | swift.test |
| swift | resolve | delegated | lib/swift/module.ae:84 | `package resolve` | swift.resolve |
| swift | package | delegated | lib/swift/module.ae:236 | `swift_build_output` | swift.build_pkg |
| swift | incremental | delegated | lib/swift/module.ae:89 | `build${config_flag}` | swift.build_pkg |

### ts

Grammar: ts.tsc, ts.tsc_files, ts.mocha, ts.generate_manifest, ts.npm_vendored, ts.npm_registry

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| ts | compile | aeb | lib/ts/module.ae:84 | `-p '${tsconfig_path}'` | ts.tsc |
| ts | compile | aeb | lib/ts/module.ae:103 | `tsc` | ts.tsc_files |
| ts | test | aeb | lib/ts/module.ae:153 | `node ${mocha_bin}` | ts.mocha |
| ts | resolve | delegated | lib/ts/module.ae:549 | `pnpm.resolve` | ts.tsc |
| ts | cache | yes | lib/ts/module.ae:579 | `cache.available` | ts.tsc |
| ts | cache | yes | lib/ts/module.ae:624 | `cache.put` | ts.tsc |

### webpack

Grammar: webpack.bundle, webpack.config

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| webpack | package | aeb | lib/webpack/module.ae:26 | `${webpack_bin}` | webpack.bundle |
| webpack | resolve | delegated | lib/webpack/module.ae:40 | `pnpm.resolve` | webpack.bundle |

### zig

Grammar: zig.build_pkg, zig.test, zig.test_existing, zig.consumer_example

| sdk | rung | grade | evidence | tool string | grammar entry |
|---|---|---|---|---|---|
| zig | compile | delegated | lib/zig/module.ae:52 | `build${opt_flag}` | zig.build_pkg |
| zig | test | delegated | lib/zig/module.ae:57 | `build test` | zig.test |
| zig | test | delegated | lib/zig/module.ae:271 | `"zig build test"` | zig.test_existing |
| zig | resolve | delegated | lib/zig/module.ae:9 | `bldr.zig.zon` | zig.build_pkg |
| zig | package | delegated | lib/zig/module.ae:122 | `zig-out/bin` | zig.build_pkg |
| zig | incremental | delegated | lib/zig/module.ae:52 | `build${opt_flag}` | zig.build_pkg |
