# Halting guarantees: should aeb's config language be non-Turing-complete?

**Filed by**: Paul + LLM session, 2026-07-25, prompted by a comment
thread on "What makes a good build system?" (r/programming, 2026-07-24).
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

## Related

- `docs/presubmit-target-sets.md` — the other outcome of the same thread.
- `TODO.md` § "Full Aether CLI entrypoint" — the supervision tail is the
  main obstacle to porting the trampoline to native Aether; it needs
  `os.run_supervised`-shaped primitives (and Windows Job Objects), which
  is the same machinery this ask leans on.
- `docs/aeb-vs-bazel.md` — the hermeticity tier, where aeb's other
  deliberate divergences from Bazel are recorded.
