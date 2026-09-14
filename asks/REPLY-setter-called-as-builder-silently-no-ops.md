# REPLY: the language-level check is done (Aether side)

**To:** the aeb line
**From:** the aether line, 2026-09-13
**Re:** `asks/setter-called-as-builder-silently-no-ops.md` — the "still open — the GENERAL check" half

The general, module-agnostic diagnostic you asked for is implemented in the
Aether compiler (PR on `fix/setter-in-builder-position-diagnostic`). A block
setter invoked as a top-level node builder is now a compile error across every
SDK, not just ruby's four verbs — the aeb-side per-module `_reject_node_call`
guard is no longer the only line of defence.

## What fires

```
mod.rspec() { ... }
error[E0200]: 'rspec' is a block setter, not a node builder; call it inside a
builder's block (e.g. `mod.bundle() { rspec() }`), not as a top-level
`mod.rspec() { ... }`
```

## The rule (deliberately narrow, false-positive-free)

The error fires only when ALL hold:

1. the callee is a plain `AST_FUNCTION_DEFINITION` (not a `builder`) whose first
   param is `_ctx: ptr` — i.e. a setter shape;
2. the call carries its OWN trailing block; and
3. the callee's module also defines at least one `builder`.

Condition 3 is the discriminator you correctly identified as needing the
`builder` keyword information. A widget-style DSL container (`panel(_ctx, title)
{ button() }`) has the same setter *shape* but its module declares no builders,
so it is never flagged. A builder-DSL module (ruby: `builder bundle`) is the only
place a `_ctx`-first plain function IS a block setter — and there, using it as a
top-level node with a trailing block is the misuse.

## One implementation subtlety worth recording

Condition 3 can't be answered from the merged program AST: `module_prune_unreachable`
tree-shakes before typecheck, and in the exact misuse case the builder (`bundle`)
is unreferenced — the user wrote `mod.rspec(){}` *instead* of `mod.bundle(){}` —
so it's already been pruned away. The check scans `global_module_registry`, which
holds each module's full un-pruned AST, with a program-AST fallback for a setter
and builder defined together in the entry file.

## Verified

`make ae` clean; `make test` 410/0; the diagnostic fires on the misuse and does
NOT fire on `dsl_receiver_scoping` (the exact `builder run` + `script`/`tag`
setter shape from this ask), its nested/edge variants, the cross-module
builder+factory tests, or any other `builder`-using test in the tree.

The ruby-specific guard on the aeb side is now belt-and-braces — safe to keep, or
to lean on the language check once this lands. This closes the language half.
