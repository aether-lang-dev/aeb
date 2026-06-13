# aeb vs. Restabuild — and "ci mode": a branch/commit-triggered, aeb-orchestrated build server

Status: **design / direction.** No `--ci` endpoint exists yet; `tools/aeb-agent.ae`
is the substrate this builds on (see [`agent-lifecycle.md`](agent-lifecycle.md)).
Motivated by Restabuild (`~/scm/restabuild`, danielflower / 3redronin), which
HSBC leans on heavily as a no-frills self-hosted build server.

This note: (1) what Restabuild *is*, precisely; (2) how much of it aeb-agent
already is; (3) the gap to "a branch/commit POST triggers a build wholly
orchestrated by aeb"; (4) the concrete shape of an aeb **ci mode** that matches
Restabuild's low-friction trigger model and exceeds its engine.

It sits under the spine from
[`aeb-vs-github-actions-gitlab-buildkite.md`](aeb-vs-github-actions-gitlab-buildkite.md):

> **aeb decides *what* to build. CI decides *where*, *when*, and under *whose
> authority* it runs.**

Restabuild is a *where/when/authority* tool (the CI half). The live question is
the same one [`aeb-vs-snap-ci-and-the-wake-on-commit-flow.md`](aeb-vs-snap-ci-and-the-wake-on-commit-flow.md)
asks of Snap: the **trigger** ("build *this* commit") is a forge/webhook hook —
but can aeb be the **canonical, in-repo grammar** of the flow that trigger kicks
off, served behind a Restabuild-shaped REST face?

## 1. What Restabuild is (the model to match)

A deliberately minimal RESTful build server. The whole contract:

- **Trigger:** `POST /restabuild/api/v1/builds` with form params `gitUrl`,
  `branch` (default `master`), optional `buildParam`. Returns a build `id` +
  `logUrl` / `buildScriptUrl` / `cancelUrl`.
- **Engine:** clone the branch → if a `build.sh` (POSIX) / `build.bat` (Windows)
  sits at the repo root, run it (`bash -x build.sh [buildParam]`) with the
  process env, in the clone dir → stream stdout+stderr (merged) to a log →
  record exit code → `SUCCESS`/`FAILURE`.
- **Observe:** `GET /builds/{id}` (status), `/{id}/log` (the streamed log),
  `/{id}/cancel`, `/{id}/buildScript`; a small build DB, a queue, a process-tree
  killer (for timeout/cancel), a deletion policy, a web UI + curl-friendly API.

The genius is the **contract**: *the repo owns its build via one root script; the
server is a dumb, observable, RESTful runner.* No per-project server-side config
(the Jenkins-freestyle sprawl); the build logic lives **with the code**. That
in-repo locality is *exactly* aeb's own thesis — Restabuild reached it for the
trigger/runner; aeb reaches it for the build graph.

What Restabuild deliberately does NOT do (the headroom): nothing about *what* to
build (it shells one script — no DAG, no affected-target slicing, no caching, no
toolchain awareness), no supply-chain inspection of the code it runs, no
containment, no structured result (just a log blob + an exit code).

## 2. How much of this aeb-agent already is

`tools/aeb-agent.ae` is, today, ~80% of a Restabuild — and richer where it
counts. It is a sovereign HTTP listener (`std.http`; `POST /dispatch`, `/ping`,
`/health`; bearer-token auth) that, per [`agent-lifecycle.md`](agent-lifecycle.md)'s
five stations:

- **fetch → checkout → apply:** clones/fetches a `branch`+`hash`, scrubs the
  worktree to pristine (`reset --hard` + `clean -ffdx` — inter-dispatch
  isolation), optionally `git apply`s a base64 patch (the untrusted delta).
- **veto:** runs the agent's *own* sovereign accept/refuse gate over the `.ae`
  graph + the patch ([`build-veto-and-sandbox.md`](build-veto-and-sandbox.md)) —
  Restabuild has **no** equivalent of inspecting code before running it.
- **build:** runs `aeb <target>` in the prepared tree, pointing
  `AEB_ARTIFACTS_JSON` + `AEB_TELEMETRY_JSON` at per-dispatch temp files and
  tee-ing the log.
- **report:** returns a terse verdict (`done`/`vetoed`/`prep-failed` + pass/fail)
  **plus a structured reply** — the artifacts JSON (what landed in `target/`) and
  a log tail (why it failed). Not just a log blob.

It also carries `--scope`/`--accept` glob matching (which dispatches this agent
will accept) — a routing/authority concept Restabuild lacks entirely.

So the **mapping is close to 1:1**, with aeb strictly ahead on three axes
Restabuild has nothing for: **the veto** (inspect before build), **structured
results** (artifacts, not a blob), and **scope/authority**. And — landed in the
Windows/Axis-2 work — aeb-agent now **compiles, listens, and serves on Windows**
too (a native Windows build agent), and runs in a container on an immutable host
(the compile-in-container/execute-on-host duality,
[`containment-and-the-control-plane.md`](containment-and-the-control-plane.md)).

## 3. The gap to "branch/commit POST → aeb-orchestrated build"

Four things Restabuild has that aeb-agent doesn't yet:

1. **The forge-shaped trigger.** Restabuild's `POST /builds {gitUrl, branch}` is
   what a GitHub/GitLab/Bitbucket webhook (or a thin `git push` hook) fires at
   directly. aeb-agent's `POST /dispatch` is shaped for an *originating aeb*
   (`agent.dispatch`), not a generic git webhook. **ci mode = a webhook-shaped
   front door onto the existing dispatch machinery.**
2. **The repo build convention.** Restabuild = `build.sh` at root. aeb's analog
   is **`.build.ae`** — and it's *better*: a typed, greppable DAG, not a flat
   bash script. ci mode should default to `.build.ae` but **also accept a plain
   `build.sh`** (aeb already has `lib/bash`'s `step()` / `_run_project`) as the
   zero-friction on-ramp — match Restabuild's entry bar, then let teams graduate
   to a real DAG.
3. **Async + a build-id/log/status surface.** aeb-agent is synchronous (the POST
   blocks until the verdict). Restabuild is async: POST returns an `id`, you poll
   `/log` + `/status`, you can `/cancel`. The agent's own docs already name this
   as "the fire-async + webhook-back split" — ci mode is where it lands.
4. **A small persisted build record + UI.** A build DB (id → status/log/result),
   a deletion policy, and the curl-friendly API + minimal UI Restabuild ships.

## 4. The shape of aeb "ci mode"

Grow aeb-agent into it — do **not** rebuild Restabuild. The hard parts
(clone/checkout/veto/build/verdict, cross-platform, Windows + container capable)
are done; ci mode is a thin façade + an async/persistence layer.

```
   git forge / push hook
        │  POST /ci/v1/builds  { gitUrl, branch, commit?, target?=.build.ae }
        ▼
   aeb-agent --ci   (the Restabuild-shaped front door)
        │  → returns { id, logUrl, statusUrl, cancelUrl }   (async, like Restabuild)
        │  → enqueues onto the existing dispatch path:
        ▼
   fetch → checkout(commit) → VETO → build → report     (agent-lifecycle's 5 stations)
        │                              │        └─ structured artifacts JSON + log
        │                              └─ sovereign accept/refuse (Restabuild has none)
        ▼
   GET /ci/v1/builds/{id}        → status + result (pass/fail + artifacts)
   GET /ci/v1/builds/{id}/log    → streamed log
   POST /ci/v1/builds/{id}/cancel
```

Endpoints intentionally mirror Restabuild's verbs (`/builds`, `/{id}`,
`/{id}/log`, `/{id}/cancel`) so a team already POSTing to Restabuild can
**repoint the URL** and keep their webhook — the migration is a base-URL change.

### What ci mode adds *over* Restabuild — the reason to do it at all

The trigger model is the same; the **engine is a different class**. Because the
thing it runs is `aeb`, ci mode composes — for free — with everything aeb already
is, none of which Restabuild can express:

- **DAG, not a script.** `branch → aeb .build.ae` builds the *whole typed
  monorepo graph*, in topo order, with caching — not one opaque `build.sh`.
- **Affected-target slicing.** A commit touches `lib/foo`; aeb (via
  `tools/affected-targets`) rebuilds only the impacted slice of the DAG, not the
  world. Restabuild reruns the whole `build.sh` every time.
- **Supply-chain veto.** The agent inspects the `.ae` graph + the diff and can
  *refuse* before building ([`build-veto-and-sandbox.md`](build-veto-and-sandbox.md)).
  A vetoed build is a distinct verdict, not a failure — Restabuild runs whatever
  you POST.
- **Containment.** `--sandbox` runs the untrusted build under a deny-by-default
  syscall profile; or the compile-in-container/execute-on-host duality on an
  immutable host. Restabuild's only isolation is "it's a separate process."
- **Prerequisite preflight.** `prereq()` / `--preflight`
  ([`build-prerequisites-and-provisioning.md`](build-prerequisites-and-provisioning.md))
  → if the agent lacks a toolchain the commit needs, it returns a distinct
  `unmet-prereqs` verdict (route the build elsewhere), not a confusing build
  error. Restabuild has no concept of "this node can't build this."
- **Scope routing + a fleet.** `--scope`/`--accept` + `ping`-advertised
  capabilities ([`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md))
  → many agents (Linux, **Windows**, container), a build routed to one that can
  serve it. Restabuild is a single box.

> **One line:** Restabuild is *"POST a gitUrl, I run your `build.sh`."* aeb ci
> mode is *"POST a gitUrl+commit, I veto it, contain it, and build the **affected
> slice** of your typed DAG — on Linux, Windows, or in a container — and hand you
> back structured artifacts, not a log blob."* Same RESTful trigger HSBC already
> likes; a much stronger engine behind it.

## 5. Where it sits in the rings ([`directions.md`](directions.md))

ci mode is **Ring C** (distributed / as-CI): an opt-in HTTP-listening server,
heavy, network-facing. It must degrade cleanly — strip the agent and the *same*
`.build.ae` still builds lone-process on a dev box (**Ring A**, the invariant).
The repo's build grammar (`.build.ae`) is identical whether a human runs it or a
ci-mode agent does; ci mode adds *where/when/authority*, never *what*. That
separation is the whole point of the spine — and it is what lets the same build
be a `git push` away from CI without the build logic ever moving server-side.

## 6. The discipline — what ci mode must NOT become

- **Not a pipeline-definition language.** The forge owns the trigger and the
  multi-stage *flow* (Snap/GoCD's "pipeline is first-class"); aeb owns the build
  graph a stage invokes. ci mode is the runner behind a stage, not a replacement
  for the forge's pipeline. (Same line [`aeb-vs-snap-ci-and-the-wake-on-commit-flow.md`](aeb-vs-snap-ci-and-the-wake-on-commit-flow.md)
  draws.)
- **Not server-side build config.** The moment ci mode grows per-project
  settings *on the server*, it has re-become Jenkins-freestyle and lost the
  in-repo-locality that makes both Restabuild and aeb worth using. Everything the
  build needs lives in the repo (`.build.ae` + `prereq()` declarations); the
  server holds only authority (tokens, scope, sandbox grant) — never build logic.
- **Keep the `build.sh` on-ramp honest.** Accepting a plain `build.sh` is the
  migration courtesy, not the destination. It runs the script and reports — it
  does **not** pretend the script is a DAG (no affected-slicing, no per-node
  caching for an opaque script). The richer engine is the reward for adopting
  `.build.ae`; the on-ramp just lowers the first step.

## 7. What to build, in order

1. **`aeb-agent --ci`: the Restabuild-shaped endpoints** (`POST /ci/v1/builds`
   {gitUrl, branch, commit?, target?}, `GET /{id}`, `/{id}/log`, `/{id}/cancel`)
   as a thin façade onto the existing `handle_dispatch` path. *(the front door)*
2. **Async + a build record** — POST returns an id immediately; a small in-memory
   (then on-disk) build DB holds status/log/result; `/log` streams. *(the
   Restabuild parity)*
3. **`build.sh` on-ramp** — when no `.build.ae` but a `build.sh` is at root, run
   it via `lib/bash` and report (no DAG claims). *(low-friction entry)*
4. **Webhook adapters** — map a GitHub/GitLab/Bitbucket webhook payload onto the
   `POST /ci/v1/builds` shape (extract gitUrl/branch/commit), so the forge hook
   points straight at the agent. *(the trigger)*
5. **Compose the rest** (already built, just wire into ci replies): affected-
   target slicing, veto verdict, `--sandbox`, `--preflight` → `unmet-prereqs`
   routing. *(the engine advantages, surfaced)*

## Companion docs

- [`agent-lifecycle.md`](agent-lifecycle.md) — the five stations ci mode reuses.
- [`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
  — dispatch protocol, accept/busy/reject, scope routing across a fleet.
- [`build-veto-and-sandbox.md`](build-veto-and-sandbox.md) — veto + containment.
- [`build-prerequisites-and-provisioning.md`](build-prerequisites-and-provisioning.md)
  — `prereq`/preflight → `unmet-prereqs` routing.
- [`aeb-vs-snap-ci-and-the-wake-on-commit-flow.md`](aeb-vs-snap-ci-and-the-wake-on-commit-flow.md),
  [`aeb-vs-github-actions-gitlab-buildkite.md`](aeb-vs-github-actions-gitlab-buildkite.md),
  [`aeb-vs-jenkins.md`](aeb-vs-jenkins.md) — the "aeb decides *what*; CI decides
  *where/when/authority*" spine.
- [`containment-and-the-control-plane.md`](containment-and-the-control-plane.md) —
  the immutable-host / in-container agent path.
