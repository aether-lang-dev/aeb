# aeb vs. Starlark

aeb's Aether closure DSL can express much of the same abstraction
space as Bazel's Starlark rules and macros. A builder closure can
collect attributes, declare deps, name outputs, and lower the result
into compiler/test/package actions:

```aether
company.java_service(b) {
    main_class("com.acme.Main")
    dep("libs/logging/.build.ae")
    dep("libs/config/.build.ae")
    image("registry/acme/service")
}
```

So the difference is not expressive power. The difference is what
aeb should make normal.

## What aeb should keep

aeb's strongest property is that the source tree is the build graph.
A target is a dot-prefixed `.ae` file, dependency edges are visible as
literal declarations, and the runner can scan the tree without
evaluating a project-specific macro framework.

That property is worth protecting. Starlark's main failure mode in
large repos is not that it is weak; it is that it is powerful enough
for teams to hide simple build intent behind layers of macros. When
that happens, answering "what does this target depend on?" becomes a
code-reading exercise instead of a graph query.

## The aeb-shaped extension model

aeb should expose constrained closure-based builders, not an
unbounded Starlark-style rule culture.

Good shape:

- Project-local SDK modules define typed builders.
- Builder closures record simple attributes on a context map.
- Dependencies remain statically extractable.
- Inputs, outputs, and actions are visible through `aeb query` /
  `aeb explain` style tooling.
- `.build.ae` files remain readable as build intent, even when a
  builder implementation lives elsewhere.

Bad shape:

- Macros generate hidden dependency edges.
- Target behaviour depends on arbitrary runtime evaluation.
- Users need to understand a repo-specific framework before they can
  understand one target.
- Shell snippets become the primary build API.

## Rule of thumb

Use Aether closures to build small typed builders that remove real
duplication. Do not recreate Bazel's macro layer.

aeb can subsume the useful parts of Starlark rules while keeping its
own advantage: a declarative, greppable, source-tree-native graph.
