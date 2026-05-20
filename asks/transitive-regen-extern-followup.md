# aeb's regen pass should also follow project-local extern references

**Filed by**: avn port (Claude session, 2026-05-20)
**Date**: 2026-05-20 (post-`0dc7f1e`)
**Severity**: medium — strictly less than the import variant
(`transitive-regen-expansion.md`) since externs are a smaller
fraction of the cross-module surface; but the diagnostic is the
same opaque gcc "undefined reference" and the workaround is the
same hand-enumeration.
**Cross-ref**: follow-up to
[`transitive-regen-expansion.md`](transitive-regen-expansion.md)
(fix landed in `0dc7f1e`, "lib/aether: auto-expand transitive
project-local regen entries"). That fix walks `import` lines; this
filing covers the still-broken **extern** case.

## Symptom (still reproducible after 0dc7f1e)

In `~/scm/AetherThings/avn`, the unit test
`util/test_text_merge.ae` does:

```aether
import std.string
import repo_storage
```

`repo_storage/module.ae` does **not** `import repos` — repo_storage
uses repos via `extern` declarations at the top of the file:

```aether
extern repo_primary_hash(repo: string) -> string
extern repo_secondary_hashes_joined(repo: string) -> string
extern repos_head_rev(repo: string) -> int
extern repos_inherit_rev_field(repo: string, rev: int, field: string, fallback: string) -> string
extern repos_rev_blob_sha(repo: string, rev: int) -> string
extern repos_rev_field(repo: string, rev: int, field: string) -> string
```

With `util/.tests-text_merge.ae` carrying only the obvious
import-chain entry:

```aether
regen_with("../repo_storage/module.ae", "fs,os")
// (no regen_with for repos/, since util doesn't import it
//  and repo_storage doesn't import it either)
```

`aeb util/.tests-text_merge.ae` runs aetherc clean and then gcc
fails:

```
/usr/bin/ld: module_generated.c:(.text+0x532a): undefined reference to `repos_rev_blob_sha'
/usr/bin/ld: module_generated.c:(.text+0x9953): undefined reference to `repo_primary_hash'
/usr/bin/ld: module_generated.c:(.text+0x9a45): undefined reference to `repo_secondary_hashes_joined'
/usr/bin/ld: module_generated.c:(.text+0xbb9d): undefined reference to `repos_head_rev'
... (10 such)
collect2: error: ld returned 1 exit status
test:util:text_merge: gcc link failed
```

Adding `regen_with("../repos/module.ae", "fs,net,os")` to the
test's `.build.ae` clears it. Pinned at commit `e480879` in avn —
the `util/.tests-text_merge.ae` build wrapper carries the manual
entry with an inline comment explaining the gap.

## Diagnosis

`_expand_transitive_regens` (post-`0dc7f1e`) walks
`import <X>` lines for each module in the regen worklist. It
doesn't walk `extern <symbol>` declarations — and indeed the
upstream commit message frames the fix as "transitive
project-local **imports**." `repo_storage`'s `extern repos_*`
decls escape the walk; `repos/module_generated.c` never lands
on the gcc command line; link fails.

## Why externs vs imports matters

In Aether the two are semantically distinct: an `import`
declares a typed name dependency the typechecker resolves
through the module graph; an `extern` is an unchecked link-time
symbol reference into something the runtime is expected to
provide. For SDK-level externs (`extern malloc`, `extern
list_new`, `extern os_getpid_raw`) the runtime libraries
(`libaether.a` / contrib libs) provide the bodies — no
project-local regen needed. But repo_storage's `extern repos_*`
decls **point at project-local sibling modules** — `repos`
provides `repos_rev_blob_sha` etc. in its generated C. So the
extern is the moral equivalent of an import for link purposes,
but the walk treats them as opaque external symbols.

Project convention in avn has been "externs are how repo_storage
calls into repos without taking on a typed import dependency
(which would otherwise be circular)." That's a real reason to
keep the import out — but it shouldn't cost a `regen_with` line
in every consumer's `.build.ae`.

## Three possible fixes

### Option A — extern-walking pass (mirrors the import-walk)

In `_expand_transitive_regens`, after walking imports, also walk
each module's top-level `extern <name>(...)` declarations:

1. For each `extern <name>(...)` in a worklist module, search the
   project tree's `module_generated.c` files for the symbol
   `<name>` (or `<sibling>_<name>` if a per-module prefix is
   in play).
2. If found in `<sibling>/module_generated.c`, queue
   `<sibling>/module.ae` for regen and link.
3. Inherit caps the same way the import walker does — either
   from the parent's caps or auto-detected from the sibling's
   own imports.

Catch: this requires either parsing the regex of extern decls
(`extern <name>(<args>) -> <ret>`) or asking aetherc for the
extern list as a build artefact. Regex parse is simple but
fragile; an aetherc-emitted `module.aeextern` sidecar would be
cleaner.

### Option B — symbol-table reverse lookup at link-fail time

Cheaper and pleasingly diagnostic-only: when gcc fails with
`undefined reference to <sym>`, aeb scans
`<project>/**/module_generated.c` for `<sym>` and, if a sibling
module defines it, prints:

```
hint: gcc linker missing repos_rev_blob_sha — defined in
      <project>/repos/module_generated.c. Add
      regen_with("../repos/module.ae", "<caps>") to .build.ae.
```

The "optional follow-up" at the end of
`transitive-regen-expansion.md` proposes the same shape. This
version doesn't auto-fix but at least drops the diagnostic onto
the porter's lap. Cheap to implement and lossless — even if the
extern-walking pass eventually lands, the diagnostic still helps
for non-Aether C externs that aren't expressible as `regen_with`.

### Option C — emit a `.aeextern` sidecar from aetherc and have aeb consume it

Slightly more invasive but the cleanest: aetherc emits
`<module>/module.aeextern` listing every project-local extern
that resolves to a sibling module (i.e. `<sibling>` is in the
same project root and its `module_generated.c` defines
`<symbol>`). aeb's regen expander reads the sidecar and queues
the siblings. This needs aetherc cooperation but produces zero
false positives.

## Workaround until any of the above lands

`.build.ae` files for consumers of `repo_storage` (or other
extern-heavy sibling modules) keep enumerating the
extern-referenced siblings by hand. Pattern pinned in avn at:

- `util/.tests-text_merge.ae` (MB-I i.1, commit `e480879`)
- `util/.tests-merge_ledger.ae` (Phase 1.1, earlier round) —
  same `regen_with("../repos/module.ae", "fs,net,os")` line.

Both files carry an inline comment explaining why the manual
entry is there; if Option A or C lands, those comments come out.

## Why I'd advocate Option B first

The import-walking fix (`0dc7f1e`) closed the worst class —
porters who add a new test driver in a module with project-local
imports no longer hit it. Option A/C are larger changes that
need design choices (parser format, sidecar shape, caps
inheritance for externs). Option B is a single-shot
post-mortem hint that catches *any* form of this class — extern
references today, plus future shapes (e.g., link-only contrib
modules, hand-rolled C externs the porter didn't realise come
from a sibling). Land Option B first; pick A or C later when
the shape settles.

## Cross-references

- `~/scm/AetherThings/aeb/asks/transitive-regen-expansion.md` —
  the original import-side ask, fix landed.
- `~/scm/AetherThings/avn/util/.tests-text_merge.ae` — the manual
  `regen_with` line + inline comment marking the gap.
- `~/scm/AetherThings/avn/util/.tests-merge_ledger.ae` — same
  pattern, earlier round; an earlier siling-Claude session.
- `~/scm/AetherThings/avn/repo_storage/module.ae` lines 50–55
  — the six `extern repos_*` decls that drove the manual
  `regen_with` entry.
