# aeb DSL rework — drop the explicit `b` from builder call sites

**Status:** PLAN — design PROVEN against `ae` (Shape A verified, §2.5/§5), no
production code yet. Approved direction: a **fully b-free node body** via a
`build() { … }` wrapper, landed as a coordinated flag-day. **Why it matters:**
the explicit build handle `b` threaded into every SDK builder —
`rust.cargo_test_existing(b) { … }` — plus every `dep(b, …)` and `build.start()`
is aeb's most visible divergence from idiomatic Aether DSLs. Aether itself
(std/, contrib/) and aether-ui write `button("OK") { … }` with **no** threaded
object; the parent context is injected invisibly. aeb's boilerplate `b` is a
paper-cut on every node in every downstream repo, and the pitch here is
explicitly **"nicer than Bazel to read and write"** — so the ergonomics are not
cosmetic, they're the product. This plan removes `b` entirely from node bodies.

---

## 1. What the mechanism actually is (the root of the confusion)

Aether's builder DSL has **two** context mechanisms (docs:
`aether/docs/closures-and-builder-dsl.md`):

| | Param spelling | Who supplies it | Visible at call site? |
|---|---|---|---|
| **Injected context** | `_ctx: ptr` / `_builder` | compiler, via `builder_context()` inside a trailing block | **No** |
| **Explicit parameter** | `ctx: ptr` (no underscore) | the caller, by hand | **Yes** — this is the `b` |

aether-ui uses the first: `button(_ctx: ptr, label)` → call site `button("OK")`.
aeb uses **both at once** in a single builder:

```aether
builder cargo_test_existing(ctx: ptr) {        // ctx = EXPLICIT (the b)
    source_dir = build._get(ctx, "source_dir") //   used for graph/artifacts
    …
    cmd = …env_export_prefix(_builder)…        // _builder = INJECTED (the block config)
}
```

- `ctx` (the `b`) carries **build-graph identity**: deps, artifacts, root dirs,
  test-result recording. Threaded through `build.dep(b, …)` /
  `build.dep_artifact(b, …)` *before* the builder is called.
- `_builder` carries the **per-call config** the trailing block's setters
  (`env()`, `extra()`, …) fill.

They are two different objects. That's why you can't just delete `b` — but you
*can* stop making the caller type it, by having the builder pull graph identity
from the injected context too.

**`ctx` vs `_ctx` is the only thing gating injection.** No *aether* change is
required to remove `b` — it's an aeb SDK convention, reversible entirely on the
aeb side (Shape A, §2.5, uses only existing language mechanisms). What it DOES
require is a coordinated change to node *structure* (§4) — that's the real cost,
not a language limitation.

---

## 2. Blast radius (measured 2026-08-26)

Live downstream (dead forks `mquickjs*`, `skirae` excluded): **435 node files**,
**~1,600 `b`-threaded lines** across **~14 repos**.

| repo | nodes w/ `b=build.start()` |
|---|---|
| servirtium-vcr | 114 |
| aether-ui | 101 |
| avn | 62 |
| aeb (self) | 60 |
| google-monorepo-sim | 55 |
| selenium | 47 |
| html-sanitizer | 34 |
| skir | 30 |
| hosted-language-headers | 11 |
| ebiten | 9 |
| zsync | 5 |
| aedis / fbs-core / aeb-test | 2 / 1 / 1 |

aeb's own surface to change: **147 builder defs** taking explicit `ctx:` across
**41 lib modules**. Plus the non-builder graph functions `dep`,
`dep_artifact`, `publish_artifact`, `_record_test_result` (all `ctx: ptr`).

A blunt rewrite = flag-day across ~1,600 lines in 435 files in 14 repos, several
of them (selenium, servirtium-vcr, aether-ui) actively moving. **We do not want
that.** §3 avoids it.

---

## 2.5 The end-user grammar: two b-free shapes — one works, one doesn't (VERIFIED)

The target is a **fully b-free node body**, not just b-free builder calls. Two
candidate shapes were tested against real `ae` (2026-08-27). Both COMPILE; only
one actually threads the build graph.

**Shape A — a `build() { … }` wrapper (WORKS):**

```aether
aeb(cap) {
    build() {
        dep("core/.build.ae")
        dep("java/.build.ae")
        lib = dep_artifact("core/.build.ae", "shared_lib")
        java.javac_test() { source_layout("maven idiomatic") release("22") }
        java.junit5() {
            jvm_args("--enable-native-access=ALL-UNNAMED")
            env("SERVIRTIUM_VCR_LIB", lib)
        }
    }
}
```

**Shape B — bare body, no wrapper (DOES NOT WORK):**

```aether
aeb(cap) {
    dep("core/.build.ae")                                 // _ctx is NULL here
    lib = dep_artifact("core/.build.ae", "shared_lib")    // _ctx is NULL here
    java.junit5() { … }
}
```

**Why A works and B doesn't (measured, not assumed).** Aether's injected context
is pushed by a **trailing block**. Shape A's `build() { … }` *is* that block: the
wrapper pushes one context object, and every `dep()` / `dep_artifact()` /
`java.junit5()` inside auto-receives it as `_ctx`. Probe result: in Shape A,
`dep_artifact` **sees** what `dep` wrote into the shared ctx — the graph threads.
Shape B has no enclosing block, so nothing is on the context stack → `_ctx`
resolves to **NULL** for every top-level call → `dep()` and `dep_artifact()`
cannot share a session, cannot build a graph. Shape B is not viable without a
LANGUAGE change (making `aeb(cap)`'s own body establish an ambient context at
function entry, which `ae` does not do today).

**Verdict: Shape A is the target.** It is fully b-free, needs NO aether change,
and is mechanically proven to thread the graph. `build() { … }` replaces
`b = build.start()`; the whole node loses every `b`.

---

## 3. The design: Shape A — an injected `build()` wrapper, whole-tree

Shape A dissolves the old "Risk B" (below): because `dep`/`dep_artifact` now sit
INSIDE the `build() { }` trailing block, they get the injected context for free,
exactly like the SDK builders. There is no ambient-context-at-entry problem to
solve — the wrapper *is* the context scope.

The pieces:

1. **Add a `build()` builder** (the wrapper). A trailing-block builder that
   creates the session/root context and pushes it — i.e. what `build.start()`
   builds today, but as a `_ctx`-pushing builder so its block body inherits it.
2. **`dep` / `dep_artifact` / `publish_artifact` / `prereq` → `_ctx`-injected**
   (drop the explicit `ctx:` param; read the injected context). They already
   take a ctx first arg; this is the `ctx:`→`_ctx:` rename + it now resolves
   from the block.
3. **All 147 SDK builders → `_ctx`-injected** (`builder foo(ctx: ptr)` →
   `builder foo(_ctx: ptr)`). NB: this is the SAME 147 signatures the `: int`
   sweep (commit `97e189d`) just rewrote — see §3.5. The rename rides the same
   lines.
4. **Rewrite the ~435 downstream nodes** into Shape A (wrap the body in
   `build() { … }`, delete every `b`).

## 3.5 Coordination window with the `: int` sweep (act now)

The node-return fix (`97e189d`) just declared all 147 builders `: int` —
`builder foo(ctx: ptr)` → `builder foo(ctx: ptr): int`. The `b`-rework renames
the SAME token on the SAME lines — `ctx:` → `_ctx:`. Doing the `b`-rework NOW,
right after the sweep, means one coordinated pass over those signatures while
the tests are green and the surface is fresh, instead of touching all 147 twice.
This is the "exhaustive coordinated set of commits" moment.

---

## 4. The real cost: this is a FLAG-DAY, not gradual (be honest about it)

Earlier drafts of this plan hoped for a gradual, backward-compatible rollout
(keep the old `b` form compiling, migrate repo-by-repo). **Shape A gives that
up on purpose**, because it changes the node's STRUCTURE, not just a call
argument:

- Old node: `b = build.start(); dep(b, …); rust.foo(b) { … }`
- New node: `build() { dep(…); rust.foo() { … } }`

These are different shapes. Once `dep`/the builders become `_ctx`-injected and
lose their explicit `ctx:` param, the OLD `dep(b, …)` call no longer type-checks
(it passes an arg the function no longer declares). So:

- **No dual-mode.** The moment aeb's lib flips, every downstream node must
  already be Shape A, or it breaks.
- **Therefore: coordinated.** aeb lib + all ~435 nodes across ~14 repos land
  together (or each repo pins the pre-flip aeb until its own nodes are
  converted). This is the flag-day the user explicitly asked for — "an
  exhaustive coordinated set of commits."

Two things that make the flag-day tractable:
- The node rewrite is **mechanical** — `b = build.start()` + body → `build() {`
  + body + `}`, then delete `\b(\w+\.)?\w+\((b)[,)]` → drop the `b`. A codemod
  does a repo in one pass; every node is the same transform.
- **Pinning buys time.** A downstream repo can stay on the pre-flip aeb release
  (AEB_REF pin) until someone runs the codemod there; it doesn't have to land in
  the same hour, just before it next bumps aeb.

**Block-less builder calls (former Risk A) still need handling.** aeb calls some
builders with `(b)` and NO trailing block — `python.install(b)`,
`rust.check_workspace(b)`, `rust.cargo_project_existing(b)`. With no block there
is no injected context. Options: (a) give them a one-line `build() { … }` block
even when empty of setters, or (b) keep a session-passing statement form for
these few. Enumerate them during the rust pilot (§6) and pick per case; there
are only a handful.

---

## 5. Spike — DONE (2026-08-27). Shape A verified; Shape B refuted.

The pivotal unknown ("what does the injected context resolve to in each shape")
is answered empirically:

```aether
build_wrap(_ctx: ptr) { return map.new() }          // the wrapper pushes a ctx
dep(_ctx: ptr, p: string): int { map.put(_ctx, p, "1"); return 0 }
dep_artifact(_ctx: ptr, m: string, a: string): int {
    if map.has(_ctx, m) == 1 { println("SAME ctx — graph threads") }  // Shape A: fires
    return 0
}
aeb(cap) { build_wrap() { dep("core/.build.ae"); _l = dep_artifact("core/.build.ae","x") } }
```

Result: **Shape A** — `dep_artifact` sees `dep`'s write (shared ctx, graph
threads). **Shape B** (same calls at the bare top level of `aeb(cap)`, no
wrapper) — `_ctx` is NULL for both, no shared session. Conclusion in §2.5. No
further spike needed; the design is proven.

---

## 6. Rollout (coordinated flag-day)

1. **Pilot `rust` end-to-end in aeb.** Add the `build()` wrapper builder; flip
   `rust`'s builders + `dep`/`dep_artifact` to `_ctx`-injected; enumerate the
   block-less `(b)` calls and resolve them (§4). Convert ONE real servirtium-vcr
   rust node to Shape A and build it green — the honest end-to-end proof (a real
   node, real deps, real `.so` artifact, not a synthetic).
2. **aeb self + full lib.** Flip all 41 lib modules' builders + the graph verbs,
   one commit per SDK family. Convert aeb's own real nodes (the 8 `tools/*`
   dist/install nodes; the itests are the regression surface). Full suite green.
3. **Downstream coordinated.** For each of the ~14 repos: run the node codemod,
   build green, commit. Repos not yet converted PIN the pre-flip aeb release so
   they keep building until their turn. servirtium-vcr (114 nodes, most
   polyglot) is the primary test-bed and goes first after aeb.

**Ordering rule:** a repo either (a) is on Shape A against post-flip aeb, or
(b) pins pre-flip aeb. Never a post-flip aeb against un-converted nodes.

---

## 7. Test-bed note

aeb's own repo has ~no real nodes outside `itests/`/`tests/` (just 8
`tools/*/.dist.ae`/`.install.ae`). The real polyglot node populations live in
the siblings: **servirtium-vcr (114) is the primary test-bed** — largest, most
language-diverse, already the proving ground for the rust `extra()`, 1b, and
REQUEST 4 work. The rust-pilot end-to-end proof (§6.1) converts a real
servirtium node.

---

## 8. Open questions for Paul

- **Block-less `(b)` calls** (§4): empty `build() { }` block, or keep a
  statement form for the handful? (Decide at the rust pilot.)
- **Codemod vs hand-edit** for the ~435 nodes — codemod + per-repo eyeball.
- **Pin-then-migrate order** across the 14 repos — which lead (servirtium-vcr
  first is the natural choice).

---

## TL;DR

The target grammar is **Shape A** — a `build() { … }` wrapper that makes the
node body **fully b-free** (every `b` gone, including `dep`/`dep_artifact`).
Verified against `ae`: Shape A threads the build graph; the wrapper-less Shape B
leaves `_ctx` NULL and can't. No aether change needed. The cost, stated
honestly: this is a **coordinated flag-day**, not the gradual dual-mode earlier
drafts hoped for — Shape A changes node STRUCTURE, so aeb's lib and the ~435
nodes across ~14 repos move together (repos pin the pre-flip release until their
turn). Do it NOW while the `: int` sweep has the same 147 signatures fresh
(§3.5). Pilot `rust` on a real servirtium-vcr node; servirtium-vcr (114 nodes)
is the primary test-bed.
