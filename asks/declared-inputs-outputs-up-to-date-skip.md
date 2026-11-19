# Declared inputs/outputs: an up-to-date skip for any node

**From:** a review of David Nelson's Casper (`../casper1`, the Boo-scripted
.NET build tool), 2026-11-19
**Status:** open, not started

## The gap

aeb skips work only where an SDK has been wired into `lib/cache`: maven,
aether, java, kotlin, scala, groovy, ts, dotnet, go, rust, clojure (see
`docs/sdk-ladder.md` for the exceptions inside those). Everything else re-runs
on every build:

- inline build steps (`os.system(...)` inside `bldr.build() { }`, the escape
  hatch in `docs/design/inline-build-steps.md`);
- the SDKs with no cache wiring: c, cpp, zig, swift, nim, d, crystal,
  javascript, pnpm, jest, webpack, angular and the rest;
- named sets' guards and any hand-rolled node.

Each new SDK has to get its own `_cache_key_for_*` before it can skip, so
coverage grows one SDK at a time and inline steps never get it.

## What Casper does

casper1 gives every task, including a raw `Exec`, two optional lists:
`InputFiles` and `OutputFiles` (`Core/TaskBase.cs`). After a task runs it
records both sets with their timestamps in `<project>/.casper/tasks`. Next
time, the task is skipped and printed `(UP-TO-DATE)` when:

- it declared at least one output (no outputs means it always runs), and
- the input set and its timestamps are unchanged, and
- the output set and its timestamps are unchanged.

See `ProjectBase.Execute` / `TaskRecord.IsUpToDate`. It is generic: the
skip belongs to the task model, not to any one task type. This is Gradle's
up-to-date check, and it is the one idea in Casper that aeb lacks.

## Sketch for aeb

Keep Casper's rules, but key on content rather than mtime, and use what
`lib/cache` already has (`cache.hash_file`, `cache.hash_inputs`).

**Setters (in `lib/bldr`, repeatable, `_ctx` first):**

```aether
import bldr (inputs, outputs, run)

aeb(cap) {
    bldr.build() {
        bldr.step() {
            inputs("src/**/*.c")
            inputs("Makefile")
            outputs("target/bin/tool")
            run("make tool")
        }
    }
}
```

**The skip needs a builder, not just setters.** Inline statements in a
`bldr.build()` block run as they are reached, and an `inputs()` call cannot
skip the statements after it. So:

1. `bldr.step() { inputs(..) outputs(..) run(..) }`: a builder that runs its
   commands when its block closes and can skip them. This is the SDK
   pattern (setters collect, builder acts) applied to an arbitrary command,
   and `run()` goes through a pure `*_cmd` helper like every other exec.
2. For inline code that needs real Aether rather than a command, a guard:
   `if bldr.up_to_date("label") == 0 { ...work...; bldr.record("label") }`.
   It's less pretty, but it works for anything.
3. An SDK with no cache wiring (c, cpp, zig, …) can call the same helper with
   inputs and outputs it already knows (its sources and its binary). That
   gives it a skip without writing a per-SDK cache key.

**Key:** sha256 over, sorted:

- each matched input path and its content hash;
- the step's command strings;
- the node's own `.ae` file content (editing the build file invalidates);
- toolchain identity (see `asks/cache-key-omits-toolchain-identity.md`);
- each upstream dep's recorded output hashes, so a changed dep invalidates
  its dependents even when this node's own sources did not change.

**Stamp:** `target/_aeb/uptodate/<label>.<step>`, holding the key plus
each output's content hash. Skip only when the key matches and every output
exists with its recorded hash. Write the stamp only after the step succeeds.
A failed run deletes it, so a failure is never remembered as up to date.

**Fail open, in the safe direction.** If a glob errors, an input can't be
read, or the stamp can't be parsed, run the step. A missed skip costs time.
A wrong skip ships a stale artifact.

**Telemetry:** report the outcome as `up-to-date` on the node's row, beside
the existing cache hit and miss. That is Casper's `(UP-TO-DATE)` marker, and
the block already has a column for it.

**Escape:** `AEB_NO_UPTODATE=1` (or a `--rerun` flag) forces every step to
run.

## Up-to-date check vs cache: not the same thing

- `lib/cache` is an artifact store. It restores outputs by key, and since
  `AEB_REMOTE_CACHE_URL` it can share them across machines.
- This ask is a local check that the outputs already in place are current.
  It needs no blob store and costs one hash pass.

The two compose: a step's key could later feed `cache.put`/`cache.get` for
its outputs, which would give inline steps a remote cache too. Leave that
for a follow-up.

## The known risk

An undeclared input gives a wrong skip. Gradle has lived with this for years,
and it is why "no outputs, no skip" matters. Two mitigations, neither needed
for v1:

- `--sandbox` already intercepts file opens at the libc boundary. It could
  later report reads outside a step's declared inputs.
- The itest below should include a deliberately under-declared step, so the
  behaviour is pinned and documented rather than discovered.

## Not asked for

- mtime keys (Casper's choice). Content hashes survive `git checkout`, CI
  clones and `touch`.
- Changing any SDK that is already cache-wired.
- Remote sharing of step outputs (see above).

## Acceptance

An itest (`itests/declared-step-up-to-date.sh`) with a `bldr.step` node:

1. A first run executes the step and writes the stamp.
2. A second run skips it and telemetry says `up-to-date`.
3. A `touch` on an input with no content change still skips.
4. A content change to an input reruns the step.
5. Editing the node's `.ae` file reruns the step.
6. Deleting or editing an output reruns the step.
7. A changed upstream dep output reruns the dependent.
8. A failing step leaves no stamp, and the next run executes it again.
9. A step with inputs but no outputs always runs.
10. `AEB_NO_UPTODATE=1` runs everything.

Plus unit tests for the pure key builder in `tests/`, and the result
checked under `make`, `AEB_JOBS=1` and `AEB_SCHED=native` (all three
schedulers must agree).
