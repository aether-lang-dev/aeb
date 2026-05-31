# aeb-agent build lifecycle — fetch → checkout → apply → veto → build

Status: **walking skeleton landed; hardening is design.** The happy path of
all five stations exists in `tools/aeb-agent.ae` (`_prepare_tree` +
`handle_dispatch`, commit `67630e0`). This doc names each station, its
current state, and its failure/hardening gaps — so the *wider* goal (a
robust, attacker-resistant prepare-and-build pipeline) has a map, not just
the one station (`maybe_veto_build`) that already has its own doc.

Companion docs — read for the surrounding context, NOT duplicated here:
- [`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
  — the **protocol** (fire-async → terse webhook → sync-pull details),
  the **decision** (accept/busy/reject), policy class × grant, the
  sovereign-peer model. Everything *up to and including* "accept."
- [`veto-alternates.md`](veto-alternates.md) — the **veto** station in
  depth (three tiers) and the **containment** layers (Aether sandbox,
  container) that backstop it.

This doc is the **middle**: what happens on the agent *after* it accepts and
*before* it reports a verdict. The decision doc ends at "accept"; this doc
picks up there and runs to "build."

## Where this sits in the whole flow

```
originator                          agent
----------                          -----
agent.dispatch  ───POST /dispatch──▶ auth-veto (token)         ◀── door gate (policy-class doc)
                                     decision (accept/busy/reject) ◀── (policy-class doc)
                                     │ accept
                                     ▼
                                     ┌─────────── THIS DOC ───────────┐
                                     │ 1. fetch    (git fetch origin) │
                                     │ 2. checkout (git checkout hash)│   _prepare_tree
                                     │ 3. apply    (git apply patch)  │
                                     │ 4. veto     (maybe_veto_build) │   ◀── veto-alternates.md
                                     │ 5. build    (aeb <target>)     │
                                     └────────────────────────────────┘
                ◀──webhook (terse)── verdict  {done, pass|fail}        ── (policy-class doc)
```

Two distinct gates bracket this pipeline, easy to conflate (both say
"veto"): the **auth-veto** at the door (refuse an unauthenticated/over-scoped
dispatch — policy-class doc) and the **build-veto** mid-pipeline (station 4,
having prepared the tree, may policy permit *this build* — veto doc). This
doc's stations 1–3 sit *between* them.

## The stations

Each is a walking-skeleton **happy path** today. The "gaps" column is the
wider-goal work — robustness and attacker-resistance, not new features.

### 1. fetch — `git fetch origin '<ref>'`

Pull the trusted base into the agent's **own** clone. The dispatch carries a
`ref` (optional) and a `hash`; it never names a remote URL — the agent owns
the origin, configured by the operator at clone time. So fetch pulls only
from where the operator pointed it. This is a deliberate trust property: the
requester cannot redirect the agent at an arbitrary remote.

Code: `_prepare_tree`, the `ghash`-gated block. `ref` empty → `git fetch
origin` (all); `ref` set → `git fetch origin '<ref>'`.

**Gaps:**
- No validation that `<ref>` resolves before checkout (a bad ref surfaces
  only as the checkout failing).
- No depth/shallow control — a fetch-all on a large origin is unbounded
  work an attacker could amplify (request many refs).
- No auth path for a private origin (today assumes an open or
  already-credentialed origin).
- A fetch failure returns the flat string `"git fetch failed"` → HTTP 409
  `prep-failed`; the originator can't distinguish "ref doesn't exist" from
  "origin unreachable" from "disk full."

### 2. checkout — `git checkout --quiet '<hash>'`

Move the worktree to the **trusted base** the originator named. `<hash>` is
the integration-line commit the pre-integration delta will be tested *on top
of* — it is trusted (the originator's, not the patch's).

Code: `_prepare_tree`, `co_cmd`.

**Gaps:**
- **No clean/reset first.** The worktree may carry detritus from a *prior*
  dispatch (build outputs, a partially-applied earlier patch, untracked
  files). `git checkout` does not remove untracked files, so dispatch N's
  tree can be poisoned by dispatch N−1. The wider goal wants
  `git reset --hard && git clean -ffdx` (or a fresh worktree per dispatch)
  so each build starts from a known state. **This is the highest-value
  robustness gap in the pipeline** — without it, dispatches are not
  isolated from each other.
- No verification that `<hash>` is an *ancestor of* / *reachable from* the
  fetched ref — a dispatch could name an arbitrary commit the origin
  happens to contain.

### 3. apply — `printf '%s' '<b64>' | base64 -d > /tmp/… && git apply`

Lay the **untrusted pre-integration delta** on top of the trusted base. This
is the one station whose input is adversarial by assumption: the patch is
"a developer's change *before* the integration line" (policy-class doc) — it
has not been reviewed, has not been integrated, and on a leased node is the
thing the operator most needs to be wary of.

The b64 is decoded via shell (Aether does not handle the binary-ish diff) to
a temp file, then `git apply`. Uses `git apply` (not `git am`) — applies to
the worktree, makes no commit.

Code: `_prepare_tree`, the `patch_b64`-gated block.

**Gaps:**
- **No `git apply --check` dry-run** before the real apply. The wider goal
  wants apply to be all-or-nothing with a clean pre-check, distinguishing
  "patch is malformed" from "patch conflicts with the base" from "patch
  applied but dirtied the tree."
- **No scope limit on what the patch may touch.** A patch can modify
  `.git/hooks/*`, `.gitattributes` (filters run arbitrary commands),
  submodule pointers, or files outside the module being built. Stations
  1–3 run *before* the veto, so `git` itself — driven by attacker-supplied
  content — is a pre-veto escape vector. (See "The prepare-before-veto
  ordering" below; this is the load-bearing subtlety.)
- The temp file is `/tmp/aeb-agent-patch-<guid>.diff`, removed after apply.
  Predictable path; on a shared host a symlink-race is conceivable
  (low severity, but it's there).
- No size cap on the decoded patch.

### 4. veto — `maybe_veto_build(repo, target, purpose)`

The agent's own policy gate over the *prepared* tree. Covered fully in
[`veto-alternates.md`](veto-alternates.md) — three tiers (tree scan / SBOM /
doppelganger trace), today a single tier-A stub. Refusal here is a distinct
status (`vetoed`, HTTP 422), **not** a build failure.

Placed here deliberately: it scans the tree *after* the patch is applied, so
tier A can flag "the patch introduced a secret/banned file" — "a hit on the
patch specifically is the highest-signal case."

### 5. build — `aeb '<target>'`

Run the build the dispatch asked for, in the workdir. Today a bare
`os.system("cd '${workdir}' && aeb '${target}'")`; the exit code maps to
`pass`/`fail`.

**Gaps** — these are the *containment* gaps, covered in
[`veto-alternates.md`](veto-alternates.md) § "Veto is policy; containment is
enforcement": the build runs **unsandboxed** on the bare host process. The
documented next step is `spawn_sandboxed(grants, "aeb", target)` (contains
the whole build subtree at the libc boundary), with the container layer
below it. A build that *computes* an escape the veto couldn't read is caught
here, not at station 4.

## The prepare-before-veto ordering — the load-bearing subtlety

The pipeline order is **fetch → checkout → apply → veto**. The veto is
station 4; the three `git`-driving stations run **before** it. This is
correct by design for what the veto *inspects* — tier A scans the prepared
tree, and the highest-signal scan is over the applied patch, which must
therefore already be on disk.

But it has a consequence the wider goal must hold in view: **the prepare
stations are themselves an attack surface that the veto sits downstream
of.** By the time `maybe_veto_build` looks at anything, the agent has already
run `git fetch`, `git checkout`, and `git apply` on attacker-influenced
inputs. `git` is not inert:

- `git checkout` / `git apply` can trigger **hooks** (`.git/hooks/*`),
  **clean/smudge filters** (`.gitattributes`), and (for some operations)
  **submodule** fetches — all of which can run arbitrary commands.
- A patch that touches `.git/*` or installs a hook has *already done so* by
  the time the veto runs.

So there are really two veto-relative positions, and the wider goal needs
both:

1. **Pre-prepare neutralization** (no policy, just hardening) — run the
   `git` stations with the dangerous mechanisms disabled regardless of
   policy: `git -c core.hooksPath=/dev/null`, `--no-recurse-submodules`,
   reject a patch whose diff touches `.git/` or `.gitattributes` *before*
   applying it. These are not vetoes (they don't consult operator policy);
   they are making the prepare stations safe to run on untrusted input *at
   all*. They belong upstream of, or woven into, stations 1–3.
2. **Post-prepare veto** (station 4, policy) — what's already documented.

The clean mental model: **stations 1–3 must be made safe to run on a hostile
input independent of the veto, because the veto runs after them, not before.**
The veto guards "may this build proceed"; it does not and cannot guard "was
it safe to have prepared this tree" — that guarantee has to live in the
prepare stations themselves.

## Failure taxonomy — the agent's verdicts for this pipeline

Each station can short-circuit with a distinct, originator-visible status.
Today's set (and where it's thin):

| Stage | Outcome | HTTP | webhook `status` | Notes |
|---|---|---|---|---|
| auth | bad/no token | 401 | `rejected` | door gate (policy-class doc) |
| decision | out of scope | 403 | `rejected` | |
| decision | no free slot | 503 | `busy` | originator may re-fire |
| prepare (1–3) | fetch/checkout/apply failed | 409 | `prep-failed` | **flat** — does not distinguish *which* station or *why* |
| veto (4) | policy refusal | 422 | `vetoed` | refusal, not failure |
| build (5) | ran, non-zero exit | 200 | `done` + `result:fail` | a real build failure |
| build (5) | ran, zero exit | 200 | `done` + `result:pass` | |

**Gap:** `prep-failed` collapses three stations and many causes into one
code. The wider goal wants the originator to tell "your patch didn't apply"
(actionable by the dev) from "the agent's origin was unreachable"
(actionable by the operator) from "the base hash doesn't exist." The
`details_url` (policy-class doc) is the natural place to carry the granular
reason without fattening the terse callback.

## What to build, in order (the wider-goal roadmap)

Robustness and attacker-resistance of the pipeline, cheapest-first:

1. **Inter-dispatch isolation (station 2).** `git reset --hard &&
   git clean -ffdx` (or a fresh worktree) before checkout, so dispatch N is
   not poisoned by N−1. Highest value: without it the pipeline is not
   repeatable.
2. **Clean apply (station 3).** `git apply --check` dry-run first;
   all-or-nothing; distinguish malformed vs. conflicting.
3. **Pre-prepare neutralization (stations 1–3).** Disable hooks
   (`core.hooksPath=/dev/null`), `--no-recurse-submodules`, reject a patch
   diff touching `.git/`/`.gitattributes` before applying. Makes the
   prepare stations safe on hostile input — the prepare-before-veto fix.
4. **Granular prepare failure taxonomy.** Per-station, per-cause reasons
   carried via `details_url`; keep the terse callback skinny.
5. **Build containment (station 5).** `spawn_sandboxed` + container
   hardening — see `veto-alternates.md`.
6. **Fetch hardening (station 1).** Ref-resolution check, depth bounds,
   private-origin auth — lower priority (the agent owns the origin, so the
   trust property already holds; this is amplification/robustness).

## The one-line summary

`maybe_veto_build` is **one station** in a five-station pipeline
(fetch → checkout → apply → veto → build). The wider goal is the *whole*
pipeline's robustness and attacker-resistance — and its sharpest, least
obvious requirement is that the three `git`-driving prepare stations run
**before** the veto, so they must be made safe on hostile input *in
themselves*, not by a gate that only fires after they've already run.
