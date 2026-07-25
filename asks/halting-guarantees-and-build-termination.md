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
background grandchild and then sleeps 300s — i.e. a step that leaks a
process, which is the case naive supervision gets wrong:

| Scenario | aeb exit | Leaked grandchild afterwards |
|---|---|---|
| SIGINT (Ctrl-C) after 6s | **130** (128+SIGINT) | **killed** — 0 survivors |
| `--timeout 8` | **124** + `aeb: build exceeded timeout 8s; terminating` | **killed** — 0 survivors |

Both the direct child and the leaked grandchild are gone in both cases.
This is the Bazel-shaped answer and it is done. No work needed.

(Historical note: this is not accidental. A lingering native server was
once seen to poison a sandboxed harness's exit — see
`server-daemon-snafu.md` — which is why the group-reap is unconditional
rather than only-on-signal.)

## Claim 1: "a build should end" — declined at the language level

The halting ask targets the **configuration language**. aeb's problem is
not there, and this is the crux:

**Config evaluation is not where builds hang.** A `.build.ae` that calls
setters and `build.dep(...)` finishes in microseconds. `build.dep()` is a
runtime no-op — the DAG is extracted *textually* by `tools/extract-deps`
before any `.ae` executes — so the graph-construction phase the halting
guarantee would protect is already effectively straight-line.

**Builds hang in `os.system("mvn ...")`.** The non-terminating thing is
an external toolchain process on the far side of a `fork`/`exec`
boundary. No type system, totality checker, or restricted loop form
reaches across that boundary. Making Aether non-Turing-complete would not
shorten a single real hang, because a terminating config language can
still emit `mvn -Dtest.wait.forever`.

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

**`--timeout` is whole-build only.** One slow node can consume the entire
budget, and when the watchdog fires every *other* node is killed for that
node's sin. The build reports 124 with no indication of which node was
responsible.

Bazel has per-action timeouts. aeb has the hooks — `tools/aeb-driver`
already writes per-node `.rc` markers and per-node logs, and the emitted
Makefile has one target per node — but there is no per-node cap today
(confirmed: no `timeout` handling in `tools/aeb-driver.ae`; the
`timeout(300)` in TODO.md's DSL sketch is an illustrative junit setter,
not a shipped node-level feature).

Sketch, **not designed, not promised**:

- a `timeout(N)` setter on the driver side, or `AEB_NODE_TIMEOUT`;
- the Makefile recipe wraps `_ae_build_all <root> <label>` in a bounded
  invocation;
- the node's `.rc` records the timeout distinctly from a plain failure so
  `[telemetry]` can render `TIMEOUT` rather than `FAIL`.

Open questions before anyone builds this: does the Makefile path make
per-recipe bounding awkward (a `timeout` binary dependency aeb does not
currently require)? Does it interact badly with the sequential fallback
path? Does a per-node cap want to be declarable in the `.ae` file — which
would make it config, and therefore subject to the "closure-DSL grammar
over external config" principle — or purely an operator-side env var?

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
