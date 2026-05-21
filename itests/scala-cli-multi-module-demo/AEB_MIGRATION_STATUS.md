# scala-cli to aeb Migration Status

Upstream: https://github.com/VirtusLab/scala-cli-multi-module-demo.git

## Modules

| Module | Compile | Tests | Package | Notes |
|--------|---------|-------|---------|-------|
| common | OK | PASS | — | Shared library, munit tests via JUnit |
| module-1 | OK | — | OK | App, depends on common; fat jar via `scala.assembly` |
| module-2 | OK | — | — | App, depends on common |

3 modules compile, 1/1 test suite passes, 1 fat jar assembled
end-to-end.

## What aeb replaces

- scala-cli (entire tool — no longer needed)
- Bloop compilation server
- Coursier dependency resolution
- `//> using file` directives (inter-module deps) → `build.dep()`
- `//> using dep` directives (Maven deps) → `dep()` in `.build.ae`/`.tests.ae`
- `package.sh` scripts (`scala-cli --power package`) → `scala.assembly(b)`
  in `module-1/.dist.ae`. Builds a single self-contained fat jar with
  scala-library + every transitive dep inlined.

## What aeb uses

- `scala.scalac(b)` — invokes Scala 3 compiler directly via `java -cp dotty.tools.dotc.Main`
- `scala.scalac_test(b)` — compiles test sources against prod classes
- `scala.munit(b)` — runs munit tests via JUnit 4 runner
- `scala.assembly(b)` — fat-jar packaging. Stages compiled classes +
  scala-library + every transitive dep (unzips each classpath jar,
  copies each classes dir) into one tree, writes a Main-Class
  manifest, `jar cfM`s it. The no-toolchain analogue of sbt-assembly
  / `scala-cli --power package`. `main_class(...)` (required) and
  `output_jar(...)` (optional) setters. Output:
  `target/<mod>/bin/<name>-assembly.jar`.

This pass also fixed a latent bug in `scala.scalac`'s classpath
artifact: the `jvm_classpath_deps_including_transitive` file it wrote
omitted the transitive `build.dep` classpath, so a downstream fat jar
lost cross-module classes (`common/SharedCode`). The artifact now
includes dep_cp, matching its name.
- Scala compiler + library jars resolved via `aeb-resolve.jar` from Maven Central
- munit + hamcrest resolved the same way

## How it works

No Scala toolchain installation required — just Java. The SDK module:

1. Resolves `org.scala-lang:scala3-compiler_3:3.8.2` via `aeb-resolve.jar`
2. Resolves `org.scala-lang:scala3-library_3:3.8.2` for the compile classpath
3. Invokes `java -cp <compiler-jars> dotty.tools.dotc.Main -d classes/ -cp <library+deps> *.scala`
4. For tests, resolves munit, compiles test sources, runs via `org.junit.runner.JUnitCore`

This is the same pattern as Java (`javac`) and Kotlin (`kotlinc`) — the language
compiler is just a JVM program invoked with the right classpath.
