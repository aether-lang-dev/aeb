# aeb vs. Gradle

Gradle and aeb both build multi-language projects from a graph, but
they put the graph in different places.

Gradle's unit is a project with tasks. Plugins add tasks, tasks depend
on other tasks, and the configuration phase computes the build graph.
Its strengths are a mature plugin ecosystem, rich JVM support,
incremental tasks, toolchains, publishing, and a remote/local build
cache.

aeb's unit is a source-tree target: a dot-prefixed `.ae` file next to
the code it builds. The graph is file-to-file and statically visible
through `build.dep(...)` declarations. Language SDKs provide the build
verbs; target files declare intent.

## What aeb should learn

- Toolchain selection and pinning.
- Strong publishing workflows for Maven, npm, PyPI, NuGet, and OCI.
- Better dependency locking and verification.
- Richer cache keys across every SDK.
- Structured test reports and build scans as exportable artifacts.
- Version injection into manifests, packages, and generated metadata.

## What aeb should avoid

Gradle's main failure mode is configuration complexity. Large builds
can become a plugin-driven runtime program where it is hard to answer
"what does this target build?" without executing project code.

aeb should keep target intent readable and dependency edges
extractable. Project-local builders are useful; hidden task mutation is
not.

## Rule of thumb

Adopt Gradle's maturity around toolchains, caching, testing, and
publishing. Do not adopt a dynamic task-configuration culture that
hides the source-tree graph.
