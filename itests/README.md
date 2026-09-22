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

### Pin the upstreams, or the subject of the test changes under you

`fetch_repo` takes an optional third argument — a commit or tag — and an entry
without one **tracks upstream HEAD**. That is not a snapshot; it means the
project being tested is whatever upstream looked like on the day someone last
ran the fetch, while the `.build.ae` files next to it were written against
whatever it looked like on the day of the migration.

It is not hypothetical. nx-examples migrated to TypeScript solution-style
configs (#458) — `tsconfig` `paths` aliases replaced by npm-workspace package
resolution, babel and webpack configs deleted, and `libs/shared/product/types`
now re-exporting a `./generated` module an `nx codegen` target produces. An
unpinned fetch replaced the test subject wholesale: 82 of its 88 recorded
upstream files were simply gone, and the itest failed with `Cannot find module
'@nx-example/shared-jsxify'` — nothing to do with aeb. It is now pinned to
`2cae706`, the parent of that migration, which matches its recorded file list
exactly.

When an itest starts failing in ways that do not look like aeb, check drift
before debugging aeb:

```bash
cd itests/<project>
while read -r f; do [ -e "$f" ] || echo "MISSING $f"; done < git-ls-files.txt | wc -l
```

(`nx-examples` and `spring-data-examples` carry a cleaner `upstream_git_files.txt`
— prefer it where present.) A non-trivial count means the upstream moved and
the migration needs either a pin or a re-migration. As of 2026-09-22:
`rust-multi-module-oxen` has drifted far and is unpinned; `go-multimodule-fyne`
and `spring-data-examples` have drifted mildly; clojure, dotnet, python, flutter
and jooby have not drifted at all.

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
(`../docs/design/presubmit-target-sets.md`): a dot-prefixed `.ae` file whose body
is nothing but `dep(...)` lines is a runnable set of targets. It
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
`../docs/guides/aeb-host-vm-or-container-setup.md` asserted "Aether itself is a
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

## Resolver `.bom.ae` check

`resolver-bom-ae.sh` pins what `aeb-resolve.jar --bom-file` accepts. A path
handed to it is one of two things: an aeb `.bom.ae` — the DSL, scanned as
text for `maven_bom()` / `maven_repo()` / `dep()` lines — or a literal Maven
BOM POM (XML). The Eclipse-Aether resolver handled both; the Aug-2026 rewrite
onto bld kept only the XML branch, so every `.bom.ae` in the tree hit an XML
parser, warned `Content is not allowed in prolog`, **and exited 0** having
silently dropped every repository and coordinate it declared. The damage
surfaced one step removed from its cause, as Clojars-hosted artifacts
reported missing from Maven Central — which is what the Clojure itest had
been failing on.

Nothing caught it: `tests/run.sh` is Aether-only and cannot exercise a Java
jar, and `tests/test_maven_cmd.ae` asserts the command string aeb builds,
which was right throughout.

Offline. A `python3 -m http.server` serves a two-file fake repository on
127.0.0.1 holding one artifact that exists in no public repository, so "did
`maven_repo()` register" and "did `dep()` register" are answered by whether
that coordinate comes back — no network, no flakes, and a pass that cannot
come from a warm Central cache. Assertions are about bytes, not `$?`, since
the broken resolver's exit code was 0.

Mutation-checked: against the pre-fix jar 3 assertions fail, while the XML
round still passes — the two `--bom-file` meanings are independent and both
need pinning.

```bash
cd itests
./resolver-bom-ae.sh
```

## Container emit-only check

`container-emit-only.sh` is the other half of
`tests/test_container_dockerfile.ae`. That unit test asserts the exact string
`dockerfile_full_content()` generates, including ordered `run`/`workdir`/`run`
rendering, and it passed throughout the bug below — because the string was
never wrong. The defect was in what the builder did with it: `container.image`
never created `target/<type>/<dir>` before writing (every other SDK mkdirs its
own output dir), and dropped `io.write_file`'s error return into a discard
variable. So the write failed, nothing said so, and the builder returned 0 —
under `AEB_CONTAINER_EMIT_ONLY` that was the entire node: a green build, an
ordinary-looking telemetry row, and no Dockerfile on disk.

`tests/run.sh` runs Aether unit tests with no builder context and no
filesystem, so it cannot reach a builder body at all. This script drives the
same grammar through a real aeb node and asserts on the file — both the
full-recipe path (`from()`/`run_step()`, the shape `agent-container/.image.ae`
uses) and the artifact-packaging default, plus the other direction: a
destination that cannot be written must redden the build and name the file.

Emit-only is the right harness because it needs no container engine, no image
pull and no network — and it is the path where the bug was total rather than
merely confusing.

Mutation-checked: remove the `bldr._mkdirs(target_dir)` and 5 assertions fail.

```bash
cd itests
./container-emit-only.sh
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

Last measured **2026-09-22** on CachyOS: JDK 26, .NET 10 SDK, Go, node 26 /
pnpm 11, rustc 1.98, Clojure CLI 1.12, Python 3.14, Ruby 3.4, gcc 16, Aether
0.706.0. Where a row differs from a previous reading, the reason is named —
several are properties of THIS host, not of aeb.

| Project | Modules | Compile | Tests |
|---------|---------|---------|-------|
| spring-data-examples | 90 | 61 OK | 69/77 |
| nx-examples | 14 | 12 OK | 0 (jest undeclared — see its status doc) |
| clojure-multiproject | 6 | 6 OK | 4/5 pass (1 intentional upstream fail) |
| dotnet-eShopOnWeb | 9 | 9 OK | blocked (host has no `Microsoft.AspNetCore.App` runtime) |
| go-multimodule-fyne | 1 + 11 test | 1 OK | 11/11 pass |
| python-monorepo-demo | 2 | 2 OK + wheel/sdist | 3/4 (1 upstream assertion) |
| aether-program-spike | 1 + 2 test | 1 OK | 2/2 pass |
| c-hello / c-aether-spike-a / -b / c-bootstrap-tool | 1 each | all OK | binaries run |
| rust-workspace-demo | 3 | 3 OK | 1/1 pass |
| rust-registry-crate-demo | 1 | 1 OK | — |
| agent-container | 1 | OK (emit-only) | — |
| rust-multi-module-oxen | 3 | 0 (env) | — (RocksDB C++ build issue; also heavily drifted, unpinned) |
| mrhdias_rust_store | 1 | 0 (upstream) | — (ord_subset crate incompatible with current rustc) |
| flutter-melos-monorepo | 6 | not run | — (no Flutter on this host; dart 3.13 alone) |
| jooby | 5 of 82 | not run this round | core 1285/1285, kotlin 9/9 (partial; see status) |

Notes on the rows that moved:

- **spring-data-examples 6 → 61.** Two fixes. The migration had added
  `enable_preview()` to all 174 build/test files although upstream's
  `jvm.enable-preview` property is empty, which pinned the project to JDK 25
  and failed 83 of 90 modules on a JDK 26 host; and `lib/java`'s modular
  compile passed deps on `--module-path` only, so javac could not complete
  `org.jspecify.annotations.Nullable` and crashed while formatting a
  diagnostic, printing a bare `1 error`. The remaining 29 are the Spring Boot
  4.0.1 → 4.0.4 drift that `AEB_MIGRATION_STATUS.md` already describes.
- **nx-examples.** Was failing wholesale against an upstream that had moved
  on; now pinned to `2cae706` and 12 of 14 modules compile. The tests need
  workspace dev-dependencies the migration never declared — listed, with
  versions, in its `AEB_MIGRATION_STATUS.md`.
- **clojure-multiproject 3/5 → 4/5.** `aeb-resolve.jar` had lost its
  `.bom.ae` parsing, so no Clojars coordinate resolved; `clojure.uberjar`
  also read `maven_classpath` from the wrong target dir. The one remaining
  failure is upstream's deliberate `(= 0 1)` FIXME.
- **dotnet-eShopOnWeb.** All 9 projects compile. The test runs abort in the
  VSTest host because the box has only `Microsoft.NETCore.App 10.0.11` and no
  ASP.NET Core shared runtime at any version, so a net8.0 test assembly has
  nothing to load. Nothing to do with aeb.

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
