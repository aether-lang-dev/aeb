# build SDK — authoring notes

Surfaced by `ae help <script>.build.ae --lib .aeb/lib` when a name
below appears. See docs/cic-help.md for the mechanism.

## `dep` is a static edge, not a runtime call

`dep("path/to")` does nothing at execution time. It
is a DAG edge, extracted *statically* by a text scan (`tools/extract-deps`)
before any `.ae` file runs — the same shape as a Bazel `BUILD` dep.
The path must be a literal string (it is grepped, not evaluated), and
it points at the dependency's directory. If you
expected `dep(...)` to trigger a build action inline, it does not — it
only orders the graph.

Pattern: literal-name `dep`

## `build` vs `begin`

`bldr.build() { ... }` opens a build session and runs its block — the SDK
verbs (`java.javac()`, `rust.cargo_project()`, …) and `dep(...)` edges go
*inside* the block as bare calls, with no handle to thread. Call it once at
the top of `aeb(cap)`. `bldr.begin()` is the lower-level per-module entry the
orchestrator uses; a hand-written `.build.ae` almost always wants `build`.

Pattern: literal-name `begin`
