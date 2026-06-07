# Lifecycle, teardown policy, and a queryable build state machine — plan

Status: **partially shipped, rest design.** Slice 1 (the in-memory
status machine — `build.fail`/`status_of`/`any_failed`/`reason_of`) and
§9's build-level process-group reap + `--timeout` are **DONE** (see the
per-slice notes below); Slices 3–5 (root_cause enrichment, always-last
`.cleanup.ae` node, crash-safe atexit) and §9's per-step `timeout { … }`
remain design. Captures the discussion behind conditional teardown for
resource-holding steps (the container-lifecycle example) and the larger
idea it points at: a queryable per-target state machine that makes
`finally`-style cleanup unnecessary in a DAG build runner. Companion:
[`nodes-as-subprocesses.md`](nodes-as-subprocesses.md) (the §9 pivot
that shipped).

Related: `container-lifecycle.md` (the motivating example),
`inline-build-steps.md` (inline-Aether steps),
`lib/bash/module.ae` (`pre_command`/`post_command`/`on_failure` — the
existing hook precedent), `lib/build/module.ae`
(`_record_test_result` / `_record_cache` — the proto-state-machine).

---

## 1. The problem

A step that holds a resource — a detached container, a spawned server,
a leased cloud VM, a temp database — must release it. "Bring it up,
exercise it, bring it down." The teardown should be:

- **a choice**, not hardwired: `always` / `never` / `on-success` /
  `on-failure` (keep-the-broken-thing-for-debugging is the high-value
  case), or a user predicate; and
- **conditional on which thing failed and why** — "remove the cache
  container always, but keep the DB container *iff the migration step
  failed*."

The container-lifecycle example currently does up → poke → down in a
single `.up_poke_down.ae` `main()` to get *unconditional* teardown via
plain control flow. That works for the simple case but:

- "unconditional" really means "unconditional *if the step doesn't
  hard-crash*" (there is no `finally`/`defer` in Aether — teardown only
  runs if control reaches it); and
- collapsing to one step throws away the clean up/poke/down separation,
  and can't express "keep on failure, remove on success" as cleanly as
  it should.

## 2. The reframe: cleanup is a *node that queries outcome*, not a `finally`

aeb is not a call stack — it's a **DAG of nodes**. `finally` is a
call-stack construct (cleanup lexically bound to a protected block).
The DAG-native equivalent is:

> A teardown is its own node that `dep`s on the work it guards and
> **queries the recorded outcome** of that work to decide what to do.

This is *more* expressive than `finally`: `finally` only knows
"something threw in my block." A queried state machine knows **which**
target failed, **why** (reason), and — if recorded — the **root
cause**, so teardown can be selective and target-addressable.

It also reconciles the one-step-vs-three-nodes tension: with a
queryable state machine, the **three-node** form (up / poke / down)
becomes correct again — `down` `dep`s on `poke`, asks the session how
`poke` went, and applies policy. No `finally` needed.

## 3. aeb is already ~80% of the way there

The substrate exists; it just isn't exposed for cross-node querying:

- **Shared session.** The orchestrator threads one session `s` through
  every node (`build.session()` → `build.begin(s, …)` →
  `build.done(s, …)`); the visited-map already lives in it. A status
  table lives in the same object — **in-memory, no file I/O**, since
  the whole build runs in one process.
- **Per-target outcomes are already recorded.** `_record_test_result`
  (passed/failed counts), `_record_cache` (hit/miss), and the
  `[telemetry]` block all derive from per-target markers under
  `target/<module>/`. A proto-state-machine — not yet readable by
  *other nodes mid-build*.
- **The orchestrator already runs-all-and-continues.** It does not
  abort on the first failed node (spring-data runs to completion with
  many COMPILE_FAIL / TEST_FAIL and still reports a summary). So "a
  downstream node runs after an upstream one failed" is already the
  model — exactly what cleanup-by-query needs.
- **DAG ordering already sequences teardown last** via `dep()`.

What's missing is **glue, not architecture**: a uniform per-target
status, a failure recorder, and a query API.

## 4. Proposed API surface

### 4.1 Failure record (the unit of state)

Per target, stored in the session:

```
{
  target:      "lifecycle/poke/.build.ae",   // node label
  status:      "passed" | "failed" | "skipped",
  reason:      "curl got HTTP 500",           // proximate, one line, cheap
  failing_cmd: "curl -fsS http://…",          // optional
  exit_code:   22,                            // optional
  root_cause:  <structured, optional>         // opt-in; only when a builder knows
}
```

- **`reason`** is the proximate failure. Every builder can fill it
  cheaply ("javac exited 1").
- **`root_cause`** is opt-in, filled only by a builder that knows the
  deeper why. Precedent: `lib/aether`'s extern-link diagnostic already
  traces an `undefined reference` back to the defining sibling module
  and emits a `regen_with(...)` hint — that *is* root-cause enrichment;
  generalise its output into this field.

### 4.2 Recording

```aether
build.fail(ctx, reason)                 // mark this target failed + reason
build.fail_with(ctx, reason, root_cause)
// …or inferred: a builder that returns non-zero is recorded "failed"
// with a generic reason by the orchestrator.
```

### 4.3 Querying (from any later node)

```aether
s = build.session_handle(b)
build.status_of(s, "lifecycle/poke/.build.ae")  -> "failed"
build.reason_of(s, "lifecycle/poke/.build.ae")   -> "curl got HTTP 500"
build.any_failed(s)                               -> 1
build.failures(s)                                 -> list of records
```

### 4.4 Teardown policy expressed via query

```aether
// down/.build.ae
dep(b, "lifecycle/poke/.build.ae")
s = build.session_handle(b)
poke_failed = string.equals(build.status_of(s, "lifecycle/poke/.build.ae"), "failed")

policy = os.getenv("AEB_TEARDOWN")          // always|never|on-success|on-failure
if string.length(policy) == 0 { policy = "always" }

teardown = 0
if string.equals(policy, "always") == 1 { teardown = 1 }
if string.equals(policy, "on-success") == 1 { if poke_failed == 0 { teardown = 1 } }
if string.equals(policy, "on-failure") == 1 { if poke_failed == 1 { teardown = 1 } }
// "never" -> teardown = 0

if teardown == 1 { remove_container() }
else { println("kept ${name} (policy=${policy}, poke=${...}) — inspect, then: ${eng} rm -f ${name}") }
```

The env var is the per-run debugging override (`AEB_TEARDOWN=on-failure
aeb …`); the script sets the default. The "keep" branch must print how
to clean up manually — a deliberately-leaked resource needs an exit
hint.

## 5. The honest limits (where it is *not* `finally`)

1. **Process death still skips node-level teardown.** The state
   machine handles *graceful* failures (a node returns non-zero or
   calls `build.fail`). A `SIGKILL` / segfault / `Ctrl-C` kills the
   orchestrator and no later node runs. So it replaces `finally` for
   "a step failed," not for "the runner died." True crash-safety needs
   an external reaper (engine `--health-on-failure=stop`, a Ryuk-style
   sidecar) **or** an orchestrator `atexit`/signal handler that runs
   "always-last" nodes even on teardown. The latter is a real runtime
   change, not glue.
2. **Ordering needs a guarantee.** Query-based teardown is only correct
   if it runs after everything it guards. Relying on the author to
   `dep` on every guarded step is fragile. Argues for a small new
   classification — a `.cleanup.ae` / "always-runs-last" node type the
   orchestrator schedules after the main graph (and ideally runs from
   the atexit path in limit 1). This is the one genuinely new
   *scheduling* concept.
3. **"What is failed?" needs a written contract.** Non-zero return =
   failed is clear. Test targets are fuzzier (2/30 failures — failed
   target?). aeb has the counts already; the contract can be "recorded
   failure OR non-zero return," but it must be documented so a query
   means the same thing everywhere.

## 6. Implementation slices

Ordered so each slice is independently useful and the risky bits are
isolated.

- **Slice 1 — in-memory status + query (glue, low risk). DONE.** Added a
  status table to the session: `build.session` now carries a `status` map
  (label → "passed"/"failed"), a `reason` map (label → one-line reason),
  and a `failed` list; `begin()` stashes a `_session` back-ref in each
  node's ctx. Shipped `build.fail(ctx, reason)` (records failed + stores
  the reason + logs it), `build.record_status(s, label, rc)`,
  `build.session_handle(ctx)`, and the queries `build.status_of` /
  `build.any_failed` / `build.failures` / `build.reason_of`. Covered by
  `tests/test_build_status.ae` (18 assertions).

  Note on the reason text: storing the heap-string reason for a later
  `reason_of` read originally hit an **aetherc heap-ownership bug** (the
  stored value was reclaimed and read back as garbage). That bug — the
  map-value-storing-wrapper use-after-free — was **fixed in ae 0.184.0**
  (`heap-string-map-value-use-after-free-multi-tu.md`), so `reason_of`
  now ships in-memory. Slice 3 still moves reason + `root_cause` to
  disk-backed markers, but for crash-survival (§5 limit 1), not because
  in-memory is unsound.

  One part of the original Slice-1 sketch is still **deferred**:

  - **Auto-recording status from a node's return code is not wired.**
    A `.build.ae` `main()` with no explicit `return` is typed *void*;
    the orchestrator's node extern is declared `-> int`, so capturing
    `_rc = node(s)` would read garbage and log spurious failures. Safe
    auto-record needs `transform-ae` to guarantee the renamed node fn
    returns int (inject a trailing `return 0`). Until then nodes record
    failure **explicitly** via `build.fail()`, which is enough for the
    intended consumers (a teardown/notify node checks `status_of` /
    `any_failed`).

- **Slice 2 — make the container demo correct (consumer proof).**
  RECONSIDERED. The container demo is now the single-file
  `.up_poke_down.ae` (one `main()` with guaranteed in-process teardown),
  which the maintainer preferred — so there's no cross-node status to
  query there. Slice 1's status machine instead serves a *different*
  consumer shape: a multi-node pipeline with a trailing notify/report/
  teardown node that asks `any_failed` / `status_of("some/dep")`. Build
  that consumer when one lands, rather than forcing the container demo
  back to three nodes.

- **Slice 3 — `root_cause` enrichment (opt-in depth).**
  Add the structured `root_cause` field; have the `lib/aether`
  extern-link tracer (and one test runner) populate it. Queries surface
  it. Purely additive.

- **Slice 4 — always-last cleanup node classification (scheduling).**
  A `.cleanup.ae` suffix (or a `cleanup()` marker) that the orchestrator
  topo-sorts *after* the rest of the graph, so teardown ordering isn't
  hand-`dep`'d. This is a real scheduling change — design carefully
  against the existing label/tag rules in `tools/aeblabel`.

- **Slice 5 — crash-safe teardown (runtime, deliberate).**
  Orchestrator installs an `atexit`/signal handler that runs the
  always-last cleanup nodes even on abnormal exit. Biggest blast
  radius; only worth it if a leaked-resource-on-crash actually bites.
  Until then, document the external-reaper alternative.

## 7. Open questions

- **Where does status live — session object or `target/<mod>/` marker?**
  In-memory session is faster and matches the one-process model, but a
  file marker survives a crash and lets a *separate* `aeb` invocation
  query the prior run's outcome. Possibly both (write-through).
- **Is `root_cause` free-form text or a typed enum/record?** Typed is
  queryable/actionable; free-form is cheap. Lean typed for the
  failures aeb itself produces, free-form fallback for shell-outs.
- **Does `build.fail` also set the process exit code?** A failed target
  should make `aeb` exit non-zero *after* all nodes (incl. cleanup)
  run — decouple "this target failed" (recorded immediately) from "the
  build failed" (exit code, computed at the end from `any_failed`).
- **Policy vocabulary.** Is `always|never|on-success|on-failure` enough,
  or do we want a predicate/closure (`teardown_when(fn)`)? Start with
  the enum; add a predicate only if a real case needs it.
- **Naming.** `build.fail` vs `build.mark_failed`; `status_of` vs
  `outcome_of`. Settle before the API ships (it's hard to change once
  consumer `.ae` files use it).

## 8. Recommendation

Slices 1–3 are mostly wiring on top of substrate that already exists,
and they immediately make conditional/selective teardown expressible
*and* the three-node container demo correct — without inventing a
call-stack `finally` that doesn't fit a DAG runner. Slices 4–5 (new
scheduling, crash-safe atexit) are genuine design commitments and
should be taken deliberately, only when a concrete need lands, not
bundled into the glue.

## 9. Process isolation & timeouts (Bazel-style)

Adjacent to teardown: keeping a step's *processes* from outliving it.
A step that backgrounds a native server (or leaks any helper) can leave
it running past the step — and a lingering native server has been seen
to poison a sandboxed harness's exit code (root cause filed aether-side:
`../aether/std-http-server-background-sigurg-poisons-harness.md`). The
mature build systems converge on **process-group reaping**: Bazel/Buck
run each action in its own process group and SIGKILL the group on
completion/timeout; Maven/Gradle mostly daemonize into Docker; Cargo
leaves it to the test author (RAII `Drop`, a known footgun).

**Done — build-level reap + `--timeout` (the aeb trampoline).** The whole
build (`aeb-main` → `aeb-link` → orchestrator → anything a step spawned)
runs as one `set -m` job in its own process group; when it finishes the
trampoline group-kills survivors (`TERM` → grace → `KILL`), so nothing
lingers into `aeb`'s own exit. `--timeout N` / `AEB_TIMEOUT=N` caps total
wall-clock (watchdog TERM→KILL; exit 124). This is *invocation-level*:
from a sandbox's view `aeb` is one command, so reaping leaks before
`aeb` exits is what fixes the poisoned exit. Always on (no-op when a
build leaks nothing). The fixture runner (`fixture_server`) also reaps
its declared servers; this catches the *undeclared* leaks too.

**Deferred — true per-step reaping + `timeout { … }` grammar.** Bazel's
finer granularity (each *action* group-reaped on *its own* completion,
per-action timeout) would also give clean mid-build isolation and a
per-target wall-clock. The natural grammar is a closure that carries
both duration and the force-quit reserve:

```aether
c.tests(b) {
    timeout { after(30)  grace_ms(2000) }   // per-step cap + graceful window
    run("svc/.build.ae", "...")
}
```

**Update (this is now UNBLOCKED).** When this section was written the
blocker was architectural: aeb ran every node **in-process** in one
linked orchestrator (sharing the in-memory session map — §1's status
machine), so a node couldn't be preempted mid-`os.system`. That
re-architecture has since **shipped**: `tools/aeb-driver.ae` runs each
node as its own subprocess (`_ae_build_all <root> <label>`), scheduled
via a generated Makefile + `make -jN`, with per-node logs and on-disk
`.rc`/status markers replacing the in-memory session for cross-node
reads. See [`nodes-as-subprocesses.md`](nodes-as-subprocesses.md)
(Slices A–E DONE, incl. per-node parallelism), which was authored
*from* this §9 ask. The original "nodes as subprocesses" prerequisite
listed below is therefore satisfied; the alternative "runtime
process-group hooks in `std.os`" route is no longer needed.

What's left is the per-step *enforcement* on top of that driver — group-
reaping each node's leaked children on **its own** completion and a
per-node watchdog — tracked as Slice F in the nodes-as-subprocesses doc.
The original two routes, kept for the record:

- **nodes as subprocesses** — each node forked into its own process
  group, reaped/timed-out individually. **DONE** (the aeb-driver pivot).
  The shared in-memory session was the apparent cost, but state was
  already disk-backed via artifacts, so it was recoverable as predicted.
- **runtime process-group hooks** — aether-side `setpgid`/`killpg`
  through `std.os`. **Not needed** now that nodes are real subprocesses
  the driver already wraps.

Don't ship `timeout { … }` grammar before Slice F lands — per-step
grammar with only build-level enforcement would be grammar that lies.
Until then, build-level `--timeout` + the reap cover the load-bearing
case (a hung or leaky build never wedges or poisons CI); the per-node
driver makes the finer-grained version a scheduling addition, not a
re-architecture.
