# aeb-agent: per-slot tree provisioning modes (design)

Status: **DESIGN** (agreed taxonomy; implementation follows). This doc is the
shared artifact for the multi-mode build-tree provisioning system — the thing
that turns `--max-jobs N` from "unsafe with one shared tree" into "N isolated
build trees, each provisioned by a launch-constrained policy."

Companion: [`aeb-agent-operating.md`](aeb-agent-operating.md) (operator how-to),
[`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
(trust model). Builds on the build-slot gate (atomic lock-dirs, `--max-jobs N`)
and lease auth.

## The problem it closes

`--max-jobs N` claims N atomic slots, but **all builds share one `--workdir`/
`--repo`**, and `_prepare_tree` does `git reset --hard && clean -ffdx` *in place*
— so two concurrent builds clobber each other. The fix: **slot `i` builds in its
own tree `<workdir>/<i>`.** N slots → N trees → real concurrency, no clobbering.

But "each slot has its own tree" immediately raises *how that tree is
provisioned and advanced*, and that turns out to be **several distinct modes**,
each of which an operator should be able to **offer or withhold at launch**.

## The decision model (resolves "who picks the mode")

Not a binary. Mirrors lease-purpose coverage and `--allow-image`:

- **The agent, at launch, declares the SET of modes it OFFERS** (fail-closed:
  withheld modes are simply not on the menu).
- **The dispatch REQUESTS a mode** (a `mode` field; absent → the agent's default
  offered mode).
- **The agent's response:**
  - **serve** — mode is offered AND a slot is free → claim slot `i`, provision/
    build in `<workdir>/<i>`.
  - **busy** (503) — mode offered but all slots full.
  - **reject** (403) — mode not offered, or its target (repo/branch) outside the
    agent's allow-list.

So "who picks" dissolves: the agent constrains the menu, the job orders from it.

## The modes

Each is a per-slot **tree lifecycle**. An agent may offer one or several.

### 1. `patch` — pre-cloned, no fetch (developer leasing)
- **Start:** operator pre-clones each `<workdir>/<i>` at a known base.
- **Per job:** `git reset --hard && clean -ffdx` to the pinned base, then
  `git apply <patch>`. **No `git fetch`** — the agent does not advance the tree;
  the *job's patch* is the delta.
- **Source of truth:** the dispatch's `patch_b64` (and optionally `hash` to pick
  the base among what's already local).
- **Use:** "build *this uncommitted delta* against a known-good base." The
  lease/preint case.

### 2. `advance` — pre-cloned, inch forward (CI on a branch)
- **Start:** operator pre-clones.
- **Per job:** `git fetch origin <branch>` + checkout (branch may be
  **launch-constrained** to a fixed branch/allow-list), then optional patch.
- **Source of truth:** the branch HEAD on origin.
- **Use:** CI tracking a branch. Constrainable: `--advance-branches main,release/*`.

### 3. `autoclone` — clone from an allow-list (fresh box / multi-repo CI)
- **Start:** nothing pre-provisioned; the agent clones into `<workdir>/<i>` on
  demand.
- **Per job:** clone (or reuse) a `(repo, branch)` **from a launch allow-list**;
  fetch/checkout within it; optional patch.
- **Source of truth:** approved remotes (`--autoclone-allow <repo>[#<branch>],…`).
- **Use:** a fresh builder serving several approved repos; ephemeral CI.

### 4. `autoclone` + **scrub-after** (ephemeral / untrusted)
- A *modifier* on `autoclone` (`--scrub-after`): after the job ends, **delete the
  cloned tree** so nothing persists between jobs. Slot returns to "no tree."
- **Use:** throwaway or untrusted builds; minimise residue.

## Launch flags (the constraint surface)

```
--provision-modes M[,M…]   modes this agent OFFERS (default: patch). e.g.
                           --provision-modes patch,advance
--advance-branches GLOB[,…]  for `advance`: which branches may be tracked (default: none → advance offered but must name an allowed branch)
--autoclone-allow R[#B][,…]  for `autoclone`: approved <repo>[#<branch>] (fail-closed: empty → autoclone offered but nothing cloneable = effective reject)
--scrub-after                for `autoclone`: delete the per-slot clone after each job
```

All fail-closed: a mode not in `--provision-modes` is rejected; a branch/repo
outside its allow-list is rejected. (Same posture as `--allow-image` /
`--allow-vm-command`.)

`--max-jobs N` still sets the slot count; each slot's tree is `<workdir>/<i>`,
provisioned per the requested (and offered) mode.

## Dispatch wire additions

```jsonc
{ …existing guid/target/purpose/ref/hash/patch_b64…,
  "mode":   "patch" | "advance" | "autoclone",   // requested mode; absent → agent default
  "repo":   "<url>",     // autoclone: which approved repo (must match allow-list)
  "branch": "<name>"     // advance/autoclone: which approved branch
}
```

The agent maps the claimed slot index `i` → `<workdir>/<i>` (and `<repo>/<i>`),
then runs the existing `_prepare_tree`/veto/build against that per-slot tree.

## Decision flow (per dispatch)

```
auth (lease) ── IP gate ── purpose in --accept scope?
  └─ requested mode in --provision-modes?           no → reject
  └─ (advance) branch in --advance-branches?        no → reject
  └─ (autoclone) repo[#branch] in --autoclone-allow? no → reject
  └─ claim a free slot i                            none → busy
       └─ provision <workdir>/<i> per mode (pre-cloned scrub / fetch / clone)
       └─ apply patch (if any) ── veto ── build ── reply
       └─ (scrub-after) delete <workdir>/<i>
       └─ release slot i
```

## What stays the same

- The atomic lock-dir slot gate (just now also names the per-slot dir).
- `_prepare_tree`'s scrub→fetch→checkout→apply — reused, pointed at `<workdir>/<i>`,
  with fetch **skipped** in `patch` mode and **constrained** in `advance`.
- Lease auth, the veto, `--allow-*` gates, `/ping` reporting — unchanged.

## Settled decisions (2026-06-14)

1. **Slot↔tree binding:** is the per-slot dir purely `<workdir>/<i>`, or does the
   *mode* also factor in (e.g. autoclone keyed by repo)? Leaning: `<workdir>/<i>`
   is the slot's tree; autoclone clones the requested repo INTO it (and
   scrub-after empties it), so one slot dir is reused across repos over time.
   **SETTLED: `<workdir>/<i>`, slot owns the dir — no per-repo clone cache
   (that would be unbounded + need eviction).**
2. **Pre-clone discovery:** in `patch`/`advance`, if `<workdir>/<i>` is missing,
   reject (operator must pre-provision) or auto-`git clone` from `--repo` as a
   template? Leaning: reject + a clear startup check that lists missing slot dirs
   (the agent never clones in the pre-cloned modes — that's the operator's job;
   autoclone is the only mode that clones). **SETTLED: reject + list missing at
   startup; the agent NEVER clones in patch/advance — autoclone is the only
   cloning mode.**
3. **Default mode** when a dispatch omits `mode`: the first entry of
   `--provision-modes` (so a single-mode agent "just works" without the job
   naming it).
