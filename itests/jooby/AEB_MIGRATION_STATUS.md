# Jooby (Java/Kotlin Maven framework) → aeb Migration — Status

Upstream: https://github.com/jooby-project/jooby (shallow `--depth 1` clone via
`itests/fetch-upstream.sh`). A real multi-module web framework — 82 modules, 85
poms, JDK 21, mixed Java + Kotlin — migrated aeb-native (deps re-declared in
`.build.ae`, not delegated to `mvn`). This is a **proving ground**: driving it
through aeb surfaced (and got fixed) several real aeb gaps.

## Not a test of record

A fringe experiment against a large real codebase, not part of aeb's canonical
surface. `tests/run.sh` exercises the SDK grammar offline without fetching a
byte of jooby. Cloners do **not** need `itests/fetch-upstream.sh`.

## Version management

`jooby.bom.ae` carries the 7 import-scoped BOMs from jooby's parent pom
(netty, aws, camel, junit, jackson x2, mcp). Modules `load_bom_file()` it, so
`dep(b, "g:a")` resolves; jooby-pinned versions go inline as `g:a:v`.

## Modules migrated so far

| Module | Compile | Tests | Notes |
|--------|---------|-------|-------|
| jooby (core) | OK | **1285/1285** | JPMS module (module-info) — modular `--module-path` compile |
| jooby-jackson | OK | — | JPMS leaf, `requires io.jooby` resolves via core on module-path |
| jooby-kotlin | OK | **9/9** | pure Kotlin (coroutines) |
| jooby-netty | OK | — | classpath-mode (`no_module_info()`) — see netty note |
| jooby-test | OK | **110/110** | mixed Java+Kotlin tests (`javac_test` + `kotlinc_test`) — green since the aether list_get_raw fix |

## aeb features this migration surfaced (all fixed)

- **JPMS `--module-path` compile** — `java.javac` auto-detects `module-info.java`
  and routes resolved deps to `--module-path` (jooby core needs it); plus a
  `no_module_info()` opt-out for classpath-mode.
- **`src/{main,test}/resources` on the classpath** — the Maven resources-plugin
  equivalent; jooby core's tests went 15 failures → 0 once SSL certs / config /
  webjar props landed on the classpath.
- **`kotlin.kotlinc_test` maven classpath** — was omitting test-scope maven deps.
- **Resolver transitivity** — aeb-resolve dropped BOM/property-versioned
  transitives (netty resolved to *just* netty-handler); now resolves the full
  effective-model tree. This is what unblocked netty.

## Fixed along the way

- **`list_get_raw` segfault on mixed Java+Kotlin test compile — FIXED** (aether
  0.417.0). `jooby-test` compiles Kotlin tests via `kotlin.kotlinc_test` against
  a *diamond* dependency (core reached via two paths) with a rich maven dep set
  (junit + coroutines). The aether runtime segfaulted in `list_get_raw`, handed a
  pointer with a bad `_kind_magic` (a dangling/type-confused list) that it
  dereferenced without validating — exposed once the resolver fix produced full
  (longer) classpaths. Fixed upstream by guarding the accessor with the
  `_kind_magic` + low-address discriminator (aether PR #1196). With the fixed
  toolchain, `jooby-test` is **110/110** — the mixed `javac_test` + `kotlinc_test`
  compile coexist fine; the earlier "clobber" fear was unfounded.

## Known blockers (not yet resolved)

- **netty 4.2 multi-release jars + JPMS.** netty's jars carry `module-info` only
  under `META-INF/versions/11`, so javac treats them as automatic modules on
  `--module-path` and jooby-netty's `requires io.netty.*` can't match. Worked
  around with `no_module_info()` (classpath-mode) — a netty idiosyncrasy, not aeb.

## Aeb-owned overlay (tracked)

Only `.build.ae` / `.tests.ae` / `jooby.bom.ae` / this file / `git-ls-files.txt`
are tracked; upstream sources are gitignored and fetched fresh.
