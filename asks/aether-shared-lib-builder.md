# `lib/aether` can consume a shared library but cannot produce one

**From:** html-sanitizer (2026-08-23).

## The gap

`lib/aether` exposes `program`, `program_test`, `csrc`, `tinygo_lib`,
`driver_test`, `binary_under_test`, `fixture_seed`, `fixture_server`.

There is no builder for **`ae build --emit=lib`** — an Aether module compiled
to a native shared library. That is the artifact at the centre of our repo:
one Aether engine, 21 language bindings that link or dlopen it.

The asymmetry is sharp. `lib/aether` *consumes* shared libs — `_collect_shared_libs`
(module.ae:417) reads `shared_library_deps_including_transitive` from its deps
and threads them into the link. But it never *publishes* one. So:

- `lib/go`'s `go_build` with `build_mode("c-shared")` publishes `ldlibdeps`
  (module.ae:340)
- `lib/rust`'s `cargo_project` with `crate_type("cdylib")` publishes
  `ldlibdeps` (module.ae:1210, 1520)
- **`lib/aether` publishes nothing equivalent**

`ldlibdeps` is the artifact `lib/java` reads (module.ae:947) to auto-wire
`-Djava.library.path`, which is why `../google-monorepo-sim`'s Java code can
call a bare `System.loadLibrary("gonasal")` against a Go-built `.so` with no
path plumbing in the leaf at all. An Aether-built `.so` cannot participate in
that.

## What we do now

`core/.build.ae` shells out:

```
os.system("cd '${root}/core' && ae build --emit=lib embed.ae --extra _embed_support.c -o '${dest}/libhtmlsanitizer.so'")
build.publish_artifact(b, "shared_lib", "${dest}/libhtmlsanitizer.so")
build.publish_artifact(b, "ldlibdeps", "${dest}/libhtmlsanitizer.so")
```

Publishing `ldlibdeps` by hand does work — we verified the JVM consumers pick
it up — but it is us guessing at an internal contract from reading aeb's
source, which is exactly the coupling a builder should own.

## The ask

```
aether.shared_lib(b) {
    source("embed.ae")
    extra_source("_embed_support.c")
    output("libhtmlsanitizer.so")
}
```

publishing `shared_lib` + `ldlibdeps` (and `c_header_dirs` if it emits a
header), so downstream JVM/Go/Rust consumers wire up automatically.

The setters already exist on `aether.program` (`source`, `extra_source`,
`output`, `caps`, `target`, `link_flag`, `include_dir`) — this is largely
`program` with `--emit=lib` and a different publish set. `csrc` is precedent
for it being a separate builder rather than a mode on `program`: a node that
publishes no `program_binary` must not be findable by
`build.program_binary_of`.

## Bonus, if `target()` composes

`aether.shared_lib` + `target("wasm32-wasi")` would cover our wasm build too —
aether 0.577.0 made `ae build --emit=lib --target=wasm32-wasi` work (verified:
40/40 exports, full conformance suite passes), and we currently drive it from
a 105-line hand-rolled `wasm/build-zig.sh`.
