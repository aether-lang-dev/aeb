# aeb DSL rework — drop the explicit `b` from builder call sites

**Status:** IN PROGRESS — design PROVEN against `ae` (Shape A verified §2.5/§5;
dual-mode verified §4). Approved direction (Paul, 2026-08-27): a **fully b-free
node body** via a `build() { … }` wrapper, landed as a **gradual/dual-mode flip
+ full node sweep** — incremental and non-breaking at every step, converging so
that only Shape A remains. NOT a flag-day (dual-mode makes old+new coexist). **Why it matters:**
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

## 4. Rollout shape: GRADUAL flip (dual-mode lib) + FULL node sweep (VERIFIED 2026-08-27)

Earlier drafts feared a flag-day (flip lib → all old `dep(b,…)` break at once).
**That fear was wrong — measured false against `ae`.** A `_ctx`-injected function
accepts BOTH call forms:

```aether
dep(_ctx: ptr, p: string): int { … }     // after the flip
dep("x")           // inside a build(){} block → _ctx injected      ✓
dep(b, "x")        // explicit b passed → _ctx = b                  ✓  (old form)
dep(b, "x")        // top-level, NO enclosing block, explicit b     ✓  (current node form)
```

All three compile and thread the graph (verified: the explicit `b` fills `_ctx`;
the injected form fills it from the pushed block ctx; the block-less top-level
`dep(b,…)` still works because `b` is passed explicitly). So the flip is
**backward-compatible**: old nodes keep building untouched, new Shape-A nodes
work, they coexist indefinitely.

**Chosen approach (Paul, 2026-08-27): gradual flip + complete the job.**
- **Gradual/dual-mode is the safety rail** — flip aeb's lib so BOTH forms
  compile. Nothing ever breaks mid-flight; no pinning, no synchronized cutover.
  A repo that lags still builds against the flipped aeb.
- **But complete the sweep** — still rewrite every one of the ~435 nodes to
  Shape A, so the end-state has **only Shape A left**, no lingering `b`. The
  dual-mode lib means a half-swept repo is never broken, just mixed, en route.

So: incremental and non-breaking at every step, converging on a uniformly
b-free tree. The `dsl_rework` "flag-day" framing is retired.

**Block-less builder calls (former Risk A) — non-issue now.** aeb calls some
builders with `(b)` and NO trailing block — `python.install(b)`,
`rust.check_workspace(b)`. Because explicit-`b` still fills `_ctx` (proven
above), these keep working as-is after the flip. When swept to Shape A they
become `build() { python.install() }` etc. (inside the wrapper block). No
special handling needed; the dual-mode lib covers them at every stage.

## 4.5 Integration map (from the transform/orchestrator/begin scout, 2026-08-27)

The authoritative mechanics the implementation must honor:

- **The `build()` wrapper is a REGULAR trailing-block function, NOT a `builder`.**
  A regular fn pushes its RETURN VALUE onto the ctx stack (what nested `_ctx`
  verbs read); a `builder` would push the config map instead — wrong object.
  Signature: `build(s: ptr, label: string) { … }` returning the graph ctx.
- **The wrapper calls `build.begin(s, label)` internally** (lib/build/module.ae:65)
  — reusing its visited-dedup, the `_session` back-ref (`:81`, what
  `build.fail`/`status_of`/`any_failed` need), and the label-typed `target_dir`
  (`:86-109`). It must reproduce `begin`'s `_null_`/already-visited short-circuit
  (today injected as `if b == 0 { return 0 }` by transform-ae).
- **`s` reaches the wrapper only as the node fn parameter, never via injection**
  (the stack is empty at the node's top level — this is why Shape B fails). So
  the wrapper takes `s` explicitly and transform-ae must thread it in:
  `build() {` (user writes) → `build(s, "<label>") {` (transform emits), exactly
  parallel to today's `build.start()` → `build.begin(s,"label")`.
- **Standalone vs orchestrated duality** (the trip hazard): `build.begin` (has
  `s`, `_session`, `target/<type>/<dir>`) vs `build.start` (env-based, no
  `_session`, `target/build/<dir>`). The wrapper must branch on whether `s` is
  present so a direct `aeb <file>` run still works (status API no-ops without a
  session, which is correct).
- **transform-ae's three rewrites** (tools/transform-ae.ae:253-262): keep the
  `aeb(…)`/`main()` → `<fname>(s: ptr): int` rename; REPLACE the
  `build.start()`→`build.begin` rule with `build() {` → `build(s,"<label>") {`;
  ADD a b-free dep-path-normalization rule (`dep("…/.x.ae")` → `dep("…")`) since
  the current one is anchored on `dep(b, "`.
- **Graph verbs to flip `ctx:`→`_ctx:`** (lib/bldr/module.ae): `dep` (:292,
  ~1034 call sites — the hot one), `dep_artifact` (:1943), `publish_artifact`
  (:1937), `prereq` (:605), `scan` (:650), `pkg_dep` (:337). These are REGULAR
  functions, so injected `_ctx` works. Setters (`env`/`step`/`extra`/…) are
  ALREADY `_ctx` — untouched.

## 4.6 CRITICAL correction: builders use `builder_context()`, NOT injected `_ctx`

Measured against `ae` (2026-08-27): a **`builder`** function does NOT receive an
injected `_ctx` param the way a regular function does. The `builder` keyword's
contract is "the trailing block fills a CONFIG object, pushed as `_builder`" —
the builder's positional first param is NOT auto-filled from the context stack.
`prog() {}` on a `builder prog(_ctx: ptr)` fails with "too few arguments".

The fix: a builder reads the graph ctx via the **`builder_context()` builtin**
(the same primitive the docs describe; aether's own std/clapae uses it). Inside a
`bldr.build() { … }` block a builder gets BOTH, simultaneously and verified:
- `builder_context()` → the graph ctx (deps/artifacts/target_dir), pushed by the
  `bldr.build()` regular-fn wrapper;
- `_builder` → its own config, filled by its setter block.

So the two halves of Shape A use DIFFERENT injection mechanisms:
- **Graph verbs** (`dep`, `dep_artifact`, … — regular fns): injected `_ctx: ptr`.
- **SDK builders** (`c.program`, `rust.foo`, … — `builder` fns): drop the ctx
  param entirely; `ctx = builder_context()` at the top, `if ctx == 0 {return 0}`.

Transform applied to all 147 builders:
`builder foo(ctx: ptr): int { … }` → `builder foo(): int { ctx = builder_context(); if ctx == 0 {return 0} … }`.
This makes the old form `c.program(b) {}` fail (too many args) — correct for the
flag-day; nodes convert to `c.program() {}`. `container.run` (string-returning)
guards `return string.concat("","")`. Value-returning builders in a node/test
pre-declare their capture var before the block (the trailing block is inlined,
so `out = container.run(){…}` inside leaks out). PROVEN end-to-end: a real
`bldr.build() { c.program() { sources(…) output_file(…) } }` node builds and the
binary runs; full aeb suite 124/124.

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
leaves `_ctx` NULL and can't. No aether change needed. **Rollout is gradual, not
a flag-day** — a `_ctx`-injected verb accepts BOTH `dep("x")` (injected) and
`dep(b,"x")` (explicit), verified §4, so flipping aeb's lib breaks nothing; old
and new nodes coexist. Approved plan: flip the lib dual-mode (safety rail), then
sweep every node to Shape A so only Shape A remains — incremental, non-breaking,
complete. Pilot `rust` on a real servirtium-vcr node; servirtium-vcr (114 nodes)
is the primary test-bed. aeb itself has ~no real nodes outside itests/tests.
