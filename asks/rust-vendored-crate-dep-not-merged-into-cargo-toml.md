# rust SDK: vendored `crate_vendored` path-dep not merged into the generated Cargo.toml on a clean build

**Filed by**: aeb Claude, 2026-06-14, climbing the agent-driven-container ladder
against ../google-monorepo-sim. Surfaced because a per-job container forces a
CLEAN build (no checked-in `target/`/`Cargo.toml` to lean on), which the host
had been papering over.

**Severity**: high for any rust crate that consumes a vendored crate via a
`dep()` on a `.crate.ae` — a clean `aeb <target>` generates a `Cargo.toml`
WITHOUT the `[dependencies]` entry, so `cargo build` fails
`E0432/E0433: use of undeclared crate or module`.

## Repro (host, current aeb 2cf7038 — NOT container-specific)

```
cd google-monorepo-sim
rm -rf target                              # force a clean build
aeb rust/components/vowelbase/.build.ae    # regenerates Cargo.toml
cat rust/components/vowelbase/Cargo.toml   # → NO [dependencies]; jni missing
```

`rust/components/vowelbase/.build.ae` declares:
```
build.dep(b, "libs/rust/registry/vendor/jni/.jni.crate.ae")
rust.cargo_project(b) { crate_name("vowelbase"); ... }   # never names jni
```
and `libs/.../jni/.jni.crate.ae` does `rust.crate_vendored(b, "jni~../../../libs/.../jni")`.

The generated manifest SHOULD contain:
```
[dependencies]
jni = { path = "../../../libs/rust/registry/vendor/jni" }
```
(the checked-in Cargo.toml has exactly this, hand-written) — but a clean aeb run
emits a manifest with no `[dependencies]` section at all.

## What the design intends (and where it breaks)

- `crate_vendored` (lib/rust/module.ae:1001) writes artifact
  `rust_path_deps_including_transitive` = `"jni~<path>"`. Docstring: *"Consumers
  of cargo_project/cargo_crate merge these with their DSL-declared path_deps."*
- The artifact IS written — verified on both host and container at
  `target/jni.crate/libs/rust/registry/vendor/jni/rust_path_deps_including_transitive`.
- BUT `cargo_project` is NOT reading that artifact from its `dep()` predecessor
  and merging it into `[dependencies]`. So the path-dep is dropped.

So the break is the CONSUMER side: `cargo_project` (and presumably `cargo_crate`)
must, when generating `[dependencies]`, also pull every
`rust_path_deps_including_transitive` artifact produced by its build deps and
emit each `name = { path = "..." }`. Today it only emits its own DSL-declared
`path_dep`s, ignoring the vendored-crate contributions.

## Why it hid until now

The checked-in `Cargo.toml` already had the jni dep, and an incremental host
build (with a populated `target/`) didn't overwrite it / happened to still
satisfy cargo. A per-job CONTAINER build starts clean every time (the whole
point — ephemeral, reproducible), so it regenerates the manifest from scratch
and the omission becomes fatal. Good argument for clean-build CI: containers
catch what stale local trees mask.

## What's wanted

`cargo_project` / `cargo_crate`, when emitting `[dependencies]`, merge in the
`rust_path_deps_including_transitive` artifacts of all build deps (each →
`<name> = { path = "<path>" }`), de-duped against DSL-declared path_deps.
Proven: a clean `aeb rust/components/vowelbase/.build.ae` emits the jni path-dep
and `cargo build` succeeds (→ libvowelbase.so), with NO hand-written Cargo.toml.

## Cross-ref

- memory `layered-temp-containers-on-aeb-base` (the ladder that found this)
- lib/rust/module.ae: `crate_vendored` (writer, ~1001), `path_dep` (~92),
  `[dependencies]` emit (~195, ~628 — the merge that's missing the vendored read)
