# `#filter` — subset a single build node that emits many artifacts

**Filed by**: aeb Claude, 2026-06-15, after seeing `../aether-ui/.all.ae` build
**30 binaries in one node**. Design note — captures a forward direction, motivated
by a concrete pain, not a request to implement right now.

## The pain (concrete)

`../aether-ui/.all.ae` is a single `.ae` file whose `main()` loops over a static
list of `(source, output)` pairs and calls `build_app(...)` — an
`aether.program(b) {…}` — once per app. **One file → one aeb node → 30
binaries**, built sequentially. Its own header comment names the cost:

> "this is a single node that builds N binaries sequentially, so there's no
> per-app caching or `aeb <one-app>` addressing — but it's the whole fleet in one
> command... If per-target caching ever bites, split into N tiny `.build.ae`'s."

So the author already saw the tension and listed **two** options:
1. Keep the one fat descriptor (what they have) — no addressing, no subsetting.
2. Explode into N `.name.ae` files — addressable + cached, but 30 near-identical
   files duplicating the same 50-line backend block (and the comment explains
   why the block *can't* be factored: `_ctx` is auto-injected, not a nameable
   variable a helper can close over).

There's a **third option neither listed**: keep the one descriptor, but let the
invocation **subset which outputs it produces**. That's `#filter`.

## What `#filter` is

A CLI fragment on the target token that narrows a multi-output node to the
artifacts whose declared `output(...)` name matches a glob — without touching
the descriptor:

```
aeb .all.ae#filter=calculator        # build only the `calculator` binary
aeb .all.ae#filter='svg_*'           # only the SVG-transpiler CLIs
aeb .all.ae#filter='aevg_*,analog_*' # the AeVG fleet + clocks
aeb .all.ae                          # (no fragment) → all 30, as today
```

Read it as: "build this node, but only the slice of it I named." The `#` keeps it
**on the target**, distinct from a global `--flag` — it scopes *that one target*,
which is exactly the Bazel `//pkg:*` / `--test_filter` ergonomic a developer
expects. (We already overload `:` for synonyms and `//` is reserved in the
`pkg-dep` design; `#` is free and reads as "fragment of".)

## Why `--scan` doesn't already cover this

`--scan <glob>` subsets across **files** — it picks which `.*.ae` build files
participate in a tree walk (`tools/aeb-main.ae` ~754, `AEB_SCAN`). It filters by
*basename of the build file*. It cannot reach **inside** one file that emits many
artifacts in a loop. `.all.ae` is one file, one node — `--scan` sees it as
atomic. `#filter` is the intra-node complement: same node, fewer outputs.

| mechanism | granularity | subsets by |
|---|---|---|
| `--scan '<glob>'` | which build *files* run | build-file basename |
| `#filter=<glob>` | which *outputs* of one node build | declared `output(...)` name |

## Where it hooks (small, localized)

Every SDK builder resolves a declared output name before the expensive compile:

- `lib/aether/module.ae` `builder program(ctx)` ~2073-2079 — `out_name` from
  `map.get(_builder, "output")`.
- same pattern in `tinygo_lib` (~2001) and the `shared_lib`/sidecar builders.

The gate is one check, right after `out_name` is known and **before**
`_build_binary` / the gcc link:

```
filter = os.getenv("AEB_FILTER")
if string.length(filter) > 0 {
    if build._glob_match(out_name, filter) == 0 {
        return 0            // declared but skipped — no compile, no artifact churn
    }
}
```

Because the loop in `main()` calls the builder once per app and each call
re-reads the gate, a non-matching app is a cheap early `return 0`. Matching apps
build exactly as today. No descriptor change, no new SDK verb — purely a
runtime narrowing.

Plumbing: add `--filter <glob>` (or parse the `#filter=` fragment off the target
token in `tools/aebcli` `classify_target`/`parse_argv`) → `AEB_FILTER`, same
shape as `--scan → AEB_SCAN`. A small comma-split lets `#filter='a,b'` mean a set.

## Design questions to settle

1. **Fragment syntax vs flag.** `.all.ae#filter=glob` (on-target, scopes one
   target) vs `--filter glob` (global, applies to whatever's building). The
   fragment is more precise when multiple targets are on the line; the flag is
   simpler to plumb (reuses the `flag_spec` table wholesale). **Recommend:
   ship the `--filter` flag first** (trivial, reuses `--scan`'s machinery), add
   the `#`-fragment parse as sugar later if multi-target lines want it.
2. **Match against output name or source?** Output name (`calculator`) reads
   best for `.all.ae`. Could also allow matching the source path. Keep it to
   `output(...)` for v1 — that's the user-facing handle.
3. **`--filter` with no match.** Build nothing + a clear note
   (`no output matched '<glob>'`), exit 0 — mirrors `--scan`'s empty-glob arm
   (`tools/aeb-main.ae` ~685). Never silent.
4. **Interaction with caching.** Orthogonal: a filtered build still caches the
   outputs it *did* build; it just doesn't visit the others. (Doesn't *give*
   `.all.ae` per-app caching across runs — that needs the N-file split — but it
   does give per-app **addressing**, which is the more common want: "rebuild just
   calculator while I iterate.")
5. **`--list`/`--targets` companion.** To filter, you must know the names — pairs
   naturally with the `aeb --targets` lister proposed in
   `ae-add-implicating-an-aeb-target.md` (list a tree's declared outputs).

## Recommendation

Add a `--filter <glob>` flag (→ `AEB_FILTER`, one row in `flag_spec`, comma-split
for sets) and a single `_glob_match` gate in each SDK builder right after
`out_name` resolves. ~15 lines of plumbing + one gate per builder. It gives
`.all.ae`-style fat descriptors **per-output addressing** (`aeb .all.ae --filter
calculator`) without forcing the 30-file explosion the author was avoiding —
the third option that was missing. The `#filter=` on-target fragment is a later
sugar once the flag proves out.

## Cross-ref

- `../aether-ui/.all.ae` (the motivating 30-output node; do NOT edit — sibling
  Claude is actively working there)
- `tools/aebcli/module.ae` (`classify_target`, `parse_argv`, `flag_spec` — where
  `--filter`/`#filter` parses), `tools/aeb-main.ae` (~754, the `AEB_SCAN` arm to
  mirror), `lib/aether/module.ae` (`builder program` ~2073, the gate site)
- `ae-add-implicating-an-aeb-target.md` (the `aeb --targets` lister this pairs with)
