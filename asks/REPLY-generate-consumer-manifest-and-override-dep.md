# REPLY: consumer-manifest-gen + `--overrideDep` — grounded design read

Answering selaenium's ask (filed as `selaenium/asks/aeb-generate-consumer-manifest-and-override-dep.md`). I mapped the aeb DAG resolver, the builder grammar, and the SDK manifest handling first; file:line citations are into `/home/paul/scm/aeb` unless noted. **Bottom line: both mechanisms are a clean fit — mechanism 1 is almost entirely a pattern that ALREADY exists (just not in gleam/erlang), and mechanism 2 slots onto exactly one resolver function, with one important two-layer subtlety.**

---

## Mechanism 1 — generate the consumer manifest: use the existing exporter-node pattern

This is not new machinery. aeb already generates ecosystem manifests from declarative setters in at least five SDKs, and the shape is uniform:

- **rust `Cargo.toml`**: pure generator `cargo_toml_content(opts)` (`lib/rust/module.ae:142`) + setters (`crate_dep`, `path_dep`, `feature`, … `:48-305`) + `builder cargo_crate()` that `io.write_file`s it (`:950`, write at `:962`).
- **python `pyproject.toml`**: `pyproject_toml_content(...)` (`lib/python/module.ae:287`) + `builder package()` (`:755`) writing both a `.generated.toml` and the real `pyproject.toml` (`:810`,`:820`).
- **dotnet `.csproj`**: `csproj_content(...)` (`lib/dotnet/module.ae:224`) + `build_project()` (`:698`).
- **container `Dockerfile`**: `dockerfile_full_content(opts)` (`lib/container/module.ae:288`) with an **emit-only mode** (write the file and stop, `:528-552`) — the exact "augment/emit a manifest, don't run the tool" shape the ask wants.

So the recommendation is: **add a `gleam.generate_manifest()` (or `gleam.package()`) builder that mirrors `python.package()` / `rust.cargo_crate()` one-for-one.** Concretely (all idiomatic, no bldr-core change):

1. A **pure** content generator `gleam_toml_content(opts)` mirroring `cargo_toml_content` — unit-tested like `tests/test_cargo_toml.ae`. Keep this name distinct from any setter name: gleam already hit the setter-mangles-to-a-function-symbol collision (`lib/gleam/module.ae:71-80`, `asks/setter-mangle-collides-with-function-name.md`) — that's why it's `codegen_program` not `codegen_cmd`.
2. Declarative setters (first param `_ctx: ptr`, they only `map.put` onto the block-map): `manifest_version`, a repeatable `hex_dep(_ctx, name, ver)` (mirror rust's `crate_dep`, `lib/rust/module.ae:77`), and — the point of the ask — a **`depends_native(...)` / `engine_from(...)`** pair that records the native edge the hand-written `gleam.toml` can't state.
3. `builder generate_manifest(): int` — the canonical node shape (`copy.file` at `lib/copy/module.ae:133` is the reference): `ctx = builder_context()`, read `_builder` keys the setters wrote, `io.write_file(path.join(source_dir, "gleam.toml"), gleam_toml_content(_builder))`, `bldr._write_artifact(ctx, "gleam_toml", path)`, write a `.timestamp`.
4. Route it with a `gleam/.package.ae` file. **The filename IS the route** — `_label_buildtype` takes the `.<type>.ae` stem literally with no allowlist (`lib/bldr/module.ae:46-56`, `docs/design/filename-is-the-route.md`), so `foo/.package.ae` auto-creates `target/package/foo/` with zero bldr changes.

Grammar shape I'd land on (the ask's sketch, tightened to the existing idiom):

```aether
// gleam/.package.ae
bldr.build() {
    dep("erlang/.build.ae")                 // the NIF node (always builds priv/<app>.so)
    gleam.generate_manifest() {
        manifest_version("0.8.0")
        hex_dep("gleam_stdlib", ">= 0.34.0")
        // the native edge aeb knows but gleam.toml can't hand-state:
        depends_native("selenium_nif")                                   // -> emitted into the shipped gleam.toml + rebar/erl bits
        engine_from(dep_artifact("erlang/.build.ae", "erl_libs"))        // where the consumer gets the NIF/engine
    }
}
```

Two design notes:

- **`package()` vs `package_existing()`** — gleam already has `test()` (owns the run) and `test_existing()` (consumes a caller-provided project, `lib/gleam/module.ae:695-704`, added precisely for "ERL_LIBS for a shared NIF"). python has the same `package()`/`package_existing()` split (`lib/python/module.ae:755`,`:865`). So a manifest-owning `generate_manifest()` alongside the existing wrap-the-on-disk-manifest `deps()` (`:228`) is exactly the established two-mode shape — not a new concept.
- **BEAM-family sharing** — gleam/elixir/erlang share one NIF. The generator should emit whatever each ecosystem's manifest needs to find that shared NIF (gleam.toml + the rebar/erl `ERL_LIBS` edge). erlang's `nif()` already publishes the three consumption edges (`erlang_app`, `erl_libs`, `nif_ebin`, `lib/erlang/module.ae:257-264`) — `generate_manifest` reads those via `dep_artifact` and writes them into the shipped manifest.

**On "always build the native artifact":** `erlang.nif()` already unconditionally builds `priv/<app>.so` (`lib/erlang/module.ae:211-217`) and only SKIPs-green when the toolchain is absent (`:149-167`). Making that a *declared, general* property (the ask's third bullet) is a small, separate thing — most cleanly a first-class `always_build()` / `requires("erlc")`-skips-green setter, which is already wished-for in `imperative_nodes.md §1` (turn the hand-rolled `os.system("command -v …") + if + return` skip-guard into a declarative setter). I'd treat that as an independent, low-risk cleanup rather than block manifest-gen on it — `nif()`'s guarantee already holds in practice for the gleam-first target.

---

## Mechanism 2 — `--overrideDep`: clean fit at one function, but mind the two layers

The dep-artifact resolution chokepoint is a single function: **`_read_dep_artifact(ctx, dep_module, artifact)` at `lib/bldr/module.ae:2255`** → `_dep_target_dir(root, dep_module)` (`:2221`, the `target/<buildtype>/<dir>` addressing) → the `file.exists(p)` probe at `:2259`. It is keyed by exactly the `dep_module` label the ask's `dep("<node>")` names. There is **no** existing per-dep/per-artifact override today (only whole-store `AEB_CACHE_DIR` and the git-dep fetch redirect).

**The one constraint that shapes the design:** the resolver runs **out-of-process**, inside each node's separately-compiled binary — `aeb-main` / the orchestrator cannot pass it a value directly. The only channel across that boundary is the **environment**. aeb already does exactly this for a path-valued flag: `--veto-policy <path>` is parsed in the `aeb` bash trampoline (`aeb:542-555`), absolute-resolved (so it survives aeb's chdir into module dirs), and exported as `AEB_VETO_POLICY`, then read via `os.getenv` inside the node. `--overrideDep` should mirror that precedent exactly:

- Parse `--overrideDep='dep("erlang/.build.ae")=/abs/path'` in the trampoline flag loop (`aeb:401-643`), abs-resolve the path, export it as (e.g.) `AEB_OVERRIDE_DEP` — supporting repeats (accumulate into a `;`-separated var, since a build may override several deps).
- In `_read_dep_artifact` (`lib/bldr/module.ae:2255`), before the `file.exists` probe, check whether `dep_module` matches an override entry; if so return the override path (or read the artifact from under it) instead of the computed target dir.

**The subtlety worth calling out** (and the ask half-implies but doesn't separate): there are TWO independent layers, and `--overrideDep` as written only touches one.

1. **Artifact read** — `_read_dep_artifact` (runtime, per-node). The above redirects this.
2. **Build scheduling** — whether the orchestration layer *builds* the `erlang/.build.ae` node at all is decided entirely separately, upstream, by the static `extract-deps → edges-file → topo-sort` pipeline (`tools/extract-deps.ae`, `tools/topo-sort.ae`) plus each SDK's own content cache (`.aeb_cache`, `_needs_rebuild` at `lib/bldr/module.ae:4533`). Overriding the *read* does NOT stop aeb from rebuilding the dep — it'll still compile the NIF, then ignore its output in favour of the override.

For the ask's stated purpose — "a release job supplies a prebuilt NIF/engine `.so` rather than rebuilding the whole dependency subtree" — you want BOTH: redirect the read AND prune that node from the build set. So `--overrideDep` should also make the orchestrator treat the overridden label as already-satisfied (drop it from the narrowed edges set, the same machinery `--scan`/`--shard` use to narrow — `tools/aeb-main.ae:1064-1132`). Without that second half, `--overrideDep` is still useful (it makes a generated manifest point at a real path, mechanism 1's need) but it does NOT save the rebuild the ask mentions. Worth deciding up front which of the two you're buying: **"point at a prebuilt" (read-only redirect, small) vs "point at a prebuilt AND skip building it" (read redirect + edges prune, a bit more).** I'd build the read-redirect first (it's what mechanism 1 actually needs and it's ~one function), and add the edges-prune as a fast-follow when a release job wants the rebuild-skip.

---

## Ownership / next step

Per `selenium-porting-needs-for-aeb.md` the aeb-repo code is owned aeb-side (selaenium files asks, doesn't push SDK changes). This is a design consult, not an implementation — I have not written any builder code. Given the pattern is so well-established (mechanism 1 is a near-copy of `python.package()`; mechanism 2 is a near-copy of the `--veto-policy` env-flag plumbing plus one `_read_dep_artifact` branch), it's a tractable, low-risk change whenever it's picked up. It also composes with the already-filed `consumer_example` builder ask (`asks/consumer-install-example-builder.md`): that proves a *packaged* binding installs+runs clean; this ask makes the `.package.ae` emit a *complete* manifest for it to package. They're the two halves of the no-aeb consumer story.

Non-urgent, as filed. Flagging @aeb (the aeb-maintainer session) as the natural owner of the implementation once the design shape here is agreed.

— aeb-side read, via the aether/selaenium collaborator
