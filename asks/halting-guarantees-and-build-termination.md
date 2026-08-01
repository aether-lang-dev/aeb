# Halting guarantees: should aeb's config language be non-Turing-complete?

**Filed by**: Paul + LLM session, 2026-07-25, prompted by a comment
thread on "What makes a good build system?" (r/programming, 2026-07-24):
https://www.reddit.com/r/programming/comments/1v5ip78/what_makes_a_good_build_system/
**Status**: **DECLINED** (the language-level ask). The termination
property it wants is already delivered by other means, verified below.
One genuine gap it surfaced — per-node timeouts — is recorded as a
separate, open item.

## The ask

u/lookmeat, in the thread that also produced `.presubmit.ae` (see
`docs/presubmit-target-sets.md`):

> When I say "Totally Functional" I don't mean "functional like LISP" I
> mean "a subset of functionality that is **not Turing Complete** and
> guarantees that all programs will eventually HALT".

Applied to aeb this would read: constrain the `.ae` build-file language
to a terminating subset (no unbounded loops, no general recursion —
`for-each` / `map` / `fold` only), so that *evaluating the build
configuration* is provably finite. This is Starlark's bet, and Bazel's.

Paul's framing when raising it: **"a build should end, or if it does not,
ctrl-c should end it cleanly."**

That sentence contains two separable claims. They have different answers.

## Claim 2 first: "ctrl-c should end it cleanly" — already true

This was checked before any argument was made about it, because the
argument depends on the facts.

The trampoline (`aeb`, the supervision tail) runs the entire build as a
single backgrounded job which `set -m` places in its own **process
group**, forwards INT/TERM to that group, and unconditionally reaps the
group afterward (TERM → 10×100ms grace → KILL). `--timeout N` /
`AEB_TIMEOUT=N` adds a watchdog that TERMs then KILLs the group on
overrun and reports the coreutils-conventional exit code 124.

Verified end-to-end against a fixture whose build step spawns a
background grandchild and then hangs — i.e. a step that leaks a process,
which is the case naive supervision gets wrong. The whole fixture:

```bash
# slow/run.sh — a build step that hangs AND leaks
#!/usr/bin/env bash
echo "step: starting"
( sleep 300 ) &                 # leaked grandchild
echo "step: leaked pid $!"
sleep 300                       # the step itself never ends
```

```aether
// slow/.build.ae
import build (start)
import bash (test, script)

aeb(cap) {
    b = build.start()
    bash.test(b) { script("run.sh") }
}
```

Reproduce (the `&` + `kill -INT` stands in for an interactive Ctrl-C):

```bash
# Signal path
aeb slow/.build.ae & T=$!; sleep 6; kill -INT $T; wait $T; echo "exit=$?"

# Timeout path
aeb --timeout 8 slow/.build.ae; echo "exit=$?"

# Survivor check (expect 0 both times)
pgrep -x sleep | while read p; do tr '\0' ' ' </proc/$p/cmdline; echo; done \
  | grep -c 300
```

| Scenario | aeb exit | Leaked grandchild afterwards |
|---|---|---|
| SIGINT (Ctrl-C) after 6s | **130** (128+SIGINT) | **killed** — 0 survivors |
| `--timeout 8` | **124** + `aeb: build exceeded timeout 8s; terminating` | **killed** — 0 survivors |

That the leak genuinely happened (rather than the step dying before it
could fork) is confirmed from the node log, which carries
`step: leaked pid <N>` in both runs.

Both the direct child and the leaked grandchild are gone in both cases.
This is the Bazel-shaped answer and it is done. No work needed.

(Historical note: this is not accidental. A lingering native server was
once seen to poison a sandboxed harness's exit — see
`server-daemon-snafu.md` — which is why the group-reap is unconditional
rather than only-on-signal.)

## Claim 1: "a build should end" — declined at the language level

The halting ask targets the **configuration language**. aeb's problem is
not there, and this is the crux:

**Config evaluation is not where builds hang.** Look at what a typical
build file actually asks the language to do:

```aether
import build (start, dep)
import java (javac, release)

aeb(cap) {
    b = build.start()
    build.dep(b, "libs/core/.build.ae")   // runtime no-op — see below
    java.javac(b) {                        // accumulates into a map,
        release("21")                      // then ONE os.system(...)
    }
}
```

There is no loop here, and nothing to diverge. `build.dep()` does
nothing at execution time — the DAG is extracted *textually* by
`tools/extract-deps` before any `.ae` runs — so the graph-construction
phase a halting guarantee would protect is already straight-line. The
setters are map writes. Evaluation finishes in microseconds.

**Builds hang in the `os.system` at the bottom.** The one line that can
run forever is the toolchain invocation, on the far side of a
`fork`/`exec` boundary:

```aether
    // Inside java.javac's builder body, roughly:
    rc = os.system(javac_cmd(opts))   // <- everything that hangs, hangs here
```

No type system, totality checker, or restricted loop form reaches across
that boundary. A provably-terminating config language can still emit:

```aether
    bash.test(b) { script("waits_forever.sh") }   // totally terminating
                                                  // config; infinite build
```

The config evaluated fine. The build never ends. That is the whole
objection in three lines — and it is not hypothetical: that exact build
file, which contains no loop and no recursion and would satisfy any
totality checker, ran until the watchdog killed it (`--timeout 6` →
exit **124**). A halting guarantee on the language would have certified
it as terminating.

**The cost would be severe.** `docs/inline-build-steps.md` is a
load-bearing escape hatch: "if no SDK builder does what you need, the
full language is right there." LLM.md's design principles lean on it as
the reason aeb doesn't need YAML-plus-plugins, and the closure-DSL
ceiling row in the scope table scores ✓ *because* there is no escape
hatch into bash/python/Skylark — the config language IS the
implementation language. Trading that for a guarantee that does not cover
the actual failure mode is a bad trade.

**And it isn't aeb's call.** Aether is a general-purpose language with
users beyond aeb. aeb does not get to make it total.

### The honest framing: aeb already chose the other horn

There are two ways to bound a build's runtime:

1. **Statically** — prove the config terminates (Starlark).
2. **Dynamically** — bound it at runtime with process groups, watchdogs,
   timeouts and forced reaping (Bazel's actual execution layer; aeb's
   trampoline).

aeb picked (2), and for a system whose work is overwhelmingly external
subprocesses this is not merely adequate, it is **strictly stronger on
the dimension that matters**: the dynamic bound also covers `mvn`,
`cargo`, `gradle` and every other opaque child. Starlark's static
guarantee covers none of them — which is precisely why Bazel *also*
implements (2).

Adopting (1) would add a constraint that binds only the part which was
never the problem.

## The one real gap this surfaced

**`--timeout` is whole-build only.** One slow node consumes the shared
budget, and when the watchdog fires it kills the whole process group —
including nodes that were progressing fine and would have finished.

Demonstrated with two independent members of a set, a hung node and an
innocent 10s one, under a 6s budget:

```bash
# slow/.tests.ae  runs `sleep 300`   (never ends)
# quick/.tests.ae runs `sleep 10`    (would finish at 10s)
# .presubmit.ae   deps on both
aeb --timeout 6 .presubmit.ae      # exit 124
```

The innocent node never printed its completion marker — killed
mid-flight at 6s for another node's sin. Its own work needed 10s and
nothing was wrong with it.

Two honest qualifications, both found by testing rather than assuming:

- **Attribution is not entirely absent.** `make` names the culprit on
  stderr — `*** [build.mk:6: slow_.tests.ae] Terminated` — so the
  information exists, in `make`'s voice rather than aeb's.
- **The `[telemetry]` block does not render at all** on the timeout
  path (the group is killed before the driver's collection step), so
  the per-node view that normally shows which target burned the time is
  exactly what you lose when you most want it.

Bazel has per-action timeouts. aeb has the hooks — `tools/aeb-driver`
already writes per-node `.rc` markers and per-node logs in **both**
scheduling modes.

**A Makefile is not always emitted.** `tools/aeb-driver.ae` picks a mode
per invocation: it emits `target/.aeb/build.mk` and runs `make -jN` only
when `AEB_JOBS != 1` *and* `command -v make` succeeds. Otherwise it runs
a sequential in-process loop calling the same `_ae_build_all` binary per
label, and **no Makefile is written at all**:

| Condition | `target/.aeb/build.mk` |
|---|---|
| `AEB_JOBS` unset (defaults to `nproc`) | **emitted** |
| `AEB_JOBS=4` | **emitted** |
| `AEB_JOBS=1` | **absent** — sequential loop |
| `make` not on `PATH` | **absent** — sequential loop |

Verified: `AEB_JOBS=1` builds the same set to exit 0 with both members
run and both `.rc` markers written, with no `build.mk` on disk. So the
Makefile is the *default* path, not the only one — anything that hangs
per-node bounding off the Makefile silently does nothing in sequential
mode.

(The emitted recipes are POSIX shell, which works on Windows only
because the driver's probe and run both go through `build._sh_capture` /
`build._sh` — the chokepoint that routes shell-outs via MSYS `sh` rather
than `cmd.exe`. And on a Windows box with no MSYS `make`, the sequential
loop *is* the path. See `docs/windows-cross-platform-notes.md` § 4.)

In the Makefile mode the emitted file has one target per node:

```make
# target/.aeb/build.mk — real shape, elided. One target per node, dep
# edges as prerequisites; the recipe is ALREADY a wrapper.
.presubmit.ae: slow_.tests.ae quick_.tests.ae
	@_s=$$(date …);  '…/_ae_build_all' '…' 'presubmit:.' > '…/logs/presubmit_..log' 2>&1; \
	 _r=$$?; _e=$$(date …); echo $$_r > '…/rc/.presubmit.ae.rc'; \
	 echo $$((_e-_s)) > '…/rc/.presubmit.ae.ms'; exit $$_r
```

so a per-node bound has a place to attach — but note the recipe is not a
bare command. It already captures start/end milliseconds, redirects to
the per-node log, writes `.rc` and `.ms`, and re-raises the node's exit
code. A per-node timeout has to nest *inside* that wrapper so the `.rc`
still gets written (a naive `timeout N <recipe>` would kill the wrapper
and lose the marker that tells the driver what happened).

There is no per-node cap today (confirmed: no `timeout` handling in
`tools/aeb-driver.ae`; the `timeout(300)` in TODO.md's DSL sketch is an
illustrative junit setter, not a shipped node-level feature).

### Blocked on aether#1278 (filed 2026-07-26)

With `AEB_SCHED=native` there is now ONE scheduler to implement this in
rather than two, which was the main cost. But the primitive is missing:
`os.wait_any(tokens)` blocks indefinitely and has no bounded variant, so
the drain step cannot notice that one child has overrun while others are
still legitimately running.

`os.wait_pid_timeout(pid, secs)` *is* bounded and **does** work on a
spawn token — verified on 0.442.0 Linux: `sleep 30` spawned, bounded
wait returned `timed_out=1` after 2 s, then `kill(tok, 9)` gave status
**137**, distinguishable from any normal exit. But building on that
would be POSIX-only, because the token is only a pid on POSIX. Aether's
own comment says so (`std/os/aether_os.c`): `out._0 = (int)pid; /* token
== pid on POSIX */`, whereas the Windows branch returns a table index
and `os_wait_pid_timeout_raw` there calls `OpenProcess((DWORD)pid)`.

So a per-node timeout written today would silently not fire on Windows —
the exact two-path divergence the native scheduler exists to remove, and
the "green build that proves nothing" shape this repo keeps hitting.

Filed upstream as
[aether#1278](https://github.com/aether-lang-dev/aether/issues/1278):
`os.wait_any_timeout(tokens, secs)` plus a contract that timeout/kill
accept spawn *tokens* on every platform.

**DELIVERED — aether `4368ad1b`, in 0.447.0.** Both halves:

```aether
os.wait_any_timeout(tokens, secs) -> (token, exit, timed_out, err)
```

per-CALL deadline (not a batch one), `timed_out` distinguishable from a
non-zero child exit, `secs <= 0` blocks like `wait_any`. POSIX polls
`waitpid(-1, WNOHANG)` against a monotonic deadline; Windows passes the
deadline to `WaitForMultipleObjects`.

And the asymmetry is closed: `os.kill` / `os.wait_pid_timeout` now
resolve a spawn token through the Windows process table before falling
back to an OS pid, so `kill(spawn_token)` behaves the same on both
platforms — previously it hit an unrelated process on Windows. POSIX
`posix_status_to_tuple` also now maps a signalled child to `128+signo`,
so killing a timed-out token reaps a distinguishable **137** rather than
an opaque "abnormal" error.

Caveats before building on it: the toolchain here must be rebuilt (source
is 0.447.0; an `ae` reporting 0.442.0 does not have it), and the commit
notes the **Windows paths mirror POSIX but await a winbaz run** — so the
cross-platform claim is reasoned, not yet measured, exactly as our own
Windows work was until we ran it.

## RESOLVED (2026-07-26) — `AEB_NODE_TIMEOUT`

Shipped in the native scheduler once aether#1278 landed
`os.wait_any_timeout` (0.447.0). Measured against the exact fixture that
demonstrated the gap — a hung node and an innocent 3s one under a 6s cap:

| | before (`--timeout 6`) | after (`AEB_NODE_TIMEOUT=6`) |
|---|---|---|
| hung node | killed | killed, **named** |
| innocent sibling | killed mid-flight | **finishes** (`QUICK-FINISHED`) |
| `.rc` attribution | — | `slow=137`, `quick=0` |
| `[telemetry]` | **not rendered at all** | renders |

137 is 128+SIGKILL, so a timeout is distinguishable from an ordinary
non-zero exit. Native-scheduler only, and it says so rather than silently
no-opping — the Makefile path would need `timeout(1)` in every recipe (a
dependency aeb does not require) and would still be absent under
`AEB_JOBS=1`. Implementing it in one scheduler rather than two is the
whole reason the native path exists.

The original sketch is kept below for the record.

Sketch, **not designed, not promised**:

- a `timeout(N)` setter on the driver side, or `AEB_NODE_TIMEOUT`;
- **both** scheduling modes bound the node — the Makefile recipe wraps
  `_ae_build_all <root> <label>` in a bounded invocation, and the
  sequential loop applies the same cap. Implementing only the Makefile
  half would make the feature silently absent under `AEB_JOBS=1` and on
  hosts without `make`, which is exactly the "green build that proves
  nothing" shape this repo keeps tripping over;
- the bound must nest *inside* the existing recipe wrapper so `.rc` is
  still written (see above);
- the node's `.rc` records the timeout distinctly from a plain failure so
  `[telemetry]` can render `TIMEOUT` rather than `FAIL`.

Open questions before anyone builds this. Would a per-recipe bound need
the `timeout` binary — a dependency aeb does not currently require, and
which would have to be probed like `make` already is, with a defined
behaviour when absent? What is the sequential-loop equivalent, given it
has no `make` to lean on? And does a per-node cap want to be declarable
in the `.ae` file — which would make it config, and therefore subject to
the file-as-truth principle — or purely an operator-side env var like
`AEB_JOBS`?

Filed as an observation, not a plan.

## Decision

**Declined** for the language-level halting guarantee: it does not
address where aeb builds actually hang, and it would cost the inline
escape hatch that the configuration-DSL-ceiling score depends on.

**No action needed** for signal/timeout cleanliness: process group +
signal forwarding + watchdog + unconditional group reap are implemented
and verified (130 on Ctrl-C, 124 on timeout, zero leaked survivors in
both).

**Open** for per-node timeouts, which is the version of "a build should
end" that would actually improve aeb.

## Postscript: why two schedulers at all?

Paul's follow-on challenge (2026-07-25): if aeb has already scanned and
topo-sorted the DAG, why emit a Makefile instead of scheduling the nodes
itself? The sequential fallback is ~35 lines and already does everything
the Makefile path does *except* run nodes concurrently — so `make` buys
exactly one capability, at the cost of POSIX-shell recipes through the
Windows chokepoint, `$$`-escaping that differs between the two modes,
two schedulers that can silently diverge (this section's per-node
timeout being the example), and an external dependency whose absence
silently halves throughput.

A native scheduler — spawn up to N ready nodes, wait for any, unblock
dependents — is ~80–120 lines given the topo-sorted DAG. The blocker
*was* platform coverage: `os.run_pipe` / `os.wait_pid` (non-blocking
spawn + reap) were **hard stubs on Windows**, and `os.run_supervised` is
blocking-with-timeout, so it supervises one child rather than fanning
out. Filed upstream as
`../aether/asks/os-run-pipe-on-windows-for-parallel-build-scheduling.md`,
asking for a pipe-less `spawn`/`wait_any` pair (a split of the existing,
working `win_launch`) plus winbaz acceptance criteria.

**UNBLOCKED — aether 0.442.0** shipped exactly that:

```
os.spawn_proc(prog, argv, env) -> (token, err)      // non-blocking
os.wait(token)                 -> (exit_code, err)
os.wait_any(tokens)            -> (token, exit_code, err)   // fan-in
```

Cross-platform including Windows, because these create no IPC pipe —
the pipe was the only part that needed the `_open_osfhandle` work.
`spawn_proc`, not `spawn`, because `spawn` is the reserved actor
keyword. Windows holds spawned handles in an int-token→HANDLE table with
**tokens never recycled, so PID reuse cannot misattribute a reap** — a
hazard our ask didn't think to raise. Verified on Win11/MSYS2 against
every acceptance criterion we listed, including genuine concurrency
(4×sleep-2 in ~2 s, so not silently serialised) and clean coexistence
with a `run_supervised` Job Object.

So the native scheduler is now writable on **every** platform aeb
targets, and the Makefile path has no remaining capability advantage.
Toolchain floor: `ae >= 0.442.0`.

### Smoke-tested locally on 0.442.0 (Linux) before designing anything

```aether
    tok, err = os.spawn_proc("sleep", argv, null)   // argv EXCLUDES argv[0]
    …
    tok, code, err = os.wait_any(toks)
```

- **Genuinely concurrent**: 4 × `sleep 2` completed in **2 s**, not 8.
- **Completion-order reap**: tokens came back `18248, 18249, 18247,
  18250` — not spawn order. `wait_any` is a real wait-any.
- **Exit codes faithful**: `sh -c "exit N"` children reported 0 / 1 / 2
  distinctly, which is what `.rc` markers depend on.

Two API notes for whoever writes the scheduler:

1. **`argv` excludes `argv[0]`.** Passing the program name as the first
   list element makes it an *argument* (`sleep sleep 2` →
   `invalid time interval 'sleep'`). Cost me one run.
2. **A failed exec is NOT reported at spawn time.** Spawning a
   nonexistent binary returned a valid token and an *empty* err string;
   the failure surfaced only as **exit 127** from `wait`. This is
   ordinary fork-then-exec behaviour, but it means the scheduler cannot
   treat "spawn returned no error" as "the node started" — a missing
   toolchain looks identical to a node that ran and failed. The
   acceptance criterion in the upstream ask ("distinguishable from a
   spawn failure") is therefore only half-met, and by design; the
   scheduler must map non-zero exit → node failed and let 127 speak for
   itself, exactly as the Makefile path already does.

If that lands, the right shape is `AEB_SCHED=native` as a third mode
first — proven green on Linux + winbaz — then flip the default and
delete the Makefile path, with the deletion trigger stated up front so
it doesn't stall at three paths.

## Related

- `docs/presubmit-target-sets.md` — the other outcome of the same thread.
- `TODO.md` § "Full Aether CLI entrypoint" — the supervision tail is the
  main obstacle to porting the trampoline to native Aether; it needs
  `os.run_supervised`-shaped primitives (and Windows Job Objects), which
  is the same machinery this ask leans on.
- `docs/aeb-vs-bazel.md` — the hermeticity tier, where aeb's other
  deliberate divergences from Bazel are recorded.
