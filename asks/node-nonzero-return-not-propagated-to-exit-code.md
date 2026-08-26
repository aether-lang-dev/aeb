# A node's non-zero return is not propagated to the build's exit code

**From:** the Selenium porting sibling (filed as their "REQUEST 4"), while
building a presubmit gate for the Bazel→aeb migration. **Where it bit:** the
whole presubmit gate reported **falsely green** — a node returned non-zero, aeb
exited 0, CI passed a broken tree. The original ask text was filed on the
CatchyOS box; this file is the aeb-side capture + **verified diagnosis** (the
bug reproduces in the current tree by code inspection).

## The claim

> aeb doesn't propagate a node's non-zero return to its exit code, so the whole
> presubmit gate was falsely green.

**Confirmed real (reproduced on this box, not just inferred), and
path-dependent.** A node whose `aeb(cap)` body `return`s non-zero **without**
also calling `build.fail(ctx, …)` is silently swallowed by the default
in-process orchestrator, and the build exits 0.

Measured 2026-08-26 against `/home/paul/.local/bin/aeb` with the repro at the
foot of this file:

| node body | expected exit | actual exit |
|---|---|---|
| `return 1` (no `build.fail`) | non-zero | **0 — BUG** |
| `build.fail(b, …)` then `return 1` | non-zero | 1 ✓ |
| `return 0` | 0 | 0 ✓ |

So the `build.fail()` channel works; the bare-`return` channel is the hole.

## Diagnosis (verified against tools/gen-orchestrator.ae + aeb-driver.ae)

aeb has **two** node-execution paths with **different** failure semantics:

### Path 1 — in-process orchestrator (the DEFAULT fan-out) — HAS the bug

`tools/gen-orchestrator.ae:126` runs each node as a plain call and
**deliberately discards its return value**:

```
println("    ${fname}(s)")        // NOT  _rc = ${fname}(s)
```

The comment (gen-orchestrator.ae:112-125) explains *why* the return is dropped:
a `.build.ae` whose last statement is a bare trailing-block builder
(`aether.program(b) { … }`, no explicit `return`) yields that block
expression's value as the implicit return, which is garbage-nonzero for some
builders (`aether.program` → garbage 1) and 0 for others (`c.program`) —
builder-dependent and latent. So trusting `_rc = ${fname}(s)` spuriously
**failed passing** builds. The fix at the time was to stop reading the return
and route failure exclusively through an explicit channel:

- every SDK builder calls `build.fail(ctx, reason)` on `os.system` failure,
- `build.fail` sets session status,
- `build.any_failed(s)` reads it,
- `gen-orchestrator.ae:201` → `if build.any_failed(s) == 1 { exit(1) }`.

That channel is correct **for SDK builders that use it**. The hole: a node that
computes its own outcome and `return 1`s **directly** — a hand-written gate,
a `.presubmit.ae` check, any custom node — never touches `build.fail()`, so:

1. its return is discarded (L126),
2. `build.status_of()` reports `passed` (nothing marked it failed;
   gen-orchestrator.ae:134 defaults empty status → `"passed"`),
3. `any_failed` stays 0 → **no `exit(1)` → exit 0 → falsely green.**

This is exactly the sibling's gate.

### Path 2 — per-node make/driver path — does NOT have the bug

`tools/aeb-driver.ae` `_node_cmd` runs each node as a **child process** and
captures its real exit code into a `.rc` marker (`'; exit $$_r`,
aeb-driver.ae ~L25), which the driver's `any_failed` reads. A bare `return 1`
becomes the child's exit code and is honoured here. So the same node fails
correctly under the make path and passes falsely under the in-process
orchestrator — a mode-dependent disagreement.

## Why the earlier ask doesn't cover this

`asks/orchestrator-failures-silenced-and-stale-helper-tools.md` (resolved,
27579bb) was about the orchestrator's **compile/link** being silenced — a
different failure (the orchestrator binary not existing). REQUEST 4 is about a
**successfully-built** orchestrator **discarding a node's own return value**.
Related family, distinct mechanism.

## The ask

Make a node's non-zero return redden the build in the in-process orchestrator
too, WITHOUT reintroducing the garbage-implicit-return false-fail the discard
was protecting against.

## RESOLVED root cause + plan (2026-08-26, after the aether-sibling investigation)

The aether sibling reproduced the garbage read and traced it precisely (see
`note_here.md` in the aeb repo root for the full exchange). The mechanism is
NOT a builder artifact and NOT specific to trailing blocks:

- Aether has **no tail-expression-as-return semantics at all** — `f() { 7 }` is
  void, same as `f() { builder(m){…} }`. An untyped function is void unless it
  has an explicit `return` OR (see below) a declared `-> int`.
- aeb's node entry is rewritten by `transform-ae` to `<fname>(s: ptr) {` —
  **void** — but `gen-orchestrator.ae:69` declares it `extern … -> int`. A void
  definition read through an `-> int` declaration across a TU boundary compiles
  **silently** and reads the return register = stack residue (measured:
  `1322553392`, `-2039513040`, … — "builder-dependent" only because different
  builder bodies leave different values behind). This is the deliberate
  `void-inferred returns` behaviour, aether `cf461f0d` / #354, not a regression.

The original proposal (1) — "make the builder value flow through" — is
**withdrawn**: it would require adding tail-expression-return semantics to the
whole language (every `foo() { bar() }` flips from call-and-discard to
call-and-return), a huge blast radius. Corrected split:

### aeb side (self-contained, does NOT wait on aether) — the fix

Measured against local `ae`:
- An `-> int` node whose last statement is a bare builder call flows the
  builder's rc automatically (success→0, failure→7) — **no explicit tail
  `return` needed in the node body**, so no `.build.ae` edits.
- BUT only if the tail builder is itself `: int`. A **void** builder under an
  `-> int` node reads the same garbage one level up (measured `-1740860416`).
- aeb's surface: **all 152 SDK builders are void-typed** (`builder …(): int` →
  0 matches), yet **152/152 already have explicit `return 0`/`return rc` in
  their bodies**. They just never declare the type.

So the aeb fix is two mechanical, purely-additive parts:
1. **Declare `: int` on all 152 builder signatures** (bodies already return
   ints — no body changes).
2. **Emit `-> int` on the node entry in `transform-ae`**, and drop the
   discard-the-return workaround in `gen-orchestrator.ae` (read `_rc =
   ${fname}(s)` again — now trustworthy).

### aether side (belt-and-braces, tracked separately) — proposal (3)

Make `extern f() -> int` over a void definition a **hard diagnostic** instead
of a silent garbage-compiling mismatch (`aether/asks/bug_hypothesis.md`). This
closes the class permanently so a future hand-written void builder can't
silently reintroduce the hole. Not a blocker for the aeb fix; a safety net over
it.

**Either way, the in-process orchestrator must not exit 0 when a node returned
non-zero.** A falsely-green presubmit is the worst failure a build tool can
have.

## Acceptance

- A node `aeb(cap) { … return 1 }` (no `build.fail`) under the DEFAULT
  in-process fan-out makes `aeb` exit non-zero. Add a test node that returns 1
  and assert the harness exit code.
- The garbage-implicit-return case the discard protected against
  (`aether.program(b){…}` tail-call) still exits 0 on success — no regression
  to the false-fail this replaced. Assert a known-good `aether.program` /
  `c.program` node still passes.
- Both execution paths (in-process orchestrator AND per-node make/driver)
  agree on the same node's pass/fail.

## Repro sketch (for whoever picks this up)

```
mkdir /tmp/rc-repro && cd /tmp/rc-repro
cat > .gate.ae <<'AE'
import build
aeb(cap) {
    b = build.start()
    // a real gate would check something; simulate the failure
    return 1        // NO build.fail() — the bug is this being ignored
}
AE
aeb .gate.ae ; echo "aeb exit = $?"   # BUG: prints 0, should be non-zero
```
