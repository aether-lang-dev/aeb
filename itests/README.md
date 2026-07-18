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
(scala/go/dotnet/ts) it runs three `aeb --telemetry-json` builds against a
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

## Projects

| Directory | Language | Upstream | What aeb replaces |
|-----------|----------|----------|-------------------|
| spring-data-examples | Java | [spring-projects/spring-data-examples](https://github.com/spring-projects/spring-data-examples) | 107 pom.xml files (Maven) |
| nx-examples | TypeScript | [nrwl/nx-examples](https://github.com/nrwl/nx-examples) | Nx workspace (Angular + React) |
| clojure-multiproject-example | Clojure | [adityaathalye/clojure-multiproject-example](https://github.com/adityaathalye/clojure-multiproject-example) | deps.edn + build.clj |
| scala-cli-multi-module-demo | Scala | [VirtusLab/scala-cli-multi-module-demo](https://github.com/VirtusLab/scala-cli-multi-module-demo) | scala-cli (replaced entirely — direct scalac) |
| dotnet-architecture-eShopOnWeb | C# | [dotnet-architecture/eShopOnWeb](https://github.com/dotnet-architecture/eShopOnWeb) | .sln + .csproj files (generated from .build.ae) |
| go-multimodule-fyne | Go | [fyne-io/fyne](https://github.com/fyne-io/fyne) | go test ./... (per-package isolation) |
| rust-multi-module-oxen | Rust | [Oxen-AI/Oxen](https://github.com/Oxen-AI/Oxen) | Cargo workspace (per-crate targeting) |
| mrhdias_rust_store | Rust | [mrhdias/store](https://github.com/mrhdias/store) | Cargo.toml (generated from .build.ae) |
| flutter-melos-monorepo | Dart/Flutter | [adityadroid/flutter-melos-monorepo](https://github.com/adityadroid/flutter-melos-monorepo) | Melos (`melos bootstrap` → committed pubspec_overrides.yaml) |

## Results summary

| Project | Modules | Compile | Tests |
|---------|---------|---------|-------|
| spring-data-examples | 90 | 68+ OK | 9+ pass |
| nx-examples | 13 | 13 OK | 7/7 pass |
| clojure-multiproject | 6 | 6 OK | 3/5 pass (1 intentional fail, 1 port conflict) |
| scala-cli-multi-module | 3 | 3 OK | 1/1 pass |
| dotnet-eShopOnWeb | 9 | 9 OK | 3/3 pass |
| go-multimodule-fyne | 1 + 11 test | 1 OK | 11/11 pass |
| rust-multi-module-oxen | 3 | 0 (env) | — (RocksDB C++ build issue) |
| mrhdias_rust_store | 1 | 0 (upstream) | — (ord_subset crate incompatible with current rustc) |
| flutter-melos-monorepo | 6 | 6 OK | 20/20 pass (needs Flutter 3.3.x) |

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
| scala | scala-cli-multi-module-demo |
| dotnet | dotnet-architecture-eShopOnWeb |
| go | go-multimodule-fyne |
| rust | rust-multi-module-oxen, mrhdias_rust_store |
| dart (+ flutter via `dart_bin`) | flutter-melos-monorepo |
