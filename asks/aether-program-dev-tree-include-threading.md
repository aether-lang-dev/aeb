# `aether.program` doesn't thread dev-tree Aether runtime includes → `aether_panic.h` not found

**Filed by**: aeb Claude, 2026-06-15, converting `../zsync` to build with aeb.
**Severity**: medium — blocks `aether.program` builds against a **dev-tree**
Aether (a source checkout, not an installed FHS layout). Workaround: build
against an *installed* Aether (which has the nested `include/aether` tree aeb
expects) — that works cleanly.

## Symptom

`aeb cmd/zsync/.build.ae` (an `aether.program` with an `extra_source` C shim),
with `AETHER`/PATH pointed at a dev tree (`/home/paul/scm/aether/build/ae`),
fails at the gcc link:

```
target/build/cmd/zsync/zsync.c:12:10: fatal error: aether_panic.h: No such file or directory
   12 | #include "aether_panic.h"
```

The header exists — at `/home/paul/scm/aether/runtime/actors/aether_panic.h` —
but the gcc command has **no `-I` referencing the dev tree's `runtime/`** at all.

## Root cause

`lib/c/module.ae` `_aether_incs(opts)` (≈line 254) builds the `-I` block via
`build._aether_include_flags(build._resolve_aether_dir(), _opt_str(opts,
"c_aether_home"))`. The 2nd arg (`dev_root`) comes from a per-build option
**`c_aether_home`** — which `aether.program` does NOT set. So `dev_root` is
empty, the dev-tree branch in `_aether_include_flags` (the
`find ${dev}/runtime ${dev}/std -type d` that would `-I` the scattered headers)
never fires, and it falls back to the installed nested-include resolution —
which finds nothing in a dev tree.

Note `tools/aeb-link.ae` (≈line 329) DOES derive a dev_root correctly
(`<aether_dir>/..`, probing `/runtime`) — so the dev-tree detection logic
exists; it's just not threaded into the `aether.program` → `lib/c` link path.

## What's wanted

`aether.program` (and the `lib/c` compile/link it drives) should auto-derive the
dev-tree root the same way `aeb-link` does — `<aether_dir>/..` when
`<that>/runtime` (or `/build/libaether.a`) exists — and pass it as `dev_root` to
`_aether_include_flags`, so the dev tree's `runtime/` + `std/` header dirs get
`-I`'d. No env var should be required; if one is wanted as an override,
`c_aether_home` / `AETHER_INCLUDE` already exist.

## Acceptance

`aeb <aether.program target>` links cleanly against a dev-tree Aether (no
`aether_panic.h` not-found), matching what it already does against an installed
Aether. Proven with `../zsync` `cmd/zsync/.build.ae`.

## Aside (separate, in zsync's notes)

zsync's `LLM.md` said "use the dev-tree `ae`, the installed one lacks MD4
(#637)". That's now STALE — installed Aether 0.256 HAS `md4_hex` (it errored on
arg-count, not missing-fn). So zsync builds fine via aeb against the installed
Aether, which is the clean workaround until this dev-tree threading lands.

## Cross-ref

- `lib/c/module.ae` `_aether_incs` (≈254), `lib/build/module.ae`
  `_aether_include_flags` (≈1063) / `_aether_dev_root` (≈985),
  `tools/aeb-link.ae` dev_root derivation (≈329)
- `../zsync` (`cmd/zsync/.build.ae`, the converted target that hit this)
