# build SDK — authoring notes

Surfaced by `ae help <script>.build.ae --lib .aeb/lib` when a name
below appears. See docs/cic-help.md for the mechanism.

## `dep` is a static edge, not a runtime call

`build.dep(b, "path/to/.build.ae")` does nothing at execution time. It
is a DAG edge, extracted *statically* by a text scan (`tools/extract-deps`)
before any `.ae` file runs — the same shape as a Bazel `BUILD` dep.
The path must be a literal string (it is grepped, not evaluated), and
it must point at the dependency's build file, not its directory. If you
expected `dep(...)` to trigger a build action inline, it does not — it
only orders the graph.

Pattern: literal-name `dep`

## `start` vs `begin`

`build.start()` opens a build session and returns the builder map you
pass to an SDK verb — call it once at the top of `main()`. `build.begin()`
is the lower-level per-module entry the orchestrator uses; a hand-written
`.build.ae` almost always wants `start`.

Pattern: literal-name `begin`
