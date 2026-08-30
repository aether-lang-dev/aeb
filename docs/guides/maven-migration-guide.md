# Migrating a Maven Project to aeb

This guide covers converting a multi-module Maven project to aeb, based on the spring-data-examples migration (107 pom.xml files → 90 `.build.ae` + 86 `.tests.ae` files).

## Overview

aeb replaces Maven's XML-based build configuration with Aether's builder-closure DSL. Each Maven module gets two files:

- `.build.ae` — compile-time dependencies and javac configuration
- `.tests.ae` — test dependencies and test execution

The migration is incremental: pom.xml files stay in place until the `.ae` files are proven correct, then the pom.xml files are deleted.

## Prerequisites

```bash
# Install aeb and initialize the project
cd your-project
/path/to/aeb/aeb --init

# Verify tools
ae version          # Aether compiler
java -version       # JDK (match your project's Java version)
mvn -version        # Maven (used once for dep extraction, then not needed)
```

## Step 1: Extract the Dependency Truth from Maven

**Do this first.** Don't guess at dependencies — Maven already knows the exact answer.

### Install reactor modules

Maven needs internal modules (parent poms, util modules) installed before it can resolve cross-module dependencies:

```bash
# Install root pom
mvn install -N -DskipTests

# Install all aggregator (parent) poms
mvn install -pl parent-module-1,parent-module-2 -N -DskipTests

# Install shared utility modules that other modules depend on
mvn install -pl shared/util -am -DskipTests
```

### Dump direct dependencies for every module

```bash
mkdir -p /tmp/aeb-deps

for pom in $(find . -name 'pom.xml' -not -path '*/target/*'); do
    dir=$(dirname "$pom")
    mod="${dir#./}"

    # Skip aggregator poms (packaging=pom, no source)
    if grep -q '<packaging>pom</packaging>' "$pom"; then continue; fi

    dep_file="/tmp/aeb-deps/${mod//\//_}.txt"
    mvn -pl "$mod" dependency:list \
        -DexcludeTransitive=true \
        -DoutputFile="$dep_file" \
        -U 2>/dev/null

    if [ -f "$dep_file" ]; then
        echo "OK: $mod"
    else
        echo "FAIL: $mod"
    fi
done
```

The output files contain lines like:
```
   org.springframework.boot:spring-boot-starter-data-jpa:jar:4.0.4:compile
   org.hsqldb:hsqldb:jar:2.7.3:compile
   org.projectlombok:lombok:jar:1.18.44:provided
   org.springframework.boot:spring-boot-starter-test:jar:4.0.4:test
```

These are the **direct** dependencies only (not transitives) — exactly what belongs in your `.build.ae` files.

### Parse the dep files

Extract clean `g:a:v:scope` lines:

```bash
for f in /tmp/aeb-deps/*.txt; do
    mod=$(basename "$f" .txt | tr '_' '/')
    echo "=== $mod ==="
    cat "$f" | sed 's/\x1b\[[0-9;]*m//g' | \
        grep -E '^\s+\S+:\S+:' | \
        sed 's/^\s*//' | \
        awk '{print $1}'
done
```

## Step 2: Create the BOM File

If your project uses a parent POM that manages dependency versions (like `spring-boot-starter-parent`), create a shared BOM file. **`.bom.ae` files are parsed as text by `aeb-resolve.jar`** — they are not Aether programs. No `import`, no `main()`. Just top-level `maven_bom(...)` / `maven_repo(...)` lines that the resolver greps for:

```aether
// spring-boot.bom.ae — parsed as text by aeb-resolve.jar
maven_bom("org.springframework.boot:spring-boot-dependencies:4.0.4")
```

This file is referenced by `load_bom_file()` (imported from `maven`) in each module's build file. Different subtrees can use different BOM files.

If your project uses snapshot or milestone repositories, add `maven_repo(...)` lines to the same file:

```aether
// spring-milestone.bom.ae
maven_bom("org.springframework.data:spring-data-bom:2026.0.0-M2")
maven_repo("https://repo.spring.io/milestone")
maven_repo("https://repo.spring.io/snapshot")
```

## Step 3: Create .build.ae Files

For each leaf module, create a `.build.ae` using the deps from Step 1.

### Mapping Maven scopes to aeb

| Maven scope | aeb |
|-------------|-------------|
| `compile` | `dep(b, "g:a")` in `.build.ae` (version from BOM) |
| `compile` (not in BOM) | `dep(b, "g:a:v")` in `.build.ae` (explicit version) |
| `test` | `dep(b, "g:a")` in `.tests.ae` |
| `provided` | `dep(b, "g:a")` in `.build.ae` (treated same as compile) |
| `runtime` | `dep(b, "g:a")` in `.build.ae` (treated same as compile) |

### Template

```aether
// module-name/.build.ae
import build
import build (dep)
import maven (load_bom_file)
import java
import java (release, source_layout, enable_preview)

aeb(cap) {
    b = build.start()
    load_bom_file(b, "../path/to/your.bom.ae")
    dep(b, "org.springframework.boot:spring-boot-starter-data-jpa")
    dep(b, "org.hsqldb:hsqldb")
    dep(b, "org.projectlombok:lombok")
    java.javac(b) {
        release("25")
        source_layout("maven")
        enable_preview()
    }
}
```

### Key patterns

**Version-less deps** — when a BOM manages the version:
```aether
dep(b, "org.springframework.boot:spring-boot-starter")
```

**Explicit versions** — when not in any BOM:
```aether
dep(b, "io.vavr:vavr:0.10.3")
```

**Inter-module deps** — reference by directory path:
```aether
dep(b, "mongodb/util")
```

**BOM overrides** — when a module needs a different BOM or extra repos, create a second `.bom.ae` next to the module (or anywhere convenient) and `load_bom_file()` it. BOMs and repos compose: every loaded `.bom.ae` contributes its `maven_bom(...)` / `maven_repo(...)` lines to the resolver invocation.
```aether
load_bom_file(b, "../../spring-boot.bom.ae")
load_bom_file(b, "spring-milestone.bom.ae")  // adds the data-bom + milestone repo
```

**QueryDSL / annotation processing** — add the APT dep and generated sources dir:
```aether
import java (release, source_layout, enable_preview, generated_sources)

    dep(b, "com.querydsl:querydsl-jpa")
    dep(b, "com.querydsl:querydsl-apt")
    java.javac(b) {
        release("25")
        source_layout("maven")
        enable_preview()
        generated_sources("target/module/generated-sources")
    }
```

## Step 4: Create .tests.ae Files

Each module with `src/test/java` gets a `.tests.ae`. The test file depends on its own module (for prod classes) and declares test-specific deps.

### Template

```aether
// module-name/.tests.ae
import build
import build (dep)
import maven (load_bom_file)
import java
import java (release, source_layout, enable_preview, test_timeout)

aeb(cap) {
    b = build.start()
    dep(b, "module/path")
    load_bom_file(b, "../path/to/your.bom.ae")
    dep(b, "org.springframework.boot:spring-boot-starter-test")
    dep(b, "org.junit.platform:junit-platform-console")
    dep(b, "org.springframework.boot:spring-boot-data-jpa-test")
    java.javac_test(b) {
        release("25")
        source_layout("maven")
        enable_preview()
    }
    java.junit5(b) {
        test_timeout("120")
        enable_preview()
    }
}
```

### Test autoconfigure modules

Spring Boot 4.x splits test autoconfiguration into separate modules. Add the right one for your data store:

| Data store | Test autoconfigure dep |
|-----------|----------------------|
| JPA | `org.springframework.boot:spring-boot-data-jpa-test` |
| JDBC | `org.springframework.boot:spring-boot-data-jdbc-test` |
| MongoDB | `org.springframework.boot:spring-boot-data-mongodb-test` |
| Redis | `org.springframework.boot:spring-boot-data-redis-test` |
| Cassandra | `org.springframework.boot:spring-boot-data-cassandra-test` |

### TestContainers

If tests use TestContainers, add these deps and set a longer timeout:

```aether
    dep(b, "org.testcontainers:testcontainers-mongodb")
    dep(b, "org.testcontainers:testcontainers-junit-jupiter")
    dep(b, "org.apache.commons:commons-lang3")
    dep(b, "commons-io:commons-io:2.18.0")
    java.junit5(b) {
        test_timeout("120")
        enable_preview()
    }
```

Note: TestContainers 2.x renamed modules with a `testcontainers-` prefix (e.g., `testcontainers-mongodb` instead of `mongodb`).

aeb auto-detects Podman sockets for TestContainers. If using Podman, start the socket first:

```bash
systemctl --user start podman.socket
```

## Step 5: Build and Iterate

```bash
# Build a single module (fastest feedback)
aeb module/path

# Build everything
aeb

# Build just compile targets (skip tests)
# (not yet supported — run specific modules instead)
```

### Common issues

**"no version for g:a and no BOM provides one"**
The dep isn't in your BOM. Add an explicit version: `dep(b, "g:a:v")`

**Jackson transitives missing (jackson-core, jackson-annotations)**
The Maven Resolver doesn't resolve property-interpolated transitive versions. Add explicitly:
```aether
dep(b, "com.fasterxml.jackson.core:jackson-databind")
dep(b, "com.fasterxml.jackson.core:jackson-annotations")
dep(b, "com.fasterxml.jackson.core:jackson-core")
```

**Command line too long (6000+ source files)**
Already handled — aeb uses `@argfile` automatically via `find`.

**Tests hang waiting for external services**
`test_timeout("30")` wraps the test JVM with `timeout`. TestContainers tests should use `test_timeout("120")` to allow time for container startup.

**Target directory collisions (mongodb/util vs cassandra/util)**
Already handled — target dirs use the full module path.

## Step 6: Delete pom.xml Files

Once all modules compile and tests pass (or fail only due to missing external services), delete the pom.xml files:

```bash
# Verify all modules compile
aeb 2>&1 | grep "javac failed"
# Should be empty

# Delete pom.xml files
find . -name 'pom.xml' -not -path '*/target/*' -delete

# Also remove Maven wrapper and config
rm -rf .mvn mvnw mvnw.cmd
```

## After Migration

A few aeb features pay off once the migration is in place. See the
README for the canonical reference; brief pointers:

- **Verify the dep graph visually.** `aeb --graph | dot -Tsvg > deps.svg`
  emits the full DAG. After translating 100+ `pom.xml` files this is
  the fastest way to confirm the new structure matches what Maven's
  reactor used to walk. `aeb --graph mermaid` for an inline-Markdown
  variant.
- **Use `aeb --since` in CI.** Instead of `aeb` (build everything),
  `aeb --since main` builds and tests only the modules whose sources
  are downstream of the PR's changes. Combined with aeb's
  content-addressed cache, a typical PR run is many times faster than
  a full Maven `verify`.
- **Narrow PR checks to tests with `--scan '.tests.ae'`.** A typical
  Maven PR triggers `mvn verify` (compile + test + package) on every
  affected module. With aeb you usually only want the *tests* on a PR;
  packaging belongs on release tags. `aeb --since main --scan '.tests.ae'`
  runs only the test targets impacted by the PR; `--scan '.dist.ae'`
  is the symmetric release-pipeline shape.
- **Composite test targets via `build.scan()`.** Commit a
  `.all-tests.ae` once and your CI command stays
  `aeb .all-tests.ae --since main` forever:

  ```aether
  // .all-tests.ae at the repo root
  import build
  aeb(cap) {
      b = build.start()
      build.scan(b, "**/.tests.ae")
  }
  ```

  Every `.tests.ae` in the tree is automatically picked up at build-graph
  extraction time. New modules join the test set the moment their
  `.tests.ae` lands; no CI config change needed.
- **Cache and telemetry are auto-on.** No configuration. Each `aeb`
  run prints a `[telemetry]` block at the end with per-module
  wall-time and `[hit]`/`[miss]` cache outcomes — useful for
  spotting which modules are still slow after migration.

## Appendix: What Doesn't Migrate Automatically

These Maven features need manual handling:

| Maven feature | aeb equivalent |
|--------------|----------------------|
| Profiles | `if` checks on environment variables in `.build.ae` |
| Resource filtering | Not yet supported — copy resources manually |
| Spring Boot repackage | Use `java.shade()` or a future `springboot.repackage()` |
| GraalVM native-image | Not yet supported |
| ByteBuddy/jmolecules transform | Post-compilation step not yet supported |
| jOOQ code generation | Pre-build code generation not yet supported |
| EclipseLink weaving | Not yet supported |
| Kotlin compilation | Use `kotlin.kotlinc()` with `source_layout("maven")` |
| Multi-release JARs | Not yet supported |

## Appendix: Resolver Limitations

The aeb resolver (`aeb-resolve.jar`) uses the Maven Resolver API but has one known limitation compared to full Maven:

**Property-interpolated transitive versions are not resolved.** When a POM declares a dependency with `<version>${some.property}</version>` where the property is defined in a parent POM, the resolver can't interpolate it. This affects:
- Jackson (jackson-databind → jackson-core via `${jackson.version.core}`)
- Some TestContainers transitives

**Workaround:** List the affected deps explicitly in your `.build.ae`. Use `mvn dependency:tree` to find the missing transitives.
