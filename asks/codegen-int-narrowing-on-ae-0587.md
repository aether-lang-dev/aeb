# python/dart/gleam/moonbit codegen: int-narrowing error on ae 0.587+

**Found:** 2026-08-27, during the DSL rework whole-itests build on the catchyos
box (ae 0.587). **Orthogonal to the DSL rework** — pre-existing, from commit
`9c0f572` (2026-05-21, "SDK upgrades driven by the Selenium polyglot
conversion").

## The error

`lib/python/module.ae`'s `codegen` builder (and the identical
`_dir_newest_mtime` staleness-check pattern copied into `lib/dart`,
`lib/gleam`, `lib/moonbit`) initializes mtime accumulators as bare `0`:

```aether
newest_in = 0          // inferred 32-bit int
oldest_out = 0
newest = 0
...
if t > newest_in { newest_in = t }   // t is a 64-bit mtime → narrowing
```

On **ae 0.587** (the box; it carries the newer, stricter narrowing check —
this is the same toolchain that has the proposal-3 void-value-read diagnostic)
this is a hard error:

```
error[E0200]: narrowing assignment to 'newest_in': its type was inferred as
32-bit int from its initializer, but a 64-bit value is assigned here and would
truncate. Annotate the declaration (e.g. `long newest_in = ...`).
```

On **ae 0.577** (this chromebook) it does NOT error — so it's a
strictness-regression exposure, latent until the box's newer ae.

## Impact

12 narrowing errors across the codegen nodes (selenium/py codegen, pytorch
aten codegen, etc.), which fail to compile on ae 0.587. Blocks those specific
codegen itests; does NOT affect the DSL rework (verified: 0 b-rework-shaped
errors in the same build).

## Fix

Annotate the accumulators as 64-bit in all four modules'
`_dir_newest_mtime`-adjacent code (python/dart/gleam/moonbit): `long newest_in
= 0`, `long oldest_out = 0`, `long newest = 0`, and any `dir_newest` local.
CANNOT be validated on this chromebook (ae 0.577 doesn't flag it) — must be
built against ae 0.587+ (the box). So this is a box-side fix: annotate, rebuild
aeb on the box, confirm the codegen nodes compile.

## Also seen

One codegen node (`pytorch/aten/src/ATen/.codegen.ae`) hits
`source file exceeds maximum token limit (50000 tokens)` — a separate
generated-node-too-large issue, also pre-existing and orthogonal.
