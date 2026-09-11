# `java.package_jar()` recompiles the sources instead of packaging a prior `javac` stage's classes

> **STATUS: FIXED (2026-09-11).** Added `from_classes(<classpath>)` to
> `package_jar`; when present it packages those pre-compiled classes and skips
> its internal javac. Self-compile stays as the fallback. Exactly the suggested
> shape.

## Resolution

`lib/java/module.ae`: new `from_classes("<dir|classpath>")` setter. When set,
`package_jar` stages each classpath entry (a directory's class tree is copied
in; a `.jar` is copied alongside) and **skips the internal javac**; native
resources + jar steps are unchanged, so `native_resource()` and the builder's
other niceties are preserved (the thing the hand-rolled workaround lost). Absent
→ self-compile as before. The builder doc now leads with the from_classes
(package-a-prior-stage) shape as preferred, self-compile as the fallback — the
compile/package split mainstream JVM build systems use.

Verified end-to-end on ae 0.665.0: a `java/.build.ae` javac node + a
`java/.jar.ae` using `from_classes(dep_artifact("java/.build.ae",
"jvm_classpath_deps_including_transitive"))` + `native_resource` →
the node's log shows `cp -R …/classes/. → stage` and "packaging pre-compiled
classes (no recompile)", **no javac in the package step**; the jar contains the
javac node's `Hello.class` + `native/libdemo.so`. Self-compile fallback (no
from_classes) still builds a jar from `src/main/java` / flat layout. Full aeb
suite green.

So "you ship what you tested" is now structural, and the binding compiles once.

## The ask

`java.package_jar()` (lib/java/module.ae, ~line 1153) runs its **own `javac`**
over `src/main/java` (with a flat top-level fallback) into a staging dir, then
`jar cf`s that. It has no way to be handed **already-compiled classes**. So a
project that has a `java.javac()` node — the standard "compile once, everyone
deps the classpath artifact" node — and *also* wants a jar must compile the same
sources **twice**: once in the `javac` node (which the tests and every
downstream JVM binding run against) and again inside `package_jar`.

Please add a way for `package_jar` to **package a pre-compiled classpath and
skip its internal `javac`** — e.g. a `from_classes(<dep'd classpath>)` setter, or
have it consume `jvm_classpath_deps_including_transitive` from a dep'd
`.build.ae` when present. Self-compile stays as the fallback for a jar node that
has no upstream compile.

## Why this is the anomaly, not a detail

Every mainstream JVM build system treats **compile as a node and jar/package as
a downstream step that consumes that node's output** — never a step that
recompiles:

- **Maven** — `maven-jar-plugin:jar` zips `target/classes` produced by the
  `compile` phase. It does not invoke `javac`.
- **Gradle** — the `Jar` task takes `sourceSets.main.output` and is wired
  `dependsOn(compileJava)`; the jar is the compile task's output, zipped.
- **Bazel** — `java_binary`/`java_library` produce a `.jar` from a single
  compilation action; a binary consumes the library's jar, it doesn't re-run
  `javac`.
- **sbt** — `package` depends on `compile` and jars `classDirectory`.

`package_jar` self-compiling is the odd one out, and today the builder's doc
comment presents that self-compile as the normal path. The compile/package split
should be the **default** shape aeb promotes (package a prior stage's classes),
with self-compile the fallback — not the reverse.

## Two concrete costs (both real, seen in libphonenumber-ae)

1. **Double compilation.** The Java binding's sources are compiled by
   `java/.build.ae` (for `java/.tests.ae` and the kotlin/groovy/clojure layers,
   which all dep its classpath) and then compiled *again* by `java/.jar.ae`'s
   `package_jar`. Wasted work that grows with source size.

2. **"Tested == shipped" is coincidental, not structural.** Because the jar
   contains a *second* compilation, the bytecode you ship is identical to the
   bytecode your tests ran only as long as both compiles read the same sources
   with the same flags. The moment the `javac` node sets a `release`, a
   `source_layout`, or any flag `package_jar` doesn't mirror, the jar ships
   bytecode that was never tested — silently. Packaging the `javac` node's
   actual output makes "you ship what you tested" a structural guarantee.

## Repro / context

libphonenumber-ae (the Aether port), branch `reboot`:
- `java/.build.ae` — `java.javac()` over a flat source dir; publishes
  `jvm_classpath_deps_including_transitive` = its `classes/` dir. Tests + the
  three JVM-family bindings all run against these classes.
- `java/.jar.ae` — wants a fat jar (classes + the engine `.so` at `/native/`).
  It deps only `core/.build.ae` (for the `.so`); it CANNOT reuse
  `java/.build.ae`'s classes, so `package_jar` recompiles.

A hand-rolled workaround exists (dep `java/.build.ae`, `cp` its published
`classes` dir + the `.so` into a stage, `jar cf`), which compiles once and ships
exactly the tested bytecode — but it bypasses `package_jar` entirely and so
loses `native_resource()` bundling and the builder's other niceties. That
workaround is exactly what a `from_classes`-capable `package_jar` would make
unnecessary.

## Suggested shape

```
java.package_jar() {
    jar_name("phonenumber-ae.jar")
    from_classes(dep_artifact("java/.build.ae", "jvm_classpath_deps_including_transitive"))
    native_resource(lib, "native/libphonenumber_ae.so")
}
```

When `from_classes` (or an equivalent dep'd classpath) is present, skip the
internal `javac` and jar those classes + the native resources; otherwise
self-compile as today.
