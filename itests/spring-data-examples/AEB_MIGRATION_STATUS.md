# Maven to aeb Migration — Status

90 leaf modules converted from Maven to aeb. All compilation and testing
is driven by `.build.ae` / `.tests.ae` files using the Java SDK + a
shared Spring Boot BOM. No `pom.xml`, Surefire, or Maven plugins are
invoked.

## `enable_preview()` removed (2026-09-22)

Every `.build.ae` and `.tests.ae` here carried `enable_preview()` alongside
`release("25")`. Upstream does **not** compile with preview features: its
`jvm.enable-preview` property is declared **empty** in the root `pom.xml` and
used in exactly one place — a surefire `argLine` prefix in
`jpa/eclipselink/pom.xml`. It is a hook for turning preview on ad hoc, not a
setting. The migration had promoted it into an unconditional compiler flag.

That made the whole project JDK-25-only, because javac accepts
`--enable-preview` only for its OWN release:

    error: invalid source release 25 with --enable-preview
      (preview language features are only supported for release 26)

On a JDK 26 box that was **83 of 90 modules failing**, all with the same
message, for a flag upstream never sets. Removed across all 174 files; the
`release("25")` pin stays, since that is upstream's real
`maven.compiler.source`/`target`.

## Upstream pinning

Upstream `spring-data-examples` tracks the current Spring Data milestone
(e.g. Spring Data 2026.0.0-SNAPSHOT / Spring Boot 4.1-SNAPSHOT), which
drifts faster than we can track. To get stable results we pin the
upstream checkout:

```bash
# itests/fetch-upstream.sh
fetch_repo "https://github.com/spring-projects/spring-data-examples.git" \
           "spring-data-examples" "cd0d2b36"
```

Commit `cd0d2b36` corresponds to upstream's Spring Boot 4.0.1 / Spring
Data 4.0.x line. Our `spring-boot.bom.ae` pins
`spring-boot-dependencies:4.0.4` which is close enough that nearly all
passing tests work unchanged; a few compile failures trace to 4.0.1 →
4.0.4 drift in the `org.springframework.boot.webmvc.test.*` and
`org.springframework.boot.resttestclient.*` packages.

## Build configuration

Every module uses the same SDK builders:

```aether
java.javac(b) {
    release("25")
    source_layout("maven idiomatic")
    enable_preview()
    parameters()   // required for Spring Data @Query named parameters
}

java.javac_test(b) {
    release("25")
    source_layout("maven idiomatic")
    enable_preview()
    parameters()
}

java.junit5(b) {
    test_timeout("30")
    enable_preview()
}
```

**`parameters()`** is load-bearing for any module using Spring Data
repository methods with named parameters — without it, tests fail with
*"For queries with named parameters you need to provide names for method
parameters"*.

## BOM and dependency management

A single `spring-boot.bom.ae` at the repo root declares:

```
maven_bom("org.springframework.boot:spring-boot-dependencies:4.0.4")
```

Every module loads it via `load_bom_file(b, "../../spring-boot.bom.ae")`.
Dependencies are then declared without versions — the BOM provides them,
the same way Maven's `<dependencyManagement>` works. Resolution is
handled by `aeb-resolve.jar` which wraps the Maven Resolver API and
caches artifacts under `~/.aeb/repo`.

## DAG and dep resolution

`.tests.ae` files dep on their sibling `.build.ae` via the file-based
pattern:

```aether
build.dep(b, "jpa/example/.build.ae")
```

When run from the repo root, `transform-ae`'s sed rule strips the
trailing `/.build.ae` to produce module path `jpa/example`, which
matches the `build.begin(s, "jpa/example")` call inside the compiled
`.build.ae` — so the test's `jvm_classpath_deps_including_transitive`
lookup finds the correct artifact directory.

## Full test matrix (all 86 `.tests.ae` modules)

Full battery run with 120s per-module cap (TestContainers-heavy modules
hit the cap and are reported as TIMEOUT — they may work given longer):

| Status       | Count |
|--------------|-------|
| PASS         |    18 |
| TEST_FAIL    |    28 |
| COMPILE_FAIL |    19 |
| TIMEOUT      |    15 |
| NO_TESTS     |     6 |
| **Total**    |    86 |

**Aggregate test counts over the 18 PASS modules:** 101 tests found /
85 successful / 0 failed (the rest were skipped or aborted). `jpa/example`
alone accounts for 45 found / 45 successful.

**Aggregate over the 28 TEST_FAIL modules:** 82 found / 6 successful /
64 failed (some modules fail in fixture setup before any test runs).

### Results by data-store category

| Category         | PASS | TEST_FAIL | COMPILE_FAIL | TIMEOUT | NO_TESTS |
|------------------|------|-----------|--------------|---------|----------|
| jpa/             |   9  |    4      |     0        |   2     |    1     |
| jdbc/            |   1  |    8      |     5        |   0     |    1     |
| rest/            |   0  |    3      |     2        |   1     |    0     |
| r2dbc/           |   1  |    0      |     0        |   1     |    0     |
| web/             |   1  |    0      |     1        |   1     |    0     |
| mongodb/         |   0  |    8      |     4        |   7     |    2     |
| cassandra/       |   0  |    3      |     0        |   1     |    1     |
| couchbase/       |   3  |    0      |     0        |   0     |    0     |
| redis/           |   1  |    0      |     6        |   0     |    1     |
| elasticsearch/   |   0  |    0      |     0        |   2     |    0     |
| neo4j/           |   0  |    1      |     0        |   0     |    0     |
| ldap/            |   0  |    1      |     0        |   0     |    0     |
| map              |   1  |    0      |     0        |   0     |    0     |
| multi-store      |   0  |    0      |     1        |   0     |    0     |

### Passing modules (18)

```
couchbase/example               4/0/0    couchbase/reactive      6/0/0
couchbase/transactions          1/0/0    jdbc/howto/schema-gen   4/4/0
jpa/eclipselink                 1/1/0    jpa/envers              1/1/0
jpa/example                    45/45/0   jpa/graalvm-native      1/1/0
jpa/interceptors                1/1/0    jpa/multiple-datasources 2/2/0
jpa/multitenant/partition       4/3/0    jpa/query-by-example    8/8/0
jpa/security                    5/5/0    jpa/vavr                4/4/0
map                             2/2/0    r2dbc/query-by-example  6/6/0
redis/cluster                   4/0/0    web/example             2/2/0
```

### Failure categories

1. **Source / API drift between pinned upstream (4.0.1) and our BOM
   (4.0.4).** Affects `web/projection`, `rest/multi-store`, and others
   that import `org.springframework.boot.webmvc.test.*` /
   `org.springframework.boot.resttestclient.*` — these packages were
   renamed in 4.0.2. Fix options: align BOM to 4.0.1, or bump pin
   forward to a commit that uses 4.0.4.

2. **Missing explicit third-party deps in individual modules.** Upstream
   `pom.xml` files declare these via profile / extension POMs that aeb
   doesn't consume; a few modules just need an extra `build.dep(b,
   "group:artifact")` line. Examples: `jdbc/mybatis` (mybatis),
   `rest/security` (jackson databind internals).

3. **Annotation-processor modules** (`jdbc/immutables`, `web/querydsl`,
   `jpa/aot-optimization`, `mongodb/querydsl`). The Java SDK already has
   complete AP support — `processor()`, `processor_path()`,
   `generated_sources()`, and `javac()` auto-wires `processor_path =
   maven_cp` so processors on the Maven classpath are discovered
   automatically. The remaining failures trace to missing transitive
   deps (`querydsl-core` not appearing on the resolved classpath even
   though `querydsl-mongodb` is) rather than AP configuration.

4. **TestContainers startup past 120 s cap** (`mongodb/reactive`,
   `elasticsearch/*`, `cassandra/example`, several others). Not build
   failures — the runner's per-module cap is tighter than the
   containers need on a cold start. Lifting the cap and/or pre-pulling
   images would reclaim most of these.

5. **HSQLDB / H2 test DB behaviour** (`jpa/jpa21` stored procedures).
   Upstream-side issue, not build-related.

6. **Upstream source quirks at the pinned commit** (e.g. `jpa/showcase`
   has custom `src/snippets/` and `src/test-snippets/` roots; these need
   a `source_layout` variant).

## Module counts

- 90 `.build.ae` files (compilation)
- 86 `.tests.ae` files (test execution)
- 0 `.dist.ae` files (examples aren't deployable apps)
- 14 data-store categories: JDBC, JPA, MongoDB, Redis, Cassandra,
  Couchbase, Elasticsearch, Neo4j, R2DBC, LDAP, Map, REST, Web,
  Multi-store

## Maven tooling still present but not invoked

The original `pom.xml` files (107 of them) remain in the repo as
reference. Notable Maven plugins that were replaced:

- **maven-compiler-plugin** — `java.javac(b)` / `java.javac_test(b)`
- **maven-surefire-plugin** — `java.junit5(b)`
- **apt-maven-plugin** (QueryDSL) — not migrated; needs a
  `java.processor()` DSL or a generator pre-step.

## What we exercise in this itest

- BOM mechanism (`load_bom_file` + `aeb-resolve.jar`) as a real
  replacement for Maven `<dependencyManagement>`
- Transitive classpath flow through `.build.ae` → `.tests.ae` via
  `jvm_classpath_deps_including_transitive`
- `parameters()` compilation flag for Spring Data
- `enable_preview()` compilation flag for Java 25 preview APIs
- TestContainers integration under Podman (aeb auto-sets `DOCKER_HOST`)
- File-based dep graph with a single-binary orchestrator over 90 modules
