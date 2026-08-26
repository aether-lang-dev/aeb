# aeb DSL rework — drop the explicit `b` from builder call sites

**Status:** PLAN (no code yet). **Why it matters:** the explicit build handle
`b` threaded into every SDK builder — `rust.cargo_test_existing(b) { … }` — is
aeb's most visible divergence from idiomatic Aether DSLs. Aether itself
(std/, contrib/) and aether-ui write `button("OK") { … }` with **no** threaded
object; the parent context is injected invisibly. aeb's boilerplate `b` is a
paper-cut on every node in every downstream repo, and the pitch here is
explicitly **"nicer than Bazel to read and write"** — so the ergonomics are not
cosmetic, they're the product. This plan makes `b` optional and migrates
toward its absence.

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

**`ctx` vs `_ctx` is the only thing gating injection.** No grammar change is
required to remove `b`; it's an aeb SDK convention, reversible on the aeb side.

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

## 3. The design: make `b` OPTIONAL, not removed (no flag-day)

The doc guarantees a `_ctx`-injected function *can still be called explicitly
with a context value outside a trailing block*. That is the seam. Target end
state — **both forms compile forever**:

```aether
rust.cargo_test_existing(b) { env(…) }   // OLD — keeps working, unchanged
rust.cargo_test_existing()  { env(…) }   // NEW — b injected, no boilerplate
```

Mechanism per builder:

1. Change `builder foo(ctx: ptr)` → `builder foo(_ctx: ptr)`.
2. Inside, resolve the graph handle with a fallback:
   `gctx = _ctx`  (injected inside a block; or the explicit arg when passed).
   The single rule: **use the injected context if present, else the explicitly
   passed one.** Confirm the exact `builder_context()` fallback idiom in the
   spike (§5) — it may be that `_ctx` already resolves to the injected value
   inside a block and to the passed value outside, in which case no body change
   is needed beyond the rename.
3. `dep` / `dep_artifact` / `publish_artifact`: give them injected-context
   fallback too, so `build.dep("core/.build.ae")` (no `b`) works inside the
   `aeb(cap)` body. **This is the harder half** — those are called in the node
   body, *not* inside a builder trailing block, so there's no pushed context
   unless `build.start()` itself pushes one. See §4 risk.

Old code never breaks → **migrate downstream lazily, repo by repo, or never.**
No synchronized cutover.

---

## 4. The pivotal unknown + the real risk

**Unknown (blocks the whole plan until answered):** can a `_ctx`-injected
builder *also* be called explicitly with `b` **when a trailing block is
present** — `foo(b) { … }` — without an arity error? The injected `_ctx` is
normally hidden from arity; passing it explicitly *and* having a block may or
may not be legal. If illegal, dual-mode needs an aether-side tweak first, and
this becomes an aether ask, not a pure-aeb change. **Resolve via §5 spike before
touching any SDK.**

**Risk A — no-block builder calls.** Measured: aeb calls builders as `(b)` with
**no trailing block** all over — `rust.cargo_project_existing(b)`,
`python.install(b)`, `rust.check_workspace(b)`, `rust.test_workspace(b)`.
Injection only fires *inside* a trailing block, so these have nowhere to inject
from. They MUST keep working via the explicit-pass path (they already pass `b`).
So: the explicit form is not merely legacy — it's **required** for block-less
builder invocations and stays first-class forever. The win is only at the
*has-a-block* call sites (~349 of them). That's fine, but the plan must not
promise `b`-free everywhere.

**Risk B — `dep`/`dep_artifact` in the node body.** These run in `aeb(cap)`'s
top level, not in a builder block. For them to lose `b`, `build.start()` (or the
`aeb(cap)` entry) would need to push itself onto the context stack so
`builder_context()` returns it in the plain body. That's a deeper change (does
the `aeb` entrypoint establish an ambient context?) and may not be worth it —
`build.dep(b, …)` is arguably *fine* keeping `b`, since it reads as "this node
depends on…". **Recommendation: scope v1 to BUILDERS ONLY.** Leave `dep`/
`dep_artifact` explicit. That already kills the ugliest boilerplate
(`mod.foo(b) {`) and dodges Risk B entirely.

**Non-goal:** removing `b = build.start()` itself. The node still names its
build; that line stays.

---

## 5. Spike (do FIRST, ~30 min, throwaway, no aeb changes)

Write a tiny `.ae` compiled against local `ae`:

```aether
import std.map
builder foo(_ctx: ptr) {
    // does _ctx bind to the injected ctx in a block, and to the passed arg outside?
    println("ctx null? …")
}
set_x(_ctx: ptr, v: string) { map.put(_ctx, "x", v) }

main() {
    b = map.new()
    foo(b) { set_x("1") }   // (Q1) explicit b + block — arity ok? _ctx = which?
    foo()  { set_x("2") }   // (Q2) injected only
    foo(b)                  // (Q3) explicit, no block — the Risk-A case
}
```

Decision gate:
- **Q1 compiles & `_ctx` sees the block config** → dual-mode works, plan is
  pure-aeb, proceed to §6.
- **Q1 errors** → file an aether ask for "explicit-pass a `_ctx` param when a
  block is present"; plan blocks on that. Capture the exact error.

---

## 6. Rollout (only after the spike says GREEN)

1. **Pilot one SDK** end-to-end in aeb: `rust` (smallest real surface — 6
   builders, and servirtium-vcr + selenium exercise it). Rename `ctx`→`_ctx`,
   add fallback, keep explicit path. Prove both forms in `tests/`.
2. **aeb self-migration** as the reference: flip aeb's own ~60 nodes to the
   `b`-free block form where a block exists; leave block-less `(b)` calls.
   Full suite must stay 123/123.
3. **Sweep the rest of aeb's 41 lib modules**, one commit per SDK family
   (jvm group, native group, scripting group…), each with a test asserting
   BOTH call forms compile.
4. **Downstream: opt-in, unsynced.** Announce in each repo's asks channel that
   the `b`-free block form is available; siblings drop `b` when they touch a
   node. Old form never breaks, so there is no deadline and no coordinated
   release. A codemod (`sed`-level: `\.(\w+)\(b\)\s*\{` → `.\1() {`) can do a
   repo in one pass when a sibling wants it — offer it, don't impose it.

**Ordering rule:** never migrate a downstream repo before the aeb SDK it uses
ships dual-mode — otherwise the `b`-free form won't compile there yet.

---

## 7. Open questions for Paul

- **v1 scope:** builders-only (my recommendation, §4 Risk B), or also chase
  `dep`/`dep_artifact` `b`-free (needs the ambient-context-in-body change)?
- **Codemod vs hand-edit** for aeb's own 60 nodes — I lean codemod + eyeball.
- Do we want a **deprecation** on the explicit-with-block form eventually, or
  keep it permanently (it's *required* for block-less calls anyway, so a full
  deprecation is impossible — the explicit path is load-bearing forever)?

---

## TL;DR

Worth doing — it's a headline ergonomics win over Bazel, which is the point.
It's a **gradual, backward-compatible** change (make `b` optional via `_ctx`
injection with explicit fallback), **not** a flag-day — *if* the aether spike in
§5 confirms explicit-pass-with-block is legal. Scope v1 to builders-with-blocks
(the ~349 ugly call sites), leave `dep`/`dep_artifact` and block-less calls on
the explicit path (they're load-bearing). Pilot `rust`, self-host in aeb, then
let 14 downstream repos adopt at their own pace with an offered codemod.
