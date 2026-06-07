# aeb vs. Jenkins (and the Jenkinsfile) — the "aeb *as* CI" future

Status: **future-capability comparison.** This doc is deliberately
different from [`aeb-vs-github-actions-gitlab-buildkite.md`](aeb-vs-github-actions-gitlab-buildkite.md).
That doc draws a hard line — *"aeb decides what to build; CI decides
where, when, and under whose authority it runs"* — and keeps aeb on the
build-graph side, feeding a hosted CI it never replaces. **This doc is
about the road across that line.** Jenkins is the prior art for what aeb
would become *if it ever owned the where/when/authority too* — so the
comparison is to a target shape, not to today's aeb. Where a capability
exists today it's marked **[have]**; where it's design it's **[design]**;
where it's not even planned it's **[no]**.

## Why Jenkins is the right mirror (and GHA/GitLab are not)

GitHub Actions, GitLab CI, and Buildkite are **cloud, runner-rental**
models: you push config, their fleet runs it, you don't own the
controller. aeb-as-CI is the opposite architecture, and it's Jenkins's
architecture:

1. **Self-hosted controller + an owned agent fleet.** Jenkins is a
   long-lived controller dispatching to build agents you operate. aeb is
   already growing exactly this: the sovereign `aeb-agent` (a real binary,
   `tools/aeb-agent.ae`), `agent.dispatch` from an originator, and the
   accept/busy/reject scope decision — see
   [`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
   and [`agent-lifecycle.md`](agent-lifecycle.md). The Bazzite NUC + Mac
   grid this was validated on *is* a Jenkins-shaped agent fleet. **[have]**
   (skeleton).
2. **Pipeline-as-code in the repo.** A Jenkinsfile is a Groovy script in
   the source tree describing the pipeline. aeb's `.build.ae` closure-DSL
   is the same idea — pipeline logic as typed code beside the source,
   greppable, versioned. **[have]** for build/test grammar;
   pipeline-of-stages framing is **[design]**.
3. **Extend by dropping in modules.** Jenkins's power and its curse is the
   plugin ecosystem. aeb's equivalent is the SDK-per-language `lib/<lang>`
   plus consumer-local `.aeb/lib/<name>` (domain SDKs tracked in the
   consumer repo). Same "extensible by adding modules" axis — see the
   "Out-of-repo SDKs" pattern. **[have]**.

GHA-vs-aeb is a *lane* contrast (different jobs). Jenkins-vs-aeb is a
*same-shape* contrast (same job, different era and different spine) — which
is why it's the illuminating one for the as-CI direction.

## The mapping: Jenkins concept → aeb substrate

Almost every load-bearing Jenkins concept already has an aeb counterpart
scattered across the design docs. The as-CI capability is largely
*connecting* these, not inventing them.

| Jenkins | aeb counterpart | Status |
|---|---|---|
| Controller (the long-lived brain) | the originator + control-plane framing in [`containment-and-the-control-plane.md`](containment-and-the-control-plane.md) | [design] |
| Build agent / node | `aeb-agent` (`tools/aeb-agent.ae`) — sovereign, scope-gated | [have] (skeleton) |
| Agent authorization / node→controller trust | fail-closed `--tokens` bearer auth + scope tree (`accept_scope` globs); the real model is policy-class × grant | [have] naive / [design] full |
| Jenkinsfile (`pipeline { stages { … } }`) | `.build.ae` closure-DSL + the DAG of nodes | [have] as build graph / [design] as stage pipeline |
| `stage(...)` / `steps { sh '…' }` | builder verbs (`container.run`, `bash.test`, `webhook.fire`) as graph nodes | [have] (verbs) / [design] (named stages) |
| `input` step (manual approval) | [`aeb-approval-hooks.md`](aeb-approval-hooks.md) — approval evidence/gate | [have]/[design] |
| SCM polling / webhook trigger | [`webhook-triggers.md`](webhook-triggers.md) (outbound today; inbound trigger is the gap) | [have] outbound / [design] inbound |
| `post { always { … } }` (cleanup) | the queryable state machine + always-last `.cleanup.ae` node in [`lifecycle_plan.md`](lifecycle_plan.md) | [have] status machine / [design] cleanup-node |
| Build-step sandbox / Groovy sandbox | the **veto** tiers + container containment in [`veto-alternates.md`](veto-alternates.md) | [have] Tier A / [design] B,C |
| Folder/job permissions | policy-class × grant (`ci` vs `pre-integration`, authority + cache namespace) | [design] |
| Plugins | `lib/<lang>` SDKs + `.aeb/lib/<name>` consumer SDKs | [have] |
| Build history / blue-ocean UI | `[telemetry]` records + artifact manifests; no server-side history store | [have] per-run / [no] durable store |
| Master node executors / labels | agent scope globs + `max_jobs` busy gating | [have] (skeleton) |
| Distributed workspace | the two-aeb duality + rsync-lease idea ([`two-aeb-duality.md`](two-aeb-duality.md), agent lease mode) | [have]/[design] |

The honest read of that table: **the agent fleet, pipeline-as-code, the
approval gate, the cleanup state machine, and the sandbox/veto are all
already designed or skeletoned.** What's missing for "aeb *is* the CI
tool" is the **controller persistence + inbound triggers + a history
store + a permissions model** — the long-lived-server half, not the
build half. That's the precise scope of the future capability.

## What Jenkins got *right* (and aeb should keep)

These are the parts of the Jenkins design that are good and that aeb's
substrate is independently converging on — worth naming so the as-CI work
doesn't reinvent them worse:

- **Self-hosted, you-own-the-metal.** No per-minute runner billing, no
  vendor lock on where builds run. aeb's owned-grid model is this.
- **Pipeline-as-code, in the repo, versioned with the source.** The
  Jenkinsfile's core insight (CI config is code, lives with the code) is
  exactly aeb's `.ae`-as-truth principle.
- **Agent fleet heterogeneity.** Jenkins labels route work to the right
  node (this-OS, this-arch, has-GPU). aeb's scope globs + agent OS
  self-report are the same routing primitive — and aeb's polyglot,
  cross-arch grid (incl. the QEMU/cross-compile tiers) is *more*
  heterogeneous than a typical Jenkins fleet.
- **Extensibility by third parties.** The plugin model let Jenkins cover
  every ecosystem. aeb's SDK + consumer-local-SDK model is the same
  openness with a cleaner boundary (generic-vs-domain).

## What aeb should *not* inherit (Jenkins's 20-year baggage)

This is the load-bearing half of the comparison — the as-CI future is
worth pursuing only if it avoids the specific things that made Jenkins
painful:

1. **The Groovy sandbox as a security boundary.** Jenkins's
   script-security plugin (sandboxing Jenkinsfile Groovy) has been a
   perennial RCE source — sandbox escapes are a recurring CVE class.
   aeb's model is structurally better: the pipeline is **compiled Aether**
   (not interpreted in-process in the controller), and the security
   boundary is **not** "sandbox the pipeline language" but the layered
   **veto (policy) + container/OS containment (enforcement)** split that
   [`veto-alternates.md`](veto-alternates.md) is explicit about —
   *"veto is policy; containment is enforcement — they are different
   layers."* Don't put the trust boundary in the DSL interpreter; keep it
   in the container/process layer, where
   [`containment-and-the-control-plane.md`](containment-and-the-control-plane.md)
   already places it (directional, nestable containment).

2. **Plugin-dependency hell.** Jenkins plugins share one JVM and one
   classpath; a plugin update can break unrelated jobs, and transitive
   plugin deps are a notorious upgrade swamp. aeb's SDKs are **source
   modules resolved per-build** (`--lib`), not a shared mutable plugin
   registry — closer to "vendored, versioned with the repo" than
   "installed into the server." Keep that: as-CI must not grow a
   server-side mutable plugin store.

3. **The stateful controller as an SPOF + upgrade hazard.** Jenkins's
   controller holds job config, history, and credentials as server-side
   mutable state (the `$JENKINS_HOME` blob); losing or corrupting it is
   catastrophic, and config drifts away from the repo. aeb's principle is
   the inverse — **`.ae`-as-truth, state on disk as artifacts/markers.**
   The as-CI controller should stay as close to *stateless-over-a-repo*
   as possible: triggers and history are projections of repo + artifact
   state, not a separate authoritative blob. (The
   [`lifecycle_plan.md`](lifecycle_plan.md) §7 "session vs. disk marker"
   question is exactly this tension, already on the table.)

4. **XML/UI config drift.** Classic Jenkins jobs were configured in the
   web UI and stored as XML — divergent from the repo, un-greppable,
   un-reviewable. aeb's whole identity (the load-bearing principle in
   LLM.md) is the opposite: no out-of-tree config, the dot-`.ae` file is
   the single source of truth. The as-CI feature must not add a
   click-ops job-config surface; a pipeline is a `.ae` file or it isn't a
   pipeline.

5. **Mixed authority on one controller.** Jenkins folder permissions are
   bolted on; a misconfigured job can read another's credentials. aeb has
   a *first-class* answer waiting in
   [`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md):
   **policy class × grant** — `ci`-authority vs `pre-integration` is an
   isolation contract (separate cache namespaces, entitlement to promote
   or enqueue), not a permissions afterthought. Build the as-CI authority
   model on that, not on Jenkins-style ACLs.

## The shape of "aeb as CI", concretely

Putting the substrate together, the future capability is roughly:

```
inbound trigger            controller (originator)         agent fleet
(webhook / SCM / cron)  →  [policy-class decision]      →  aeb-agent (scope-gated)
   [design: inbound]          [design: persistence]          [have: skeleton]
                               authority = ci|pre-int            fetch→checkout→apply
                               (run-policy doc)                  →veto→build (agent-lifecycle)
                                     │                                 │
                                     │  ◀──── verdict + telemetry ─────┘
                                     ▼
                            history = projection of artifacts/markers
                               [no: durable store yet]
                            approval gate (aeb-approval-hooks)  [have/design]
                            cleanup (.cleanup.ae always-last)   [design]
```

Read against Jenkins: the **right column is more mature than the
left**. aeb already has the agent, the scoped dispatch, the build
lifecycle, the veto, the approval evidence, and the cleanup design — the
"agent does the work" half Jenkins also has. What aeb lacks for parity is
the **controller half**: a persistent originator, **inbound** trigger
delivery (webhooks today fire *outbound*), and a durable history store —
and the deliberate choice (per the baggage section) is to make those as
**stateless-over-the-repo** as possible rather than a `$JENKINS_HOME`.

## Rule of thumb (the as-CI counterpart to the GHA doc's)

The GHA doc's rule is: *"aeb decides what to build; CI decides where,
when, and under whose authority."* The as-CI future rewrites the second
clause in aeb's own terms:

> If aeb ever decides *where, when, and under whose authority* too, it
> should look like Jenkins's architecture (self-hosted controller + owned
> agent fleet + pipeline-as-code) and **un-look** like Jenkins's
> implementation (no Groovy-sandbox trust boundary, no server-side plugin
> store, no stateful-controller SPOF, no out-of-tree job config). The
> spine is the **policy-class × grant** authority model and the
> **veto + containment** security split — both already designed — not a
> permissions ACL bolted onto a stateful brain.

## Not asking for this yet

This is a *future-capability* comparison, filed so the design intent
exists before the code. aeb today is on the GHA-doc side of the line: it
emits affected-target sets and telemetry and *feeds* a CI. The as-CI
direction is real (the agent/policy/containment docs are its foundation)
but unscheduled. When it's picked up, this doc is the map of which
Jenkins lessons to take and which to refuse.
