# deps.edn to aeb Migration Status

Upstream: https://github.com/adityaathalye/clojure-multiproject-example.git

## Modules

| Module | Compile | Tests | Package | Notes |
|--------|---------|-------|---------|-------|
| parts (grugstack) | OK | FAIL | — | Intentional upstream FIXME test `(= 0 1)` |
| projects/example_app | OK | PASS | OK | No external deps beyond clojure.jar; executable uberjar via `clojure.uberjar` |
| projects/acmecorp/snafuapp | OK | PASS | Depends on parts, Ring, JDBC, SQLite |
| projects/usermanager-first-principles | OK | PASS | Depends on parts, Ring, JDBC, SQLite |
| projects/fnconf2025/smolwebapp | OK | FAIL | Test binds Jetty to hardcoded port 3000 (env conflict) |
| projects/fnconf2025/catchall | OK | — | No tests in upstream |
| projects/fnconf2025/nullproject | — | — | Empty stub, skipped |

6 modules compile, 3/5 test suites pass.

## What aeb replaces

- `deps.edn` aliases (`:root/all`, `:root/test`, per-project aliases)
- `build/build.clj` (tools.build orchestration)
- `clj -X:root/all:root/test` (test runner invocation)
- `clj -T:root/build ci` (CI pipeline)

## What aeb uses

- `clojure.compile(b)` — validates sources load via `java -cp ... clojure.main`
- `clojure.test(b)` — discovers `*_test.clj` files, runs via `clojure.test/run-tests`
- `clojure.uberjar(b)` — executable uberjar packaging. AOT-compiles
  `main_ns` (the `(:gen-class)` namespace), stages the `src/` tree
  (so non-AOT namespaces load at runtime), unzips clojure.jar + every
  maven dep, writes a Main-Class manifest (dash-munged ns), and
  `jar cfM`s a standalone jar. The no-leiningen analogue of
  `lein uberjar` / tools.build's `uber`. `main_ns(...)` (required) +
  `output_jar(...)` (optional) setters. Demonstrated by
  `projects/example_app/.dist.ae`: builds an 8 MB self-contained jar
  that `java -jar` runs to print the `-main` greeting.
- Maven deps via `dep()` — same `group:artifact:version` coordinates as `:mvn/version`
- `clojars.bom.ae` — adds Clojars repo (Clojure libs aren't on Maven Central)
- `clojure-dep-patches.bom.ae` — explicit Jetty transitives the resolver misses

## deps.edn files still present but not invoked

The original `deps.edn` files remain as reference. Key things they declare
that aeb now handles:

- `:deps` maps → `dep()` lines in `.build.ae`
- `:local/root` deps → `build.dep()` inter-module references
- `:aliases` for test/build/dev → `.tests.ae` files
- cognitect test-runner (git dep) → replaced by direct `clojure.test` invocation

## Known issues

1. Resolver can't interpolate POM parent properties (Jetty BOM versions),
   requiring explicit `dep()` lines in `clojure-dep-patches.bom.ae`
2. `load_bom_file` was single-value — fixed to accumulate a list
3. Clojure source paths must chain transitively (unlike Java class dirs)
