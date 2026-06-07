# Node failure must redden the build (silent-green fix)

**Filed by**: a tracing session (Paul + LLM), after noticing a failed
compile produced an exit-0 build.
**Status**: implemented (this pass).
**Severity**: was critical — a build tool that exits 0 on a failed compile
is the worst failure mode (CI passes on broken code).

## The bug

`aeb foo/bar/.tests.ae`, where the test target `dep`s a compile that
FAILS, exited **0**, printed `test:... 0/0 PASS`, and the only trace of
the compile error was text in a per-node log file. Verified on a Java
fixture with a deliberate syntax error: `javac` failed, yet the build was
green.

Root cause, two independent links both broken (so it affected EVERY SDK,
not one):

1. **The generated orchestrator (`tools/gen-orchestrator.ae`) discarded
   the node outcome.** It emitted `<node>(s)` (return ignored) then
   unconditionally `build.done(label)`, and `main()` never exited
   non-zero. So even an explicit failing return vanished. A stale comment
   blamed "a `.build.ae` `main()` is typed void" — but `transform-ae`
   already injects the `if b == 0 { return 0 }` begin-guard, which makes
   every builder fn int-typed (verified: a transformed-shape fn returns
   its rc cleanly).

2. **Builders swallowed their own rc anyway.** The user writes
   `java.javac(b)` with no `return`, so the node fn falls off the end
   returning 0 regardless of what `javac` returned. Reading the node fn's
   rc (link 1) is therefore necessary but NOT sufficient — the rc the
   orchestrator can read is the *user main's*, which is 0.

The status machine to fix it already existed and was wired to nothing:
`build.fail` / `record_status` / `any_failed` / `failures` /
`reason_of` in `lib/build`, plus `aeb-driver` already aggregating rc
marks + `test_failed>0` and `exit(1)`-ing on `any_failed`. No SDK called
`build.fail`; the orchestrator never checked `any_failed`.

## The fix

Both links, because either alone leaves the silent-green:

1. **Orchestrator** (`gen-orchestrator`): capture `_rc = <node>(s)`, call
   `build.record_status(s, label, _rc)`, and after the run loop
   `if build.any_failed(s) == 1 { exit(1) }`. The exit gate sits OUTSIDE
   the per-node `_sel` guard so it fires in both modes:
   - per-node (default): the node-subprocess exits non-zero → its rc mark
     is non-zero → `aeb-driver`'s existing `any_failed` aggregation +
     `make -k` skip-dependents catch it and `exit(1)`.
   - in-process (`--in-process`): this is the whole run, so it exits
     non-zero directly.

2. **SDK sweep**: every `os.system`-failure path (and
   missing-required-setter guard) inside a `builder ...(ctx: ptr)` body
   now calls `build.fail(ctx, "<reason>")` before its non-zero return.
   `build.fail` writes the failure into the shared session that
   `any_failed` reads — the channel the user's return-less `main()` can't
   swallow. ~69 sites across 16 SDKs (java, python, ruby, c, kotlin,
   scala, clojure, jest, ts, pnpm, webpack, bash, copy, webhook,
   approval; maven had no builders). Pure command-string helpers (`*_cmd`,
   `_foo`) were left alone — they have no `ctx` and their `return 1`s are
   validation, not build failures (handled by their builder callers).

`record_status` never downgrades an explicit `build.fail` to passed, so
the two mechanisms compose: a builder that both `build.fail`s and returns
0 (or vice versa) stays failed.

## Why both, not one

- Orchestrator-only (read the rc): the user's `main()` returns 0 (no
  explicit return), so the rc is always 0 — silent green persists.
- Sweep-only (`build.fail` everywhere): the session records the failure
  but the orchestrator still exits 0 — silent green persists.
Only together do they redden the build.

## Verification

A test target whose compile dep fails: exit non-zero in BOTH per-node and
in-process; driver prints `FAILED (see <log>)` + cats the log; failed
compile's rc mark = 1; dependent skipped by `make -k` and flagged failed;
clean build still exits 0; `bash.test` failure reddens while a passing
`bash.test` stays green. `tests/run.sh` 69/69.

## Follow-up

- Per-step sandboxing / isolation remains separate (`docs/lifecycle_plan.md`).
- A future `record_status`-from-rc path could also catch an explicit
  `return <nonzero>` from a user `main()` that DOES return — already
  wired (the orchestrator reads `_rc`), just rarely exercised because
  users seldom `return` from a builder call.
- Structured per-test XML/JSON (TODO.md) would let the driver distinguish
  "test failed" from "test errored" more richly than the rc + `0/0`
  heuristic.
