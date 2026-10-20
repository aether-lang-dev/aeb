# aeb gcheckout: a Lore backend beside the git one

**Status:** IMPLEMENTED in `tools/gcheckout.ae` (backend auto-detected by a
`.lore/` marker; git path unchanged). **Speculative:** Lore is pre-1.0 (its own
README warns on-disk formats and APIs may change between releases), so this is
"designed and verified against lore 0.10.2-nightly, ship when it settles," not a
roadmap commitment.

## What Lore is, and why it fits gcheckout

Lore is Epic Games' open-source version-control system (MIT, Rust), aimed at
"unprecedented scalability of both data and teams... code with large binary
assets" — the exact monorepo-too-big-for-your-disk case the expand/contract
story targets (`../tbd/content/expanding-contracting-monorepos/index.md`). It is
the newest member of the family that article lists (git sparse-checkout /
Perforce client-spec / svn sparse / Plastic cloaked.conf), and the cleanest fit:
a **sparse working tree is Lore's default operating mode**, not a retrofit.

`aeb gcheckout` today walks the `.ae` `dep()` DAG from a target and calls
`git sparse-checkout add <dir>` per visited module dir (`tools/gcheckout.ae`,
`sparse_add`). A Lore backend keeps the *same walker* and swaps the *emit*: the
visited set becomes a Lore **view filter** (`.lore/view`) and we run
`lore sync --view <file>` (or `lore clone --view <file>` at first materialization).

## The CLI contract (observed on lore 0.10.2-nightly, not from docs)

- `lore clone <url> <path> --view <file>` — sparse from first materialization.
- `lore sync --view <file>` — records the view on the instance. The help reads
  "changing which subset of the repository is on disk", but see the constraint
  below: in practice it narrows on *materialization*, not retroactively.
- The view is client-side and per-instance: it never travels with a clone, and
  it is applied on *every* materialization (clone, sync that moves the revision,
  branch switch, restore) — so a stale view silently reshapes a later branch
  switch too.

### Constraint found during implementation: no in-place view-only eviction

The original sketch above implied `lore sync --view` contracts an
already-materialized tree in place. **It does not** (lore 0.10.2-nightly,
verified end-to-end while building the backend):

- A `sync --view` on a working copy *already at* the target revision computes a
  `1 -> 1` delta and touches no files — the newly-narrowed view is recorded but
  out-of-view files already on disk stay. (A same-revision `sync` is a full
  no-op regardless of view; it won't even restore a deleted in-view file.)
- Lore refuses to combine `--view` with its one working-tree sweep:
  `sync --reset --view` errors *"Unable to change the view of a sync that resets
  the working tree"* (`lore-revision/src/revision/sync.rs:282`).
- So the view genuinely only bites on a real materialization: **a fresh
  `lore clone --view <file>` produces the exact narrowed tree** (verified: 4/4
  with the generated view vs 5/5 full), as does a branch switch or a
  revision-moving sync.

Consequence for the backend: `gcheckout add` writes `.lore/view` and records it
via `lore sync --view`, but must **say honestly** that out-of-view files already
on disk are swept on the next materialization, not immediately — and that a
fresh `lore clone --view .lore/view` gives the narrowed tree now. The git
backend contracts in place (`git sparse-checkout`), the Lore backend narrows
going-forward; the tool prints the difference rather than silently under-
delivering. If a future Lore gains an in-place view-eviction op, drop the note.

## The view-file syntax — `.gitignore` polarity, the INVERSE of git sparse-checkout

This is the load-bearing finding, and it was pinned empirically (reading
`lore-revision/src/filter.rs` would have led to a wrong guess). A throwaway repo
with `src/{myteamsapplication,theirapplication,theormwebothdependon}/` + `docs/`,
cloned under assorted views:

| view file body | materialized | rule |
|---|---|---|
| (empty) | all 4 files | **default is include-everything** |
| `/src/theormwebothdependon/**` | that module *absent*, rest present | a bare line is an **EXCLUDE** |
| `!/src/theormwebothdependon/**` | all 4 | `!` **re-includes** (no-op; nothing excluded first) |

So Lore's `.lore/view` is **git-*ignore* semantics**, which is the **opposite
polarity** of git *sparse-checkout*: sparse-checkout lists what to KEEP; a Lore
view lists what to DROP (with `!` to claw back). gcheckout wants "keep only the
walked set," so the Lore backend must exclude-all then re-include each visited
subtree.

### The keep-only recipe (verified: cloned exactly 1/1 files)

```
*
!<dir>
!<dir>/**
```

for each DAG-visited module `<dir>`. Two non-obvious points, both observed:

1. **The exclude-all line must be bare `*`, not `/**`.** `*` (unanchored)
   excluded everything and the re-includes carved the wanted subtree back (1/1).
   An anchored `/**` did NOT fire as exclude-all — those clones kept 3/3. (Likely
   `/**`'s leading-separator anchoring in filter.rs; `*` is "unanchored, reaches
   every path," per the file's own comment.)
2. **Re-include needs BOTH the dir entry and its subtree**: `!src/mod` AND
   `!src/mod/**`. The first keeps the directory on the path; the second keeps its
   files. The parent (`src/`) did *not* need its own `!` line — `!src/mod`
   re-includes along the path.

Union of several modules (the article's "MyTeamsApplication + TheORMweBothDependOn"
case) is just one `!<dir>` / `!<dir>/**` pair per visited dir under the single
`*`.

## Backend shape (Shape A — aeb owns the graph)

Mirror the git path in `tools/gcheckout.ae`:

- git: `sparse_add(dir)` → `git sparse-checkout add <dir>`, called per visited dir.
- lore: accumulate visited dirs into a list, then write `.lore/view` as
  `*\n` followed by `!<dir>\n!<dir>/**\n` per dir, and run `lore sync --view
  .lore/view`. `--reset` writes an empty view (everything) or removes the file.

Backend selection: detect the VCS the same way root discovery already sniffs
markers — a `.lore/` dir (or `lore`-managed working tree) selects the Lore emit,
a `.git` selects the existing `git sparse-checkout` emit. One walker, two emits,
chosen by what the checkout actually is. (Root discovery already honours
`.avn`/`.git`/`.hg`/`.svn`/`.bzr`/Fossil/Pijul — Lore is one more marker.)

## Deliberately NOT used: Lore's native dependency sync

Lore's `lore sync` has its OWN DAG-driven selective sync:
`--root-file <path>` ("only sync changes for these files and their
dependencies"), `--dependency-recursive`, `--dependency-tag`,
`--dependency-depth-limit`. This is gcheckout's idea built into Lore — but on
**Lore's** dependency graph, whatever that tracks, NOT aeb's `.ae` `dep()`
edges. aeb's `dep()` DAG is the single source of truth (the load-bearing
principle); we do not hand Lore our targets as `--root-file` and let it walk,
because it cannot see our edges. The view-filter path keeps aeb's graph
authoritative and uses Lore purely as the sparse-materialization target — the
same role git plays today. If Lore ever grew a way to import an external edge
set, revisit; not before.

## Not asked / out of scope

- **Lore's VFS** (roadmap, in progress 2026): lazy per-file materialization that
  goes past choose-upfront sparse. When it lands, gcheckout's "reshape the view"
  becomes less necessary (files appear on open), but the view emit still scopes
  what the VFS considers in-set. No aeb change needed for it now.
- **Links / layers / partitions** (Lore's multi-repo composition + per-dir
  access control): a different axis (composition, not view) — the git-subtrees
  analog, orthogonal to expand/contract. Not part of this backend.

## Verified

- lore 0.10.2-nightly built from source (nightly Rust — Lore uses the unstable
  `atomic_try_update` std feature, #135894; stable 1.94 rejects it) and run on
  Debian 12 / glibc 2.36. NB: the prebuilt `curl|bash` client needs GLIBC_2.39
  and will NOT run on Crostini/Debian-12 — build from source there. (The prebuilt
  `loreserver` only needs 2.34 and does run.)
- The view-syntax table and the 1/1 keep-only recipe above were each observed
  via `lore clone --view` against a local `loreserver` demo repo, not inferred.
