# Transitive-regen expansion shadows explicit `regen_with` caps → emit=lib cap rejection on aetherc 0.190

**Filed by**: avn port (Claude session, 2026-05-27)
**Severity**: high — breaks clean rebuilds of any binary whose
`--emit=lib` regen needs a capability that (a) isn't a *direct*
`import std.X` of the regen'd module and (b) is only supplied via an
explicit `regen_with(path, caps)`. Surfaced now because **aetherc
0.190 newly *requires* `--with` caps for `--emit=lib`** (older aetherc
didn't, so the missing cap was silently harmless and builds worked
off cached generated.c).
**Component**: `lib/aether/module.ae` — `_expand_transitive_regens`
+ `_detect_caps_from_content` + `_run_regen_pass`.
**Related**: `transitive-regen-expansion.md` (this is its caps
follow-up), `transitive-regen-extern-followup.md`.

## Symptom

A clean `aeb avnserver` (avn project) aborts:

```
Error: --emit=lib rejects 'import std.fs' without --with=fs.
avnserver: aetherc --emit=lib failed for .../client/module.ae
```

…even though `avnserver/.build.ae` explicitly declares:

```
regen_with("../client/module.ae", "fs,os,net")
```

Passing the caps directly works fine, proving aetherc is happy and
the caps are correct:

```
$ aetherc --emit=lib --with=fs,os,net client/module.ae /tmp/c.c   # exit 0, clean
```

So aeb is regenerating `client/module.ae` **without** `--with=fs`.

## Root cause (two interacting gaps)

1. **`_detect_caps_from_content` only sees *direct* `import std.X`.**
   `client/module.ae` does **not** directly `import std.fs` — it
   imports `std.config` / `std.json` / `std.io`, which *transitively*
   pull `std.fs`. aetherc's emit=lib cap-gate checks the full import
   closure and demands `--with=fs`; aeb's heuristic
   (`index_of("import std.fs")` on the file's own text) returns just
   `"os"` (from `import std.os`). So auto-detected caps are
   **insufficient** for any module with a transitive std cap need.

2. **The explicit `regen_with` entry that *would* supply `fs` is
   shadowed by a duplicate transitive entry.** The build declares
   `regen_with("../client/module.ae", "fs,os,net")` — a **relative**
   path. `_expand_transitive_regens` then walks the import graph and
   re-adds `client` as an **absolute** path
   (`/home/.../client/module.ae`) with auto-detected caps (`"os"`),
   because its "already-declared?" dedup compares the absolute import
   path against the existing relative entry as strings — they don't
   match, so it's treated as new. `_run_regen_pass` then processes
   *both*: the explicit one (`fs,os,net` — succeeds) **and** the
   duplicate (`os` — fails on `std.fs`), and the failure aborts the
   build.

Net: even when the author correctly declares caps, the duplicate
auto-entry with weaker caps fails the build.

## Repro

avn @ current, aether 0.190 installed:

```
cd ~/scm/AetherThings/avn
rm -rf ~/.aeb/cache/*            # force regen (toolchain bump also invalidates the cache)
aeb avnserver                    # → "aetherc --emit=lib failed for .../client/module.ae"
```

## Requested fixes (either alone unblocks; both are right)

1. **Normalise paths before the transitive-expansion dedup.** Resolve
   explicit `regen_with` relative paths to absolute (or compare via a
   canonical form) so an already-declared module is recognised and
   **not** re-added with auto-detected caps. Explicit `regen_with`
   caps must always win (the doc comment already claims they do —
   "Already-declared paths — explicit regen_with wins over
   auto-detection" — but the relative/absolute mismatch defeats it).

2. **Make cap auto-detection closure-aware (or union duplicates).**
   Either detect caps over the transitive import closure (so
   `std.config → std.fs` yields `fs`), or — cheaper — when the same
   module appears twice in the regen list, **union** the caps rather
   than processing both independently. A union would also paper over
   gap (1).

The minimal robust fix is (1): dedup correctly and let the explicit
caps stand.

## Impact / workaround

Blocks clean rebuilds of avnserver (and thus the avn project's H1
branch-create debugging, which needs an instrumented avnserver
rebuild). No avn-side workaround that isn't a hack (client doesn't
actually use `std.fs` directly, so adding a spurious
`import std.fs` to force detection would be wrong). The binaries
still *run* off previously-generated `.c` (built before aetherc
started requiring caps); only regeneration is broken.

---

## Resolution (2026-05-27) — fix (1): canonical-path dedup

Applied the recommended minimal fix: dedup by **canonical path** in
`_expand_transitive_regens`, so an explicit `regen_with("../client/module.ae")`
is recognised as the same module the import walk resolves to
`…/client/module.ae` and is **not** re-added with weaker auto-detected
caps. The explicit caps now stand alone.

- New pure helper `_canonical_path` (collapses `.` / `..` / empty
  segments; no filesystem/symlink resolution — it must agree with
  `_resolve_import_ae`'s plain joins). Both sides of the dedup
  (`known` set + each discovered import) are compared canonically.
- Verified: `tests/test_aether_canonical_path.ae` (13 assertions) and a
  real avn-shaped build — the explicit `../client/module.ae` is regen'd
  **once**, no duplicate absolute entry. Suite 67/67 on `ae 0.190.0`.

**Remaining (gap 1, not fixed here):** `_detect_caps_from_content` still
only sees *direct* `import std.X`. A module that needs a cap purely
*transitively* and is **not** explicitly `regen_with`-declared would
still be regen'd with insufficient caps. The fix above makes explicit
`regen_with(path, caps)` authoritative, so the workaround for any such
module is to declare it with `regen_with` (as avn already does for
`client`). Closure-aware cap auto-detection is a larger follow-up.

(Side note: chasing this surfaced a local-env trap — a stale
`AETHER_HOME` pointing at a deleted temp dir silently corrupts cloned
codegen. Not an aeb/aether bug; worth knowing when builds "heisenbug.")
