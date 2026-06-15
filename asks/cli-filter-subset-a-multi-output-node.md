# `target_filter(name) { … }` — a selector-gated DSL block for subsetting a multi-output descriptor

**Filed by**: aeb Claude, 2026-06-15, after `../aether-ui/.all.ae` (one node, **30
binaries**) surfaced the want, and Paul proposed making the filter a
*first-class DSL block* rather than a runtime env-var gate. Design note —
forward direction, not a request to implement now. **Supersedes** the earlier
`--filter`/`AEB_FILTER` SDK-gate sketch in this file: declaring the subset in the
descriptor is the better layer (no SDK builder needs to change).

## The pain (concrete)

`../aether-ui/.all.ae` is one `.ae` file whose `main()` loops over a static list
of `(source, output)` pairs and calls `build_app(...)` — an `aether.program(b)
{…}` — once per app. **One file → one aeb node → 30 binaries**, built
sequentially. Its header comment names the cost:

> "no per-app caching or `aeb <one-app>` addressing... If per-target caching ever
> bites, split into N tiny `.build.ae`'s."

— and notes the shared 50-line backend block **can't be factored into a helper**
(`_ctx` is auto-injected, not a nameable variable a fn can close over). So the
two options the author saw are: keep the fat descriptor (no addressing), or
explode into 30 near-identical files (massive duplication). `target_filter` is
the third: keep the descriptor, **declare per-target selection boundaries inside
it**.

## The idea (Paul's form)

A `target_filter(name) { … }` block whose body runs **only when a CLI selector
picks `name`** — and `all` (i.e. no selector) makes every block's path true:

```
target_filter("app1") { build_binary("app1") }
target_filter("app2") { build_binary("app2") }
```

```
aeb .all.ae app1        → only app1's block body runs
aeb .all.ae 'svg_*'     → every block whose name globs svg_* runs
aeb .all.ae app1 app2   → both
aeb .all.ae             → no selector ⇒ `all` is true ⇒ every block runs (today's behaviour)
```

## Why this beats the env-var SDK gate (the superseded sketch)

The earlier idea gated *inside* each SDK builder (`builder program`,
`tinygo_lib`, …) by reading `AEB_FILTER` after `out_name` resolves — which makes
every SDK complicit in filtering. `target_filter` gates **before the block body
runs at all**, in pure DSL. **No SDK builder changes.** The descriptor owns its
own subset boundaries — exactly where the knowledge lives. It's the same
config-is-code stance as zsync's `serverdsl` (selection *is* a closure, not a
parsed manifest).

## It fits the existing closure mechanism exactly

A `builder foo(b, ...) {…}` block is already a fn with `_ctx`/`_builder`
injected, whose body runs immediately. `target_filter` is just that, with a guard:

```
// lib/build (or a small lib/target SDK)
builder target_filter(b: ptr, name: string) {
    if _target_selected(name) == 1 {
        // the injected block body executes here — same _ctx/_builder plumbing
        // that aether.driver_test's nested blocks already use.
    }
    // not selected → body skipped: nothing built, no artifact, cheap return.
}

// Selector source: bare CLI tokens after the target, comma/space joined into
// AEB_TARGETS (one flag_spec row, mirrors --scan → AEB_SCAN). Empty ⇒ `all`.
_target_selected(name: string) {
    sel = os.getenv("AEB_TARGETS")
    if string.length(sel) == 0 { return 1 }      // no selector → all true
    return _glob_csv_match(name, sel)            // exact OR glob, comma-set
}
```

Mirrors the existing `_compile_enabled()` / `_execute_enabled()` env-gate idiom
in `lib/build/module.ae` (~491) — same shape, different axis.

## "Both / either" — the block is body-agnostic (Paul's call)

`target_filter` does **not** care what its body is. Two sanctioned usages, author
picks per descriptor:

**(a) Guard inside the loop** — zero duplication, keeps `.all.ae`'s one backend
block. The selector wraps each iteration:

```
main() {
    b = build.start()
    apps = [ ("example_calculator.ae","calculator"), ("example_canvas.ae","canvas"), … ]
    for (src, out) in apps {
        target_filter(out) {            // gate this iteration by output name
            build_app(b, root, os_name, src, out)
        }
    }
}
// aeb .all.ae calculator → only that iteration's body runs.
```

**(b) N explicit standalone blocks** — most readable/greppable; legal because
`target_filter`'s body is itself a closure with its own injected `_ctx`, so it
can directly contain an `aether.program(b){…}` (the factoring `.all.ae`'s comment
said a *helper* couldn't do — a block body can):

```
target_filter("calculator") {
    aether.program(b) { source("example_calculator.ae"); output("calculator"); /* …backend… */ }
}
target_filter("canvas") {
    aether.program(b) { source("example_canvas.ae"); output("canvas"); /* …backend… */ }
}
```

Form (b) re-duplicates the backend per app; form (a) does not. Both are valid —
the verb is the same; document both, recommend (a) for fat fleets like
aether-ui, (b) where each target genuinely differs.

## Match rule (Paul's call): exact-or-glob, comma/space sets

`app1` exact; `svg_*` globs; multiple tokens / commas form a set. Reuses a small
`_glob_csv_match`. Same expressiveness as the `--scan` glob users already know.

## Design questions to settle

1. **Selector plumbing.** Bare tokens after the target (`aeb .all.ae app1 svg_*`)
   → `AEB_TARGETS`. Distinguishing a *selector* from a *second target* (another
   `.ae` path) is easy: selectors are bare words, targets contain `/`, `:` or end
   `.ae`. The CLI already classifies tokens (`tools/aebcli classify_target`).
2. **No-match behaviour.** Build nothing + a clear note (`no target matched
   '<sel>'`), exit 0 — mirrors `--scan`'s empty arm (`tools/aeb-main.ae` ~685).
   Never silent.
3. **`all` as an explicit keyword?** `aeb .all.ae all` could be an explicit
   synonym for "no selector" (nice for scripts/CI that always pass an arg).
   Cheap: treat the literal token `all` as ⇒ select-everything.
4. **Caching.** Orthogonal: filtered build still caches what it *did* build. Form
   (a) doesn't grant cross-run per-app caching (that needs the N-file split), but
   it grants per-app **addressing** — "rebuild just calculator while I iterate" —
   which is the more common want.
5. **`aeb --targets` companion.** To select, you must know the names. Pairs with
   the tree-target lister proposed in `ae-add-implicating-an-aeb-target.md`: a
   `target_filter(name)` block is exactly the thing `--targets` would enumerate
   (its `name` arg is the declared handle), so the lister falls out for free.
6. **Where it lives.** Could be `build.target_filter` (no new import) or a tiny
   `lib/target` SDK (`target.filter`). Recommend `build.target_filter` — it's
   build-graph machinery, not a language toolchain.

## Recommendation

Add `target_filter(b, name) { … }` as a selector-gated block in `lib/build`
(guard mirrors `_compile_enabled`; selector from bare CLI tokens → `AEB_TARGETS`;
exact-or-glob comma-set match), body-agnostic so it wraps either a loop iteration
(zero-dup, recommended for fleets) or a standalone `aether.program`. ~25 lines of
DSL + CLI plumbing, **no SDK builder touched**. Gives `.all.ae`-style fat
descriptors per-target addressing (`aeb .all.ae calculator`) without the 30-file
explosion — and the `name` handles double as what `aeb --targets` would list.

## Cross-ref

- `../aether-ui/.all.ae` (the motivating 30-output node; do NOT edit — sibling
  Claude is active there)
- `lib/build/module.ae` (`_compile_enabled`/`_execute_enabled` ~491, the
  env-gate idiom to mirror; home for `target_filter`)
- `lib/aether/module.ae` (`builder driver_test` ~2200 — nested-closure body
  plumbing `target_filter` reuses; `output(...)` ~25, the declared name)
- `tools/aebcli/module.ae` (`classify_target`, `parse_argv` — selector-vs-target
  token discrimination), `tools/aeb-main.ae` (~685/~754, the `--scan` arm to mirror)
- `ae-add-implicating-an-aeb-target.md` (`aeb --targets` lister these blocks feed)
