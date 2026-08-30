# TODO: a pure-Aether Maven coordinate resolver (retire aeb-resolve.jar)

> STATUS UPDATE (2026-08-30): the mvn-install COUPLING is already gone — aeb-resolve
> is now a thin shim over bld (commit c32a5be), JDK+curl build, no mvn/shade/stubs.
> What remains below is the FURTHER step of a fully pure-Aether resolver (no JVM at
> all); bld is the reference implementation to study for it.


Parked idea (2026-08-30). We keep building scaffolding around a foreign 3.7 MB
Java dependency (Eclipse Aether / Maven Resolver, via aeb-resolve.jar) that does
something conceptually simple. Doing it in Aether would sever the Java/mvn
coupling entirely — no jar, no compile stubs, no shade, no curl'd impl, no
~/.m2. aeb-resolve becomes a normal self-hosted `.ae` tool.

## What it must do
1. Take coordinates (`org.junit.jupiter:junit-jupiter:5.10.2`).
2. HTTP GET each POM from Maven Central.
3. Parse POM XML → `<dependencies>`, `<parent>`, `<dependencyManagement>`, props.
4. Walk transitively, dedupe, apply version/scope rules → emit the classpath;
   fetch each `.jar`.

Aether already has the hard infrastructure: real HTTP (the WebDriver-BiDi
transport) and XML/text parsing. The remaining work is the resolution LOGIC.

## The semantics that make it non-trivial (the closure to reproduce)
- transitive POM walk + `<parent>` chains
- `<dependencyManagement>` + BOM imports (`<scope>import</scope>`) — junit/spring
- property interpolation (`${project.version}`, `${prop}`)
- version conflict resolution (Maven "nearest wins")
- scope filtering (compile/runtime/test/provided), exclusions, optional, classifiers

Failure mode is nasty: a 90%-correct resolver silently emits a slightly-wrong
classpath. So target the common subset first (direct + transitive + parent +
dependencyManagement + properties + nearest-wins + compile/test scope), measure
against real coordinate sets (junit/xunit/dotty), and decide the long tail after.

## Next step when picked up
Survey the actual `maven_dep`/`jar_registry` coordinates across aeb + sibling
repos to size the semantics burden (mostly direct+BOM? or long tail?), then
build-vs-buy: pure-Aether MVP vs keeping the library. See the selaenium-handoff
#2 thread and tools/resolver/.dist.ae for the current mvn-free-build state.

## Prior art to study (all resolve the SAME Maven repo format, each with its OWN resolver)
- **Maven / Eclipse Aether (maven-resolver)** — what aeb-resolve.jar wraps today (heavy, 3.7 MB closure).
- **Gradle** — its own engine (not Aether); reads POMs + Gradle Module Metadata; conflict rule differs (highest-wins vs Maven nearest-wins).
- **Coursier** (sbt/Scala) — independent resolver.
- **bld (Geert Bevin, RIFE2)** — the best reference: a compact, from-scratch Maven-coordinate resolver written in plain Java *specifically to avoid* pulling in maven-resolver/Gradle. Small + readable — the closest model for a pure-Aether resolver. bld's "build is real code in the host language" also mirrors aeb's ".ae build files."

Takeaway: nobody shares a resolver; each ecosystem rewrote it over the one shared *format*. A pure-Aether resolver is normal, not wheel-reinvention — and bld proves a lean one is tractable.

## DECISION (2026-08-30): adopt bld's resolver as aeb-resolve

Proven: bld-2.3.0.jar is ONE self-contained 2 MB jar (0 non-rife classes) whose
`rife.bld.dependencies.DependencyResolver` resolves a coordinate transitively,
downloads from Maven Central, and yields a working classpath — verified by
resolving org.junit.jupiter:junit-jupiter:5.10.2 (8 jars) and compiling a real
junit test against the result. `Dependency.parse("g:a:v")` takes aeb's exact
coordinate form; `ArtifactRetriever.instance()` + `Repository.MAVEN_CENTRAL` +
`Scope.compile/runtime` + `getAllDependencies(...)` + `transferIntoDirectory(dir)`
are the public API. Prototype shim: scratchpad/bld-Resolve-prototype.java.

This RETIRES: the 24-jar Eclipse-Aether closure, tools/resolver/stubs/,
fetch-impl.sh, impl-jars.txt, the java.shade dance, and mvn entirely. aeb-resolve
becomes: fetch pinned bld-<v>.jar (curl, sha) + a tiny shim reproducing the
EXISTING aeb-resolve CLI contract, run as `java -cp bld.jar:shim BldResolve ...`.

### The CLI contract the shim MUST match (lib/maven depends on it verbatim)
    java -jar <jar> --output classpath|sbom [--bom G:A:V] [--bom-file <path>] \
                    [--repo <url>] [--cache <dir>] <coord> <coord>...
  - --output classpath -> ':'-joined jar paths on stdout (default)
  - --output sbom      -> resolved coords, one per line, sorted+deduped
  - --bom / --bom-file -> dependencyManagement version sources
  - --repo             -> extra repositories (besides Central)
  - positional coords  -> the deps to resolve

### The one risk to verify: BOM imports (--bom G:A:V)
bld's Scope has no `import`; dependencyManagement/parent/property handling is
internal to Xml2MavenPom (not a flag). junit resolves fine (no external BOM).
Spring-style `--bom` imports need testing — if bld doesn't apply an external
BOM's managed versions, the shim must resolve the BOM's <dependencyManagement>
itself (fetch the BOM POM, read managed versions) and pin the coords. TEST
against a real BOM case (e.g. spring-boot-dependencies) before trusting the swap.
