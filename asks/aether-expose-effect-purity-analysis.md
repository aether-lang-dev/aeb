# Aether: expose the per-function effect / purity analysis externally (for aeb's veto)

**Upstream issue:** https://github.com/aether-lang-org/aether/issues/889

**Filed by:** aeb Claude, 2026-06-26. An enhancement request TO the Aether
maintainer — something aeb would consume, not an aeb-internal task.

**Aether:** the effect system landed in 0.309 (#481 per-function effect tags,
#522 static purity inference + `__pure(fn)`). Confirmed against ae 0.315.

## What aeb does today (and why it's relevant)

aeb ships a supply-chain build veto (`aeb --vet`, `docs/build-veto-and-sandbox.md`)
whose core question is: **does this build-grammar reach `os.system`/`os.exec`,
the network, or a raw `extern` — directly or transitively?** A `.build.ae` is an
Aether program run in the trusted harness; aeb must decide whether to run it.

aeb answers this by HAND-ROLLING capability-reachability:
- Tier-2b: `aetherc --emit=ast` → `lib/veto` `decide()` walks the AST for
  extern/exec/net/banned calls, origin-scoped, fail-closed.
- Tier-C: a doppelganger `std.os` (`lib/veto_trace_os`) that RECORDS
  `os.system`/`os.exec`/`os.run*` instead of executing, to capture intent.

That is, aeb reimplements — approximately, one path at a time — exactly the
whole-program capability/call-graph analysis Aether 0.309 now does precisely.

## The gap

Aether 0.309's analysis is **internal-only**. There is no external surface that
reports a function's inferred effect set:
- `--emit=ast` (the JSON aeb's veto consumes) carries **no** purity/effect
  annotation on function nodes (verified: no `pure`/`effect`/`reaches`/`no_os`
  keys in the emitted AST).
- `--emit=inspect` reports capabilities at **module** granularity ("capabilities
  required (gated imports): os") and lists functions separately — but does NOT
  say WHICH functions reach os/net/fs. aeb's veto needs per-function / per-call-
  path resolution (which is the whole point — "the build's *orchestration* shells
  out, distinguished from the *application* being built").
- `@no_os`/`@no_net`/`@pure` enforce internally (a tagged violator → compile
  error) and `__pure(fn)` folds at compile time, but neither is a query an
  external tool can run over arbitrary code it didn't write.

Crucially, the AUTHOR-WRITTEN tags (`@no_os` etc.) are **not** trustworthy for a
veto — an attacker just omits the tag. What IS trustworthy is the **derived**
analysis (#522's inference from the actual call graph + the `--with=` capability
classification), because it's whole-program and not author-assertable. aeb wants
the *derived* result, exposed.

## What's wanted

Expose the derived per-function effect/capability-reachability analysis so an
external consumer (aeb's veto) can read it WITHOUT re-deriving it. Any one of:

1. **Annotate `--emit=ast` function nodes** with the inferred effect set, e.g.
   `"effects": ["os"]` / `"pure": true` per function declaration. Lowest-friction
   for aeb — it already parses this JSON; the veto would read the annotation
   instead of walking call sites. (Preferred.)
2. **A new `--emit=effects`** (JSON): `{ "<fn>": {"pure": bool, "reaches":
   ["os","net","fs"], "externs": [...] } }` for every function, whole-program.
3. **Per-function rows in `--emit=inspect`** — extend the function listing with
   each function's reached-capability set, not just the module total.

Whichever shape: the contract aeb needs is **derived (not tag-asserted),
whole-program transitive, per-function, fail-closed on unresolved/extern**
(an extern → "unclassifiable / treat as reaches-everything", matching how the
`--with=` gate already treats raw externs).

## Why it helps aeb (and Aether)

- aeb's veto could **lean on the compiler's authoritative analysis** instead of
  its approximate AST walk — less code in `lib/veto`, and a verdict grounded in
  the same reachability the `--with=` gate enforces (no drift between "what aeb
  thinks the build reaches" and "what aetherc knows it reaches").
- It keeps aeb's veto PRINCIPLE intact: the veto still runs in the trusted
  harness and consumes a derived, non-author-assertable fact — a `.build.ae`
  still can't clear a verdict about itself (it can't fake the inference).
- Generally useful beyond aeb: any tool auditing untrusted Aether (a CI gate, a
  package-registry scanner) wants the same external read.

## Acceptance

`aetherc <some-emit-flag> evil.ae` reports, for a function that transitively
calls `os.system` (even via a helper, even in an imported module), that it
reaches `os` — derived from the call graph, NOT from an author `@no_os`/absent
tag. aeb's `lib/veto` can replace its hand-rolled extern/exec/net AST walk with a
read of that output.

## Cross-ref

- aeb: `docs/build-veto-and-sandbox.md`, `lib/veto` `decide()`,
  `lib/veto_trace_os`, `tools/aeb-vet.ae`, `aeb --trace-intent`
- Aether: #481 (effect tags), #522 (purity inference + `__pure`), `--emit=ast`,
  `--emit=inspect`
