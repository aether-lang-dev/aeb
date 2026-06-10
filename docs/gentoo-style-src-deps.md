# Gentoo-style source-dependency graphs in aeb

Status: **design / analysis.** No `.src.ae` node type or USE-flag vector
exists yet; this doc captures *what would be needed* and — the headline —
**how little of it is new**, because aeb's core already *is* a source-dependency
graph that produces binaries as it traverses.

> The question this answers: "Could aeb support a Gentoo-style source-dep graph
> that makes binaries as it goes?" Short answer: yes, and most of it is naming
> patterns aeb already has, not building a new engine.

## What "Gentoo-style" actually means

Gentoo/Portage (`emerge`) is the canonical *source-based* package model. Its
defining properties:

1. **A source-dependency graph**, topologically ordered.
2. **Build each node from source** as you traverse it (no prebuilt-binary
   assumption).
3. **Upstream artifacts are consumed downstream** — a package you compiled is
   installed so its dependents can link/use it.
4. **A from-source dep can itself be a tool** used to build later deps
   (bootstrap chains: a compiler builds a compiler builds the world).
5. **USE flags** — a cross-cutting feature vector (`USE="ssl -X systemd"`) that
   every package reads to decide what to compile in.
6. **A repository of recipes** (`*.ebuild` keyed `category/package-version`)
   that *fetch* a source tarball, unpack, and build it.
7. **System-wide install with slots** — multiple versions coexist in a live
   system.

The interesting finding is which of these aeb has *natively*, which it
*approximates*, and which are genuine (and small) extensions.

## What aeb already is — properties 1–4, for free

aeb's fundamental operation is **a source-dependency graph that produces
binaries as it traverses**: topo-sort the `.build.ae` DAG, build each node from
source, and downstream nodes consume the artifacts (classpaths, `.so`s, crate
libs) the upstream nodes produced into `target/<module>/`. That *is* the
Portage model:

| Portage property | aeb |
|---|---|
| 1. Source-dep graph, topo-ordered | ✅ the `.build.ae` DAG — the whole point |
| 2. Build from source as you traverse | ✅ each node compiles; no prebuilt assumption |
| 3. Upstream artifacts consumed downstream | ✅ `target/<module>/` artifacts propagate transitively |
| 4. A from-source dep that *is* a tool, used to build later deps | ✅ the **bootstrap-tool pattern** (`lib/c`: "compile+link a small C tool, then RUN it") and real consumers — skir's generator builds itself then generates bindings; mquickjs builds its C-port engine then `gen/` consumes it |

Property 4 is the Gentoo-defining move — **a from-source dep whose output is a
binary the rest of the build consumes** — and aeb does it today. skir
(`generators/*/.build.ae` build a code generator, `bindings/*/.build.ae`
consume it) is a literal small source-bootstrap graph.

One thing aeb does *better* than Gentoo here: Gentoo **recompiles**; aeb
**content-addressed-caches** (`lib/cache`), so an unchanged source-dep is a
hash hit, not a rebuild. The traverse-and-make-binaries shape is identical; the
rebuild discipline is stricter.

## The genuine extensions — properties 5–7

Three Portage properties aeb does not have out of the box. Two are small and
have existing templates; one is a deliberate non-goal.

### A. Source-package node type (`.src.ae`) — property 6

Gentoo's nodes are ebuilds that *fetch* a tarball and build it. aeb's nodes
point at source *already on disk* (or vendored). aeb has no "fetch
`foo-1.2.3.tar.gz` from a mirror, unpack, compile, expose the artifact" node as
a first-class type.

But aeb **already has the exact node shape** — the typed-dep declaration files:

```aether
// libs/rust/registry/vendor/serde_json/.serde_json.crate.ae
import build
import rust
main() {
    b = build.start()
    rust.crate_registry(b, "serde_json~1.0")   // declares HOW to source this dep
}
```

`.crate.ae` / `.jar.ae` / `.npm.ae` / `.whl.ae` are dot-prefixed `.ae` nodes
that declare *how to obtain a dependency* and expose it to consumers via
`build.dep(b, "…/.serde_json.crate.ae")`. They resolve to a **prebuilt
artifact to link**. A Gentoo-style source package is the **same declaration
shape resolving to source to compile**:

```aether
// vendor/zlib/.zlib.src.ae  — a from-source dependency
import build
import c
main() {
    b = build.start()
    src.fetch(b, "https://zlib.net/zlib-1.3.1.tar.gz",
                 "sha256:9a93b2b7df…")   // pinned, content-addressed
    // build the unpacked source into an artifact downstream nodes link
    c.sources(b, "*.c")
    c.static_lib(b, "libz.a")
}
```

A consumer `dep(b, "vendor/zlib/.zlib.src.ae")` gets `libz.a` built-from-source
and on its link line — exactly the Gentoo "compile the dep, then build against
it" flow, expressed in aeb's existing dep-graph grammar. What's new is small:

- a **`src` SDK** (`src.fetch(url, sha256)` → download to a cache, verify the
  hash, unpack) — the fetch+unpack+verify primitive aeb lacks today;
- it slots into the existing typed-dep family (`.src.ae`), so `extract-deps` /
  `gcheckout` / the DAG walk follow it with no new machinery — they already
  follow `.crate.ae` et al. by the same dot-suffix convention.

The fetch is the only genuinely-new capability. Everything else — the node, the
DAG edge, the artifact propagation, the cache keying — is reused. And fetch is
the same primitive the **`prereq()`/provisioning** design needs (pinned-tarball
recipes; see below), so it is shared, not bespoke.

### B. USE flags — a graph-wide feature vector (property 5)

Gentoo's USE flags are *cross-cutting*: one set (`USE="ssl -X"`) that every
package consults to decide what to compile in. aeb has **per-node** feature
setters today — `rust.features(b, "…")`, `c.flag(b, "…")`, `crate_type(…)`,
`with_*` — but no graph-wide vector a whole build reads.

The template for adding one already exists: **`--coverage`**. It is a
cross-cutting build flag exported to every SDK builder (via `AEB_COVERAGE`),
which each SDK honors in its own language's terms, and which **segregates the
cache key** so coverage builds don't collide with regular ones. USE flags are
the same mechanism with a richer vocabulary:

```sh
aeb --use ssl,-X,+jemalloc  app/.build.ae
# → AEB_USE="ssl,-X,+jemalloc" exported; SDKs branch on it; cache key includes it
```

A node reads the active USE set and conditionally adds sources/flags/deps:

```aether
aeb(cap) {
    b = build.start()
    if build.use(b, "ssl")  { build.dep(b, "vendor/openssl/.openssl.src.ae") }
    if build.use(b, "jemalloc") { c.flag(b, "-DUSE_JEMALLOC") }
    c.compile(b)
}
```

What's new: a `--use`/`AEB_USE` flag parsed by the trampoline (the `--coverage`
parse is the template), a `build.use(b, name)` query, and — critically —
**cache-key segregation by the USE vector** (again, `--coverage` already proves
this pattern, so the cache plumbing exists). The USE *vocabulary* (which flags
mean what) is per-project, declared by the SDKs/nodes that read them — aeb
ships the mechanism, not an opinionated flag list.

### C. System-wide install + slots — property 7 (a deliberate non-goal)

Gentoo installs into a live system (`/usr`, `/etc`) with *slots* so multiple
versions coexist, mutating shared global state. **aeb deliberately does not do
this** — it builds into a per-project `target/`, hermetically, and never
mutates a shared system. That is a *feature*, not a gap: aeb is
project-scoped-and-reproducible where Gentoo is system-scoped-and-stateful.

You probably do **not** want aeb to become a `/usr` package manager — that
would fight its founding hermeticity. The expressible-today equivalent is a
`.dist.ae` node that *packages* the produced binary (a tarball, a Docker image,
a `brew` formula via the exporters), which is "install the artifact somewhere"
without the live-system slot machinery. If a consumer genuinely needs
"multiple versions of a source-dep coexisting," that is two differently-named
`.src.ae` nodes (`.zlib-1.3.src.ae`, `.zlib-1.2.src.ae`) — the DAG already
supports siblings; "slots" become ordinary distinct nodes.

## The tie-in: this is the same instinct as `prereq()`/provisioning

A Gentoo-style **source toolchain dep** (build your compiler/runtime from
source so the version is exact and deterministic) is *exactly* the
toolchain-determinism instinct already captured in
[`build-prerequisites-and-provisioning.md`](build-prerequisites-and-provisioning.md).
The Snap CI assessment
([`aeb-vs-snap-ci-and-the-wake-on-commit-flow.md`](aeb-vs-snap-ci-and-the-wake-on-commit-flow.md))
named the same pattern in Snap's `ruby-build`/`python-build`/`nodejs-build`
repos: maintain a from-source build of each runtime so "pick version X" is
deterministic, not whatever happens to be on PATH.

So a from-source source-dep graph sits at the intersection of three things aeb
already has or has designed:

- **the source-dep DAG** — have (the `.build.ae` graph);
- **the bootstrap-tool pattern** — have (`lib/c`; skir; mquickjs);
- **`prereq()`/provisioning** — designed (the `src.fetch` primitive a `.src.ae`
  needs is the same pinned-tarball fetch the provisioning recipes use).

`prereq("zig:0.13")` says *"this build needs the zig toolchain present"* (an
operator provisions it); a `.zig.src.ae` says *"this build builds zig from
source as a graph node."* Same determinism goal, two grains: prereq is "have it
installed," the source-dep is "build it here." They compose — a `.src.ae` could
*be* what a provisioning recipe builds.

## What it would take, concretely

In rough build order:

1. **`src` SDK — `src.fetch(url, sha256)`** + unpack into a content-addressed
   cache. The one genuinely-new primitive; shared with provisioning's pinned
   fetches. Pinned-hash, fail-closed on mismatch (a fetch that can't verify is
   a build failure, never a silent substitution — the supply-chain discipline
   from the veto stack applies: a fetched tarball is untrusted, so it composes
   with `--vet`/`--sandbox`).
2. **`.src.ae` node type** — a dot-suffix typed-dep declaration resolving to
   *built-from-source artifact*; `extract-deps`/`gcheckout`/the DAG walk follow
   it for free (same convention as `.crate.ae`).
3. **USE flags** — `--use`/`AEB_USE` (parse template: `--coverage`), a
   `build.use(b, name)` query, USE-vector cache-key segregation.
4. **Per-language `src.*` build glue** — how a fetched C/Rust/… source tree
   compiles to the artifact a consumer links (mostly reuses the existing
   `c.static_lib`/`rust.cargo_*`/etc. builders against the unpacked tree).

None of this reshapes the graph engine. aeb is already a source-dep graph that
makes binaries as it traverses; "Gentoo-style" adds a *fetch* primitive, a
*from-source dep node* that uses it, and a *cross-cutting feature vector* — each
modeled on a mechanism aeb already ships. The system-install/slot half is left
out on purpose: aeb's hermetic `target/` is the better answer for a build tool.

## Relationship to other docs

- Source-dep nodes are untrusted source the build fetches → they compose with
  [`build-veto-and-sandbox.md`](build-veto-and-sandbox.md) (a `.src.ae`'s
  fetched+built tree is exactly what `--vet`/`--sandbox` exist to contain).
- The `src.fetch` primitive is shared with
  [`build-prerequisites-and-provisioning.md`](build-prerequisites-and-provisioning.md)
  (pinned-tarball toolchain recipes).
- This is the source-based-package answer to the Snap CI lineage's owned
  from-source toolchain ([`aeb-vs-snap-ci-and-the-wake-on-commit-flow.md`](aeb-vs-snap-ci-and-the-wake-on-commit-flow.md)).
