# aeb vs Bazel — a Selenium-flavoured musing

Filed alongside the Selenium DAG scaffolding. Sibling to
`itests/pytorch/Aeb_vs_Bazel.md`. Not load-bearing for the migration;
useful framing for why aeb's shape lands where it does versus what a
Bazel-shaped attempt would prioritise differently.

PyTorch surfaced the **hermeticity-vs-honest-input-declaration** axis.
Selenium surfaces a different one: **polyglot DAG hermeticity vs
polyglot DAG cheapness**. The two repos let you triangulate where
Bazel actually earns its complexity and where aeb's per-language SDK
pattern lands the same value for less.

## Same starting point (again)

Bazel and aeb both express Selenium's seven-language graph as a
declarative file-based DAG, greppable rule edges, no recursion-driven
build. Both can answer "what targets are affected by a change to
`java/src/.../Json.java`?" The difference, again, is what each
considers load-bearing past the DAG.

## Bazel's bet: one ruleset per language, hermetic

Selenium's Bazel surface is **`rules_jvm_external` + `rules_ruby_gem`
+ `aspect_rules_js` + `rules_dotnet` + `rules_rust` + native C++
toolchains + Selenium-specific Starlark macros** stitched through
`MODULE.bazel`. Each rule wraps its language's real toolchain in
Starlark and presents Bazel-shaped action graphs. The payoff:

- One sandboxed action graph for the whole repo. A Ruby `rspec_test`
  and a Java `java_test` are scheduled the same way, cache-keyed the
  same way, and execute under the same sandbox.
- A shared content-addressed remote cache. The CI machine that builds
  the Rust `selenium-manager` shares its `.bazel-cache/` with the
  developer machine that runs `rspec` against the gem.
- Pinning artefacts (`maven_install.json`, `pnpm-lock.yaml`,
  paket.lock, `Cargo.lock`, `Gemfile.lock`) get treated as inputs to
  the action's cache key — one source of truth, one re-pin step.

The cost: every rule has a maintained-by-someone-else Starlark
authoring surface. `rules_jvm_external`'s `maven_install_artifacts()`
isn't `pom.xml`; `rules_ruby_gem` isn't `Gemfile`; `aspect_rules_js`
isn't `package.json`. Each rule's documentation, breaking changes,
and contributor learning curve is its own world. Selenium has
non-trivial in-repo Starlark just to glue the rules into the project
shape it wants.

## aeb's bet: one closure DSL, real toolchains under it

aeb has **one `lib/<lang>/module.ae` per language**, each authored in
Aether (a real general-purpose language, not a sandbox-constrained
sub-dialect), each calling the real toolchain via `os.system`. The
SDK pattern looks the same across languages:

```
java.javac(b)      { release("17")     dep(b, "g:a:v") }
ruby.gem(b)        { gemspec("foo.gemspec") }
pnpm.run(b, "lint")
dotnet.build_project_existing(b)
rust.cargo_project_existing(b) { binary_name("selenium-manager") }
python.package_existing(b)
```

No Starlark dialect to learn per ruleset; setters are plain function
calls with an implicit `_ctx`. The DSL ceiling is "what does the
upstream tool's CLI surface"; aeb doesn't try to model its own model
of e.g. maven dependency resolution — it shells out to `aeb-resolve.jar`.

The cost: aeb gives up Bazel's central sandbox + shared remote cache.
A cached classpath resolution from `lib/maven` doesn't share its
key-space with a cached `pnpm install` from `lib/pnpm`. Each SDK does
its own caching; "remote cache" today means "every machine resolves
its own deps."

## Why aeb won't parse `maven_install.json`

The shortcut on the Java side would be: write a tool that reads
Selenium's `maven_install.json` (the `rules_jvm_external`-pinned
closure) and emits an aeb `.bom.ae` automatically. Then 173 Java leaves
would all consume the auto-translated BOM and "scale" trivially.

We pushed back on that. Two reasons:

1. **It crosses LLM.md's load-bearing principle.** aeb doesn't parse
   external config formats. `pom.xml`, `Cargo.toml`, `pyproject.toml`,
   `package.json` are all honoured via shell-outs to tools that
   already parse them — aeb itself reads only `.ae` files. Adding a
   `maven_install.json` parser would be the first crack in that line.
   The next one is "well if we parse JSON for Maven, why not YAML for
   docker-compose, TOML for Cargo.workspaces, ..."

2. **The pin artefact is a Bazel rule's data model, not a portable
   one.** `maven_install.json` is `rules_jvm_external`'s output
   format. It contains transitive closure detail (per-coord URLs +
   sha256s + parent-pom hints), exclusion lists, override rules, and
   coursier-specific knobs. aeb's `lib/maven` doesn't model any of
   that — it shells out to `aeb-resolve.jar` (a small Aether Maven
   Resolver wrapper) which does the same closure walk live. Parsing
   the file would be parsing *Bazel's* model, not Maven's model.

The idiomatic aeb answer is **hand-authored `.bom.ae` files**, one
per language tree (or one global), with explicit pinned coords and
versions. More verbose — Selenium's java tree has ~120 third-party
coords, all of which would live in one file. But every dep edge stays
greppable, the file is plain Aether, and the version travels in the
build grammar instead of in a foreign config format. Convert once,
maintain by hand (or via a one-shot porter script that's not part of
aeb's runtime).

The same logic applies to:

- `pnpm-lock.yaml` — aeb shells out to `pnpm install --frozen-lockfile`,
  which already parses it. aeb doesn't.
- `paket.lock` (Selenium's .NET pinning) — aeb shells out to `dotnet`,
  which honours `paket` via the project file. aeb doesn't.
- `Cargo.lock` — aeb shells out to `cargo build`, which honours it.
- `Gemfile.lock` — aeb shells out to `bundle install`, which honours it.

In every case the **lock artefact is upstream's responsibility**.
aeb's job is to issue the command that consumes it, not to
re-implement that consumer.

## What Selenium reveals about polyglot DAGs

Three things worth noting from this conversion exercise:

1. **Cross-language artefact deps are surprisingly rare.** Selenium's
   bindings communicate at runtime over the WebDriver wire protocol,
   not at build time over shared artefacts. The one real cross-tool
   handoff is **Python wheel embeds Rust binary** (`setuptools-rust`
   compiles `selenium-manager` into the wheel). aeb expresses this as
   a `build.dep` edge from `py/.dist.ae` onto `rust/.build.ae`, with
   the Rust side's `cargo_binary` artifact consumed at wheel-build
   time. Bazel expresses it as a `py_wheel` rule with a `data` attr
   on the rust target. Same graph shape; same wire-up cost.

2. **Codegen-from-spec is a recurring polyglot pattern.** Selenium's
   `py/generate_bidi.py` reads a CDDL spec fetched from `w3c/webref`
   and writes ~20 Python modules. Upstream Bazel fetches the spec via
   `MODULE.bazel`'s `http_file` + extracts via `webref_cddl.bzl`
   macros. aeb expresses the same chain as `fetch.file(b)` + a
   `python.codegen(b)` block — one `lib/fetch` SDK, one
   `lib/python.codegen` SDK, no project-specific Bazel macros. The
   fetch-and-codegen pair is small enough to live in two `.ae` files;
   Bazel needs the `webref_cddl.bzl` machinery because each
   `MODULE.bazel` extension is module-scoped.

3. **`./go format`-shaped pre-build chains have no aeb-side
   abstraction yet.** Selenium runs a Rake-driven `buildifier +
   update_copyright + per-language formatters` step before CI's real
   build. aeb has no `format` builder primitive — `bash.run(b)` plus
   `pre_command` would do it, but there's no canonical SDK shape for
   "run language-specific formatters as a phase." For now, hand it
   off to the bash SDK or to upstream's existing `./go format` script
   verbatim. Worth a roadmap line: `lib/format` could canonicalise the
   shape.

## The clear gap (Selenium edition)

Same as PyTorch's clear gap, reframed:

- **Bazel** ships a uniform action-graph cache across all rulesets.
  An aeb conversion of Selenium would have per-SDK caches (lib/maven
  caches classpaths; lib/cargo relies on cargo's own incremental;
  lib/pnpm relies on pnpm's; lib/python relies on pip wheel cache).
  No central key space; no shared remote cache.

- **aeb** ships a one-language closure DSL and per-language SDKs that
  call the real upstream toolchain. Smaller surface to maintain;
  fewer foreign Starlark dialects to learn; greppable dep edges
  through the whole graph.

For a hyperscaler whose CI fleet builds the same DAG thousands of
times per hour, Bazel's shared cache pays for itself many times over.
For a polyglot codebase that a small team maintains and individual
contributors build mostly-incrementally on their own machines, aeb's
"each SDK uses upstream's caching, the orchestrator just sequences"
model is enough.

## The Wingerd middle ground (same as PyTorch)

The remote-cache gap can close without going hermetic — see
`docs/plans/distributed-cache-plan.md` and the follow-up section in
`itests/pytorch/Aeb_vs_Bazel.md`. Selenium would benefit from the
same Wingerd-mainline-model shared cache if it ever materialises.
Until then, accept that "Bazel-with-remote-cache" beats "aeb +
per-machine cache" on CI throughput, and aeb beats Bazel on
authoring ergonomics.

## Net positioning (Selenium edition)

- **Bazel** for the CI-throughput problem its hermetic-sandboxed
  action graph was built for: a known fleet, a shared cache, rule
  authors and rule consumers as different orgs.
- **aeb** for the per-language SDK ergonomics + greppable DAG
  problem: a small team owning both the rules and the consumption,
  a polyglot tree, a willingness to trade central caching for
  zero-Starlark-dialect authoring.

Selenium itself sits closer to Bazel's natural fit (large team,
shared CI fleet, contributors who aren't always platform engineers).
The interest of this conversion isn't "Selenium should use aeb" —
it's "aeb can express this graph with less ceremony, and the cost is
the same one the PyTorch musing names: hermeticity."
