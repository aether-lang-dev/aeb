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

## Build-failure visibility smoke test

`build-failure-visibility.sh` is the regression harness for
[issue #13](https://github.com/aether-lang-dev/aeb/issues/13): a node whose
gcc/link step failed used to render the byte-identical telemetry row a
successful build renders — same `[miss]`, same timing, no verdict — because
only *test* rows had a verdict channel (their pass/fail counts). It builds
an `aether.program` with a deliberately broken `extra_source` `.c` (the
route through lib/aether's manual aetherc+gcc path, where the reported
failures happened) and asserts the row says `FAILED`, that the summary
block's last lines still say so, that the roll-up names the target, that no
binary was actually produced, and that the gcc stderr log is named — on
**both** driver paths, since the parallel and sequential drivers write
different status vocabularies (`"fail"` vs `"failed"`). A final round
asserts the other direction: a green build stays quiet.

Assertions are about bytes on stdout, not `$?`. The exit code was correct
throughout the original incidents; the harm came from output that read as
success when piped through `tail`/`grep` (which replaces the exit code) or
simply read on screen.

Needs a C toolchain and a working `ae`; fetches nothing.

```bash
cd itests
AETHER=/path/to/ae ./build-failure-visibility.sh
```

## Toolchain-fetch smoke test

`toolchain-fetch.sh` pins how the trampoline obtains aeb's **private,
pinned Aether** — prefer the prebuilt release asset, fall back to a source
build via upstream's `get.sh`.

It exists because nothing tested this and it silently drifted: the
trampoline built from source (~69 s, needs a C compiler) while
`release.yml` fetched the prebuilt (<1 s) under a comment claiming it did
so "the same way a cold node would", and
`../docs/aeb-host-vm-or-container-setup.md` asserted "Aether itself is a
2.8 MB binary tarball, not a source build". Three places, two behaviours,
no test to notice.

`curl` is stubbed on `PATH` and serves local fixtures, so the default run
is **offline and takes seconds** — every property under test is about what
the trampoline does with what it receives (which URL it asks for, whether
it probes before caching, what it does when the probe fails), none of
which needs GitHub. `--live` adds the one thing a stub cannot prove: that
the asset URL actually resolves.

The load-bearing assertion is the **compile probe**. Upstream publishes no
`.sha256`, so that probe is the only integrity gate on the fast path — and
the cache is consulted with a bare `-x .../bin/ae` on every later run, so
a bad tree admitted once is reused forever. The fixture is an archive that
unpacks cleanly with an executable `bin/ae` that cannot compile: exactly
the v0.449.0 shape, where `--version` succeeded on a `aetherc` that needed
`GLIBC_2.38` and died on Debian 12.

Mutation-checked — reverting to source-only fails 5 assertions, swapping
the compile probe for `--version` fails 3, and moving the fetch log back
inside the directory the success path deletes fails 3 (that last one is
not cosmetic: it breaks caching outright, since `mv`'s stderr redirect
targets a path inside the just-removed directory).

```bash
cd itests
./toolchain-fetch.sh          # offline, stubbed
./toolchain-fetch.sh --live   # + one real download
```

## std symbol-collision check

`std-symbol-collision.sh` stops aeb sources from defining a function that
Aether's std already exports as a C symbol.

Three tools (`aeb-link`, `gen-orchestrator`, `encode-name`) each carried a
local helper named `string_replace_all`. Aether **0.463.0** added a C
function with exactly that name, and two definitions of one symbol is a
hard link error — `make` stopped working outright on any newer Aether.
Nothing caught it: the unit suite never builds those tools, and CI pins an
older Aether, so it only surfaced when someone compiled against a newer
toolchain.

It reads the **actual** exported/extern symbol set (~1355 names) out of
whichever toolchain is in play, so running under a newer Aether is what
gives early warning about names std has just taken. Two earlier drafts
were wrong in instructive ways: matching by *prefix* flagged innocent code
(`path_dep`, `file_to_label`, `os_getpid_safe` — none of which std
defines), and matching every std name flagged ~50 SDK setters (`get`,
`run`, `path`) that compile to `<module>_<name>` and cannot collide. Only
the fully-qualified `<stdmodule>_<fn>` form is a real hazard.

`lib/veto_trace_os/std/` is excluded deliberately — it is a drop-in shadow
of `std.os` for veto tracing, so matching std's names is the point, and it
is never linked alongside the real one. In CI a missing std tree **fails**
rather than skips, so the step cannot go green having checked nothing.

Mutation-checked: reintroducing `string_replace_all` in `aeb-link.ae`
trips two assertions.

```bash
cd itests
./std-symbol-collision.sh
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
