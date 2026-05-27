# Design: nodes as subprocesses

**Status:** design + in-progress (slices below). Motivated by three
asks that all converge on the same pivot:

- **Compartmentalized logs** — aeb's own stdout (the `compile: X` /
  telemetry / summary framing) should be separate from each target's
  tool output (javac, junit, jest…), which today interleaves onto aeb's
  stdout. (User ask, 2026-05-27.)
- **Per-step process-group reaping** — kill a node's leaked children
  when *that node* finishes, not just at end-of-build (today's
  build-level reaper). (`lifecycle_plan.md` §9.)
- **Per-step `timeout { … }`** — a per-target wall-clock cap, enforceable
  only if a node can be preempted. (`lifecycle_plan.md` §9.)

All three need the same thing: **each node running as its own child
process** instead of an in-process function call in one linked binary.

## Why it's tractable (the key observation)

aeb already passes *all inter-node data over disk*, not memory. The
generated orchestrator (`tools/gen-orchestrator.ae`) collects every
per-node fact by reading **markers in the node's `target_dir`** *after*
the call:

- artifacts a dependent consumes — `c_objects`, `c_header_dirs`,
  `c_binary`/`program_binary`, `*_generated.c`, jars, `.so`s — are all
  `build._write_artifact` files under `target/<label>/…`, read by
  `build._read_dep_artifact`;
- telemetry — wall time (measured by the orchestrator around the call),
  `_read_cache_outcome`, `_read_test_result`, `_read_test_failures` —
  all read from `target_dir`.

So a node consuming its deps' outputs already works across a process
boundary. The **only** state carried in the in-memory session `s` is:

1. the **visited set** (dedup) — but the topo-sorted driver runs each
   node exactly once, so ordering/dedup is the driver's job, not `s`'s;
2. **telemetry record collection** — already done by the orchestrator
   *around* the node (driver-side), reading disk markers;
3. the **status machine** (`status_of`/`any_failed`/`reason_of`, Slice 1)
   — the one thing that is genuinely in-memory-only today. It moves to
   **disk-backed markers** (`target/.aeb/status/<label>`), which
   `lifecycle_plan.md` §1/§3 already anticipated.

Net: the session shrinks to near-nothing across the boundary; nodes are
already independent.

## The model

One linked binary (as today), but invoked **once per node** with a
selector, by a **driver** that loops in topo order:

```
out_bin <root>                 # all-in-one (today's default; kept)
out_bin <root> --node <label>  # run exactly one node, fresh session
```

The driver (the thing `aeb-link` runs, in place of the all-in-one run):

```
for label in <topo order>:
    log = target/.aeb/logs/<label>.log
    setsid out_bin <root> --node <label> >log 2>&1   # own pgroup
        (optional per-node timeout: watchdog TERM→KILL the group)
    rc = wait
    group-reap survivors of this node             # per-step reaping
    print aeb's OWN framing for <label> to stdout (compile/test + time)
    read telemetry/result markers from target/<label>
    on rc != 0: surface the log (tail or full), record failure
render summary  (driver-side, from collected markers)
```

aeb's stdout = only the driver's framing + summary. Each node's tool
output = its own `target/.aeb/logs/<label>.log`. Clean separation, and
the per-node child gives reaping + timeout for free (the build-level
reaper in `aeb` becomes a backstop).

Driver language: **bash** is the pragmatic choice — it already does the
fd redirection, process groups, and timeout the trampoline reaper uses;
`aeb-link` can emit it the way `gen-orchestrator` emits the orchestrator.
(An Aether driver is possible later.)

## Risk & rollback

This reshapes aeb's core execution, on which every itest and
`google-monorepo-sim` depend. It landed incrementally, proven green at
each step:

- per-node was opt-in (`AEB_PER_NODE=1`) first, validated against the
  sim;
- then per-node became the **default**, with the all-in-one path kept
  permanently as the `--in-process` (`AEB_IN_PROCESS=1`) opt-out — not
  removed: it's the faster path for small builds and the simplest to
  debug. `AEB_PER_NODE` still forces the choice (1 / 0).

## Slices

- **A. `--node <label>` selector (additive, default-unchanged).**
  `gen-orchestrator` wraps each node's call+telemetry in
  `if no-selector OR selector==label { … }`, and only renders the
  summary when no selector is given. `out_bin <root>` behaves exactly as
  today. *No behavior change yet.* ← doing this first.
- **B. Per-node driver, flag-gated.** `aeb-link` emits/ runs a bash
  driver under `AEB_PER_NODE=1`: per-node spawn with log redirection +
  process group; driver renders framing + summary from markers; surfaces
  the failing node's log. Default path unchanged.
- **C. Status machine → disk-backed.** Move `status_of`/`any_failed`/
  `reason_of` to `target/.aeb/status/<label>` so cross-node queries work
  across the process boundary (folds in `lifecycle_plan.md` Slice 3).
- **D. Validate + flip. DONE.** Validated per-node on the sim (identical
  `32 compile + 2 dist + 22 test`, zero tool-noise on stdout, ~⅓ slower),
  then flipped per-node to the **default**; the all-in-one path is kept
  as `aeb --in-process` (the fast/simple mode), not removed.
  *Caveat:* the broad `itests/` set was not re-run under per-node before
  the flip — `--in-process` is the escape hatch if any itest greps aeb
  stdout for tool output.
- **E. (then) per-step `timeout { … }` + per-step reaping** ride on the
  per-node child — `lifecycle_plan.md` §9 grammar becomes enforceable.
