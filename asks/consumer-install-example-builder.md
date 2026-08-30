# A `consumer_example` builder family: prove a package installs + runs from clean

**From:** the Selenium-on-Aether port (`paul-hammant/selaenium`), migrating its
binding nodes to the declarative bldr/SDK grammar, 2026-08-30.

## The recurring pattern with no builder

Every one of our 18 language bindings has an `.example.ae` that proves the
distributable **actually works for a third party**, distinct from the in-tree
tests: **install the packaged artifact into a CLEAN, isolated environment — no
source tree on the path, the dev env var unset — then run a small consumer that
loads the bundled native `.so` and drives the protocol.** Concretely:

| binding | package | clean-install |
|---------|---------|---------------|
| python  | wheel   | fresh venv, `pip install`, source tree off PYTHONPATH |
| .NET    | nupkg   | local NuGet feed only (no nuget.org), `dotnet restore` in a fresh dir |
| ruby    | gem     | clean GEM_HOME, `gem install` |
| node    | tarball | fresh dir, `npm install ./pkg.tgz` |
| rust    | crate   | consumer crate with a path dep, no in-tree `../core` sibling |
| go/dart/nim/zig/lua | module/pkg | staged copy with the bundled `.so`, no repo sibling |

The shared assertions: the packaged artifact restores from **only** its own feed
(isolation — proves nothing leaks from the source tree), the **bundled `.so`
lands next to / inside the installed package**, and the consumer **runs** (an
`ffi` mode with no browser, optionally a `live` mode that self-skips without a
driver). This is the honest "a naive `pip install` / `dotnet add package` just
works" test — the thing a real user hits first.

aeb has no builder for it, and google-monorepo-sim has no `.example.ae` nodes,
so there is no reference idiom. Per aeb's own principle
(`docs/design/inline-build-steps.md`: SDK builders for common patterns, inline escape
hatch for bespoke, **promote when it recurs**), this pattern recurs across 18
bindings — it wants to be a real builder rather than 18 inline hand-rolls.

## The ask

A `consumer_example` builder family (one per packaging ecosystem, mirroring how
each SDK already has `pack`/`build_project`/`gem`/`wheel`/`npm_pack`/`cargo_*`):

```
dotnet.consumer_example() {
    package(dep_artifact("dotnet/SeleniumCore/.package.ae", "nupkg"))  # the local feed
    project("dotnet/example")        # the consumer sources (Program.cs + csproj)
    run_arg("ffi"); run_arg("live")  # invoke the consumer once per mode
    unset_env("SELENIUM_CORE_LIB")   # prove ONLY the bundled .so satisfies the load
    expect_native("libselenium_core.so")  # assert the .so landed in the restored app
}
```

and the parallels `python.consumer_example()` (wheel → venv), `ruby....` (gem),
`javascript....` (tarball → npm i), `rust....` (crate path-dep), etc. The
builder owns the isolation (fresh dir, feed-only restore, env scrubbing), the
run, and the pass/fail — the `.example.ae` becomes declarative:

```
bldr.build() {
    dep("dotnet/SeleniumCore/.package.ae")
    dotnet.consumer_example() { ... }
}
```

## Why it's worth a builder (not the escape hatch)

- It recurs 18× — the exact "promote to an SDK builder" trigger the docs name.
- The isolation is subtle and easy to get wrong inline (a leaked global cache or
  a source-tree fallback silently makes the test pass when a real install would
  fail — the very thing the test exists to catch). A builder gets it right once.
- It composes with the existing `pack`/`native_runtime` artifacts already in the
  SDK, so most of the plumbing (the `nupkg`/`wheel` artifact edges) is there.

## Meanwhile

We are holding our `.example.ae` nodes (not converting them to inline Aether)
pending this builder, per the "add to aeb, don't escape-hatch" direction. Our
`.package.ae` nodes already prove the package builds with the `.so` bundled
(verified: the SeleniumCore nupkg ships `runtimes/linux-x64/native/
libselenium_core.so`); the consumer-install proof is the remaining layer.

If a full builder family is too big a first bite, a single
`dotnet.consumer_example()` (the ecosystem we have furthest along) as a
proof-of-shape would unblock us and set the template for the rest.
