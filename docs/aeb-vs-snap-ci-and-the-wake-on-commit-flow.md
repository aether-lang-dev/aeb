# aeb vs. Snap CI — and "wake on commit": can aeb be the canonical flow grammar?

Snap CI (ThoughtWorks, ~2013–2017) was a hosted CD product built on one
strong idea inherited from Go/GoCD: **the deployment pipeline is the
first-class object, not the isolated build.** Its companion archive
(`~/scm/snap-ae`) preserves the *supporting machinery* — disposable
per-build LXC/Docker isolation (`mini-lxc`, `ruby-lxc`, `chef-container`), a
from-source toolchain "distro" (`ruby-build`, `python-build`, `nodejs-build`,
… published to an S3 bucket), test parallelism (`parallel-tests`), and
deploy/merge glue (`snap-deploy`, `github-services`, `merge_fun`). It got
isolation and toolchain-determinism right years early, but solved them as a
**vendor-operated monolith**.

This note positions aeb against that lineage, then answers the live design
question: the trigger ("wake up and look at *this* commit") is a hook owned
by the forge/CI — but **the flow that trigger kicks off — can aeb be its
canonical, in-repo grammar?**

This builds on [aeb-vs-github-actions-gitlab-buildkite.md](aeb-vs-github-actions-gitlab-buildkite.md),
whose rule of thumb is the spine of everything below:

> **aeb decides *what* to build. CI decides *where*, *when*, and under
> *whose authority* it runs.**

## The one axis that organizes the whole Snap story: *where does it live?*

The Snap assessment's central finding is the **"where does the pipeline
live?"** split:

- **Snap / Jenkins-freestyle / early Go:** pipeline lives **server-side** in
  the service's store. Rich, visual, fan-in/fan-out CD modelling — but the
  definition **does not branch with the code.** Snap auto-*commissioned* a
  pipeline per branch (its genuine "branchable CI" win, 2013) yet that
  pipeline was a server-side clone of master's; a feature branch could not
  carry its *own modified* build as a reviewable diff.
- **Travis → CircleCI → GitLab CI → Actions → Argo/Flux → Dagger:** the
  definition lives **in the repo**, branches with the code, is versioned and
  reviewable. The industry chose this, then spent a decade re-adding Snap/Go's
  richer modelling (matrices, reusable workflows, environments, gates) back on
  top of the in-repo file.

aeb is unambiguously on the **in-repo** side — and was *born* there. The
`.build.ae` DAG is source-canonical, branches with the code, and is a
reviewable diff. **aeb already is what Snap lacked** for the part it covers:
a branchable, in-repo, version-controlled grammar. The question is *which*
part it covers.

## What aeb is vs. what Snap was — the layer split

| Concern | Snap CI (and CD cohort) | aeb |
| --- | --- | --- |
| Trigger (VCS event / cron / "wake on commit") | Owned — the hosted service watches the forge | **Not owned.** A hook/CI delivers the event. |
| What this commit *affects* — the scoped subgraph | Implicit in the server-side pipeline | **Owned, canonically.** `aeb --since <ref>` / `--print-affected`. |
| The build/test DAG itself | Modelled in the UI, server-side | **Owned, in-repo, branchable.** The `.build.ae` graph. |
| Where/when/auth it runs (runners, secrets, approvals) | Owned (vendor compute) | **Not owned.** CI's job. |
| Deploy/promotion stages, value-stream modelling | First-class (the whole point of Snap) | **Out of scope** (today). aeb builds + tests; it is not a deploy pipeline. |
| Toolchain provisioning | Owned (the `*-build` distro, S3 bucket) | **Partial, by a different route** — `prereq()`/provisioning design (see [build-prerequisites-and-provisioning.md](build-prerequisites-and-provisioning.md)): the repo declares toolchain needs, an opt-in agent layers them. Snap's instinct, re-expressed as an in-repo declaration. |
| Merge-safety / merge queue | Embryonic (`merge_fun`, `integrated-branch-build-spec`) | **Adjacent, not owned** — `--since main` gives "what this PR-vs-main touches"; a merge queue (re-test the *merge result*) is CI's to run, fed by aeb's affected-set. |

The pattern: **aeb owns the *graph* and the *affected-subgraph-of-a-commit*;
it does not own the *orchestration* (trigger, runners, auth, deploy
stages).** That is the same boundary the Actions/GitLab/Buildkite doc draws,
applied to Snap's pipeline-first framing.

## "Wake on commit": separating the trigger from the flow

You named the two halves precisely, and they belong on opposite sides of the
boundary:

1. **The trigger — "wake up and look at *this* commit."** A webhook, a forge
   event, a poll, a cron. This is delivery of a `(repo, ref, sha)` fact.
   **aeb does not own this and should not** — it is CI's "Cron/VCS event
   delivery." Whatever wakes the flow (GitHub webhook → Actions, a GitLab
   pipeline trigger, a Buildkite agent picking up a job, a bare `post-receive`
   hook on a server) hands aeb a ref and steps back.

2. **The flow the trigger kicks off.** Given the commit, *something* must
   decide: what changed, what's affected, what to rebuild, in what order,
   which tests to run, what to report. **This is exactly aeb's domain — and
   it is the part Snap held server-side and the part the industry moved
   in-repo.** The canonical expression is:

   ```sh
   # CI woke on a push to <sha>; the flow is then, canonically:
   aeb --since "$BASE_REF" --print-affected     # what this commit touches
   aeb --since "$BASE_REF" --scan '.tests.ae'   # run only impacted tests
   aeb --since "$BASE_REF" --shard "$N/$M"      # fan the impacted set across runners
   ```

   The trigger said *"a commit happened."* aeb answers *"here is the precise,
   minimal, dependency-correct flow that commit implies"* — derived from the
   in-repo DAG, so it is **branchable**: a branch that changes the graph (adds
   a module, re-wires a dep) automatically changes its own affected-set and
   its own flow, as a reviewable diff. That is the property Snap could not
   express because its pipeline lived outside the repo.

## So: can aeb be the *canonical grammar* for that flow?

**Yes, for the part of the flow that is "what this commit implies for the
build graph" — and that is the load-bearing part Snap got wrong.** Precisely:

- **aeb IS the canonical grammar for the *graph the flow traverses* and for
  *the commit→affected-subgraph mapping*.** The `.build.ae` DAG + `--since`/
  `--print-affected`/`--scan`/`--shard` is a complete, in-repo, branchable
  answer to "given this commit, what is the correct build/test flow." A CI
  step that shells out to aeb on every wake-up is consuming that grammar.

- **aeb is NOT the canonical grammar for the flow's *orchestration*** — the
  trigger, the runner allocation, the secret injection, the approval gate, the
  deploy/promotion stages, the long-term history. Those are CI's, and trying
  to absorb them would re-make Snap's mistake in reverse (a build tool
  pretending to be a control plane). The
  [Actions/GitLab/Buildkite doc](aeb-vs-github-actions-gitlab-buildkite.md)'s
  export shape is the seam: `aeb emit ci --provider …` *generates* the
  orchestration file from the graph, but the orchestration still runs in the
  CI system.

The honest one-liner: **the trigger is CI's; the "what does this commit
mean for the build" flow is aeb's, in-repo and branchable; the "where/when/
under-whose-authority" wrapper around that flow is CI's again.** aeb can be
the canonical grammar for the *middle* — and the middle is exactly the
branchable, source-controlled pipeline-fragment Snap proved teams wanted and
could not get from a server-side model.

## A concrete CLI: `aeb --ci <git-url> <commit-hash> <scan-target>`

The one-shot command a trigger hands to a runner — *"here is a commit, give
me the flow result."* Design (not built):

```sh
aeb --ci https://github.com/org/repo abc1234 '.tests.ae'
#  1. clone (or fetch into a workdir cache) the URL
#  2. git checkout abc1234            (the named, fetchable revision)
#  3. run the scan over the target, as if you'd cd'd in:  aeb --scan '.tests.ae'
#  → exit code + telemetry = the flow result the trigger wanted
```

**This is not a new responsibility — it surfaces what `aeb-agent` already
does.** The agent's accepted-build path is already
`git fetch origin <ref> && git checkout <hash>` → vet → build the prepared
tree (`tools/aeb-agent.ae`). `--ci` is that same *fetch-a-named-revision-and-
build* capability exposed as a **direct local CLI** instead of over the
dispatch/lease protocol. aeb already crossed into "fetch a ref" for the
agent; `--ci` just makes it a first-class local command.

Why it still respects the boundary: aeb does the *fetch+checkout+build of a
named revision* (a deterministic, content-addressed operation — the same
class as the agent's, the same class as `gcheckout`'s git interaction). It
does **not** own the *trigger* (what told it `abc1234` happened — a hook),
nor the *runner allocation / secrets / approval / deploy* around the call.
The trigger says "wake on this commit"; `--ci` is the **answer** it invokes;
the runner/auth wrapper is still CI's.

### Trust posture: vet + sandbox ON by default for `--ci`

A `--ci` run fetches a commit you may not have reviewed — that is the whole
point: a trigger fired on *someone's* push. So **`--ci` defaults to
`--vet --sandbox`** (the agent path already vets the prepared tree before
building). The fetched-commit-from-a-URL is **untrusted until cleared**,
matching the agent's pre-integration model:

```sh
aeb --ci <url> <hash> '.tests.ae'          # implicitly --vet --sandbox
aeb --ci --no-vet --no-sandbox <url> <hash> '.tests.ae'   # explicit trusted fast path
```

This is the seam where the three feature tracks compose: `--ci` is the
*entry*, the **veto/sandbox stack** is the *trust gate*, and (once built) the
**prereq()/provisioning** design is what lets the runner have the toolchains
the fetched commit needs. A trigger wakes aeb on a commit; aeb fetches it,
vets it, contains it, checks its prerequisites, and runs the affected flow —
all from one in-repo, branchable grammar, with the trigger and the
runner-authority staying outside.

### Open questions for `--ci`

- **Workdir lifecycle** — a per-invocation temp clone (clean, slow) vs. a
  cached bare mirror fetched-into (fast, reused across triggers). Lean cached
  mirror keyed by URL, `git fetch` + detached checkout per hash.
- **`<scan-target>` is a scan glob or a target path** — reuse the existing
  target/`--scan`/synonym resolution verbatim, so `--ci` adds *fetch+checkout*
  and nothing else to the build semantics.
- **Patch overlay (optional)** — the agent also applies an untrusted `git
  diff` on top of the base; `--ci` could take an optional `--patch <file>` to
  cover the "test this PR's uncommitted delta" case, reusing the agent's
  apply+vet path. Defer unless needed.
- **Auth for private repos** — fetching a private URL needs a credential,
  which is squarely CI's "secrets" column. `--ci` should rely on the ambient
  git credential helper / SSH agent the *runner* provides, and never manage
  secrets itself (that would cross the boundary).

## Where this could go (not built; design-adjacent)

Two seams make aeb a *better* citizen of a wake-on-commit flow without
crossing into CI's territory:

1. **`aeb emit ci --provider <x>`** (already the stated direction): generate
   the provider's trigger+matrix file *from* the DAG, so the in-repo graph is
   the source of truth and the YAML is a derived artifact — closing the
   round-trip gap the Snap assessment found almost no tool solves. The graph
   is canonical; the CI file is generated, branchable because the graph is.

2. **A commit→flow descriptor** — a stable, machine-readable emission of
   "given `--since <ref>`, here is the affected DAG, the shardable test set,
   the artifacts, and the suggested order" (extend the existing
   `--artifacts-json` / `--tests-json` / telemetry surface). That descriptor
   is what a trigger hands to a runner. It is *not* a pipeline server; it is
   the branchable, in-repo **answer** a dumb trigger needs — Snap's pipeline
   intelligence, relocated into the repo where it branches with the code.

## Bottom line

Snap CI was right that delivery wants a real model and reproducible
isolation, and wrong to keep that model server-side where it could not branch
with the code. aeb sits on the side history chose: an in-repo, branchable,
source-canonical grammar — but scoped to **the build/test graph and the
commit→affected-subgraph mapping**, not the orchestration around it. So aeb
*can* be the canonical grammar for the **flow a "wake on commit" trigger kicks
off** — specifically the "what does this commit imply for the build" core —
while the trigger itself, and the runner/secret/approval/deploy wrapper,
stay where they belong: in CI. aeb decides what to build; the hook decides
when to ask; CI decides where and under whose authority the answer runs.
