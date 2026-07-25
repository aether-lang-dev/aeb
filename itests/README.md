# aeb Integration Tests

Real-world open-source projects converted from their native build systems
to aeb. Each project is a shallow clone of an upstream repo with
`.build.ae`, `.tests.ae`, and `.bom.ae` files added.

## Setup

Upstream sources are not committed — fetch them once:

```bash
./fetch-upstream.sh
```

Then build any project by `cd`-ing into it and running `aeb`:

```bash
cd spring-data-examples
aeb --init
AETHER=/path/to/ae aeb
```

## Cache smoke test

`cache-smoke.sh` is the end-to-end check that the content-addressed cache
actually skips work on a warm rebuild and re-runs when a source changes —
the level the unit suite (`tests/run.sh`) can't reach because it never
drives a real build. For each cache-wired SDK with a green itest
(go/dotnet/ts) it runs three `aeb --telemetry-json` builds against a
fresh `$AEB_CACHE_DIR` and asserts: cold → 0 cache hits, warm → >0 hits,
touch-a-source → fewer hits than warm. Projects whose toolchain or
upstream sources are absent are skipped (so partial environments still get
coverage). Needs a working `ae` that can link a full multi-module `./aeb`
(Linux today — macOS ld64 can't; see ../TODO.md).

```bash
cd itests
./fetch-upstream.sh
AETHER=/path/to/ae ./cache-smoke.sh                       # all green-itest SDKs
AETHER=/path/to/ae ./cache-smoke.sh go-multimodule-fyne   # one project
```

## Named-target-set smoke test

`presubmit-smoke.sh` verifies the `.presubmit.ae` convention
(`../docs/presubmit-target-sets.md`): a dot-prefixed `.ae` file whose body
is nothing but `build.dep(...)` lines is a runnable set of targets. It
synthesises a three-node fixture in a temp dir and asserts that members
run, the aggregator topo-sorts last, the set self-classifies as type
`presubmit` from its filename alone, an all-green set exits 0, and — the
load-bearing one — a set with a failing member exits non-zero with the
failure attributed to that member. Two further rounds pin the doc's
claims about guards: `meta.desc` on a node that builds nothing, an
inline working-tree check gating both ways, a reproducible tool probe,
and the `os.exec` silent-pass trap that makes a naive probe useless.

Needs no language toolchain (members are trivial `bash.test` nodes) and
fetches nothing, so it runs anywhere a working `ae` can link a
multi-module build.

```bash
cd itests
AETHER=/path/to/ae ./presubmit-smoke.sh
```

## Projects

| Directory | Language | Upstream | What aeb replaces |
|-----------|----------|----------|-------------------|
| spring-data-examples | Java | [spring-projects/spring-data-examples](https://github.com/spring-projects/spring-data-examples) | 107 pom.xml files (Maven) |
| nx-examples | TypeScript | [nrwl/nx-examples](https://github.com/nrwl/nx-examples) | Nx workspace (Angular + React) |
| clojure-multiproject-example | Clojure | [adityaathalye/clojure-multiproject-example](https://github.com/adityaathalye/clojure-multiproject-example) | deps.edn + build.clj |
| dotnet-architecture-eShopOnWeb | C# | [dotnet-architecture/eShopOnWeb](https://github.com/dotnet-architecture/eShopOnWeb) | .sln + .csproj files (generated from .build.ae) |
| go-multimodule-fyne | Go | [fyne-io/fyne](https://github.com/fyne-io/fyne) | go test ./... (per-package isolation) |
| rust-multi-module-oxen | Rust | [Oxen-AI/Oxen](https://github.com/Oxen-AI/Oxen) | Cargo workspace (per-crate targeting) |
| mrhdias_rust_store | Rust | [mrhdias/store](https://github.com/mrhdias/store) | Cargo.toml (generated from .build.ae) |
| flutter-melos-monorepo | Dart/Flutter | [adityadroid/flutter-melos-monorepo](https://github.com/adityadroid/flutter-melos-monorepo) | Melos (`melos bootstrap` → committed pubspec_overrides.yaml) |
| jooby | Java/Kotlin | [jooby-project/jooby](https://github.com/jooby-project/jooby) | Maven reactor (82 modules; deps re-declared aeb-native) |

## Results summary

| Project | Modules | Compile | Tests |
|---------|---------|---------|-------|
| spring-data-examples | 90 | 68+ OK | 9+ pass |
| nx-examples | 13 | 13 OK | 7/7 pass |
| clojure-multiproject | 6 | 6 OK | 3/5 pass (1 intentional fail, 1 port conflict) |
| dotnet-eShopOnWeb | 9 | 9 OK | 3/3 pass |
| go-multimodule-fyne | 1 + 11 test | 1 OK | 11/11 pass |
| rust-multi-module-oxen | 3 | 0 (env) | — (RocksDB C++ build issue) |
| mrhdias_rust_store | 1 | 0 (upstream) | — (ord_subset crate incompatible with current rustc) |
| flutter-melos-monorepo | 6 | 6 OK | 20/20 pass (needs Flutter 3.3.x) |
| jooby | 5 of 82 | 5 OK | core 1285/1285, kotlin 9/9 (partial; see status) |

## What gets committed

Only aeb-specific files are tracked in the aeb repo:

- `.build.ae`, `.tests.ae`, `.dist.ae` — build scripts
- `*.bom.ae`, `*.deps.ae` — shared dependency declarations
- `AEB_MIGRATION_STATUS.md` — per-project migration notes
- `git-ls-files.txt` — upstream file list for .gitignore

Upstream source files are in `.gitignore` (fetched fresh by `fetch-upstream.sh`).
Build artifacts (`target/`, `.aeb/`, `.generated.csproj`) are also ignored.

## SDK modules exercised

| SDK | Projects using it |
|-----|------------------|
| java + maven | spring-data-examples |
| ts + pnpm + angular + jest + webpack | nx-examples |
| clojure + maven | clojure-multiproject-example |
| dotnet | dotnet-architecture-eShopOnWeb |
| go | go-multimodule-fyne |
| rust | rust-multi-module-oxen, mrhdias_rust_store |
| dart (+ flutter via `dart_bin`) | flutter-melos-monorepo |
| java + maven + kotlin (JPMS) | jooby |
