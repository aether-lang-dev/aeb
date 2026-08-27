# Imperative-node patterns — where the pseudo-declarative dream leaks

**Purpose:** track the ways real `.ae` build nodes deviate from the clean
pseudo-declarative ideal (`bldr.build() { dep(…); rust.foo() { … } }`). Each
entry is a pattern that pulls a node toward imperative shell-orchestration, why
it happens, whether it's a genuine gap or acceptable, and what a more
declarative form might look like. Living doc — appended as the DSL-rework sweep
surfaces more. Seeded from the servirtium-vcr conversion (2026-08-27).

The dream: a node reads as a *declaration* of what to build, not a *script* that
builds it. Every `os.system`, every `if`, every hand-built path string is a
place the dream leaks.

---

## Baseline data (servirtium-vcr, 113 nodes, post-Shape-A codemod)

Sobering but honest:

| tell | nodes | of 113 |
|---|---|---|
| `os.system` / `os.exec` (raw shell-out) | 79 | 70% |
| control flow (`if`/`while`/`for`) in body | 80 | 71% |
| `return` before the build (skip-guards) | 80 | 71% |
| local vars building paths via `${…}` interpolation | 68 | 60% |
| shell out to `ae build`/`aeb` directly (bypassing SDK builders) | 10 | 9% |

Declarative SDK-builder calls, by contrast: `bldr.build()` ×112 (the wrapper),
then a long tail of ONE each — `rust.cargo_test_existing`, `ruby.rspec`,
`python.test`, `php.test`, `scala.scalac`, `zig.test_existing`, a few
`java.mvn_repo`/`dotnet.build_project`. **servirtium is mostly imperative**: the
declarative builders are the minority; most nodes are hand-rolled `os.system`
orchestration that merely *lives inside* `bldr.build() { }` for the ctx.

So Shape A made the nodes b-free, but it did NOT make them declarative — that's a
separate, deeper gap. This doc catalogs it.

---

## Pattern catalog

### 1. Skip-guard before the build (`return` before `bldr.build()`)
**Example:** `integration/subversion_interop/.svn_checkout.ae`
```aether
aeb(cap) {
    have_svn = os.system("command -v svn >/dev/null 2>&1")
    if have_svn != 0 { println("SKIP — svn not found"); return 0 }
    bldr.build() { … }
}
```
**Why:** the node self-skips when a tool is absent (the documented "skip green on
missing toolchain" convention). The guard MUST run outside the wrapper (it
returns before any build).
**Codemod impact:** breaks the "wrap the whole body" assumption — the wrapper
starts *after* the guard. The one node across all ~435 that needed a hand-pass.
**Declarative wish:** a first-class `skip_unless("svn")` / `requires("svn")`
setter that skips-green declaratively instead of a hand-rolled
`os.system("command -v …")` + `if` + `return`. (Related: the existing
`prereq()` / `--preflight` machinery — could a prereq mean "skip if absent"
rather than "fail if absent"? See asks/prereq-preflight.)

### 2. Raw `os.system` orchestration (the big one — 70% of nodes)
**Example:** most servirtium integration nodes — start a VCR server, poll a log
for READY, run a client, diff output, kill the server — all `os.system`.
```aether
bldr.build() {
    _start = os.system("TAPE_PATH=… ${srv_bin} & …")
    while i < 60 { seen = os.system("grep -q READY …"); … }
    co = os.system("svn checkout … ${PLAYBACK} …")
}
```
**Why:** genuinely bespoke test choreography (spawn/poll/interact/teardown) that
no SDK builder models. This is the honest floor of the imperative escape hatch.
**Declarative wish:** unclear one exists — some of this IS inherently a script.
BUT the recurring shapes (spawn-a-server-then-poll-READY-then-run-a-client) could
become a `service_fixture()` / `wait_for_ready()` builder. Worth watching for the
same shape across repos before deciding it's irreducible.

### 3. Shelling out to `ae build` / `aeb` directly (bypassing the SDK) — 10 nodes
**Example:** `core/.build.ae`
```aether
bldr.build() {
    root = bldr._get("root")
    rc = os.system("cd \"${root}/core\" && ae build --emit=lib --with=fs,net embed.ae --extra _embed_strdup.c -o \"${dest}/…so\"")
}
```
**Why:** `aether.shared_lib` / the aether SDK didn't cover this exact
`--emit=lib --with=… --extra …` invocation when the node was written, so it
shells out to `ae build` by hand.
**Declarative wish:** this is a genuine SDK GAP — an `aether.shared_lib()` (or
`c.program`'s aether-source path) builder that takes `.with(fs,net)`,
`.extra("_embed_strdup.c")`, `.emit("lib")`. Every `os.system("… ae build …")`
is a builder that should exist. HIGH-VALUE to close (turns imperative → declarative).

### 4. Hand-built path strings via `${…}` interpolation — 60% of nodes
**Example:** `out = "${root}/target/subversion_interop"`, then that string is
threaded through a dozen `os.system` calls.
**Why:** the node computes its own output/scratch paths from `root` because it's
orchestrating raw shell, not declaring a builder (which would derive
`target_dir` itself).
**Why it's mostly a symptom, not a cause:** these disappear when #2/#3 do — a
declarative builder owns its paths. Where they remain (genuine scratch dirs for
test choreography), they're acceptable.

### 5b. Node opts OUT of `bldr.build()` entirely (pure imperative, explicit ctx)
**Example:** `integration/subversion_interop/.svn_checkout.ae` — after the
skip-guard, it's ~50 lines of `os.system` spawn/poll/checkout/assert/teardown
with early `return`s, and the ONLY thing it needs from the graph is `root`.
**Resolution used:** it keeps `b = bldr.start()` as a plain explicit local ctx
and calls `bldr._get(b, "root")` explicitly — NO `bldr.build()` wrapper. This is
legitimate: a node that is genuinely a script (returns values mid-body, no
builders, no deps) shouldn't be forced into a declarative wrapper it doesn't use.
The explicit-ctx path still works (a `_ctx`-injected reader accepts an explicit
arg too), so imperative nodes have a clean escape hatch.
**Why this is fine, not a failure:** the wrapper's job is to thread ctx to nested
declarative calls; a node with none doesn't need it. Forcing `bldr.build()`
around a body full of `return`s is worse (returns inside a trailing block are a
foot-gun). The tell to watch: how MANY nodes want this — if it's a large
fraction, the "declarative" framing is aspirational and aeb is really a
script-runner with declarative sugar.
**Frequency:** 1 of ~435 nodes across all repos needed it (the svn node).

### 5. `bldr._get("root")` / low-level ctx reads in node bodies
**Example:** `root = bldr._get("root")` then string-building from it.
**Why:** the node needs the monorepo root for its hand-rolled paths (#4).
**Note:** these are the reader fns we had to flip to `_ctx` injection for Shape A.
They read fine inside `bldr.build()`, but their PRESENCE signals a node doing
path math a builder should be doing. A tell, not a bug.

---

## The honest summary

Shape A delivered **b-free**, not **declarative**. A servirtium node like
`rust/.tests.ae` is now genuinely clean and declarative:
```aether
bldr.build() {
    dep("core/.build.ae")
    lib = dep_artifact("core/.build.ae", "shared_lib")
    rust.cargo_test_existing() { env("SERVIRTIUM_VCR_LIB", lib) }
}
```
But that's the ~30% with an SDK builder. The other ~70% are shell scripts wearing
a `bldr.build() { }` hat. The path from here to the pseudo-declarative dream is
**closing the SDK gaps in #3** (builders for what nodes currently `os.system`)
and **finding the repeatable choreography in #2** (service-fixture builders) —
not more grammar work on `b`. The `b`-removal was necessary but not sufficient.

### 6. Node-local top-level helpers (`_engine()`, `_chromedriver()`)
**Example:** 14 servirtium integration nodes each define a top-level
`_engine()` helper (`command -v podman || echo docker`).
**Why:** the node needs a little reusable logic and factors it into a top-level
function — natural, and encouraged. But it's another sign the node is a *program*
(it has its own functions), not a pure declaration.
**The bug it exposed (now fixed):** transform-ae renamed only the entrypoint, so
these same-named helpers emitted duplicate extern C symbols (`ae_engine`) that
collided at the whole-tree link. Fixed (`55f80a6`) by auto-appending `_` to every
node-local top-level helper → file-local (static) linkage (#279). So this pattern
is now SAFE — nodes can freely define same-named helpers.
**Declarative note:** the *content* of these helpers (shell probes for a
container engine, a chromedriver path) is more imperative escape-hatch (#2). A
node that needs `_engine()` at all is orchestrating containers by hand.

**Next actions this doc implies (not yet asks):**
- `aether.shared_lib()` builder covering `--emit=lib --with= --extra` (#3) — the
  single highest-leverage gap; 10 servirtium nodes shell out to `ae build` today.
- `skip_unless(tool)` declarative skip-guard (#1).
- Watch for a repeating spawn-server/poll-ready/run-client shape (#2) → maybe a
  `service_fixture()` builder.
