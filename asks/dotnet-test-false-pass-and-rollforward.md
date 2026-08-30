# dotnet.test: reports PASS when the test run fails, and no roll-forward option

**From:** the Selenium-on-Aether port converting its binding nodes to the
declarative bldr/dotnet grammar (matching google-monorepo-sim), 2026-08-29.

Two issues surfaced wiring `dotnet.build_project(){ test_project() }` +
`dotnet.test()` for a real xUnit project.

## Bug 1 (falsely green): `dotnet.test` reports PASS when `dotnet test` fails

When the test host aborts, `dotnet.test` still records the node as passed. Two
observed instances, both ending in `tests:<node>: tests PASSED` with `0/0 PASS`
in telemetry despite a hard failure:

- a **compile failure** (missing PackageReference — 18 `error CS0246`): the log
  showed `dotnet build failed`, then `running tests`, then `tests PASSED`.
- a **testhost launch failure**: `Testhost process ... exited with error: You
  must install or update .NET ... Test Run Aborted.` — then `tests PASSED`.

Expected: a non-zero `dotnet test` (or `dotnet build`) exit must fail the node.
This is the same class as the `.tests.ae` node-return propagation fix (REQUEST 4)
but inside the dotnet SDK builder's own pass/fail detection — it currently
green-lights a run that produced no passing tests, or that never ran. A
build-failure should also short-circuit before "running tests" rather than
proceeding to a run that can only abort.

Repro shape: a `test_project()` whose csproj references a TFM the box lacks a
runtime for, or one with a compile error, run via `dotnet.test()`.

## Bug/Gap 2: `dotnet.test` cannot roll forward to a newer runtime

A test project targeting `net8.0` cannot run on a box that has only the net10
runtime — `dotnet test`'s testhost demands the exact `Microsoft.NETCore.App
8.0.0` and aborts. The fix a hand-rolled node used was `dotnet exec
--roll-forward Major`, but `dotnet.test()` offers no equivalent, so the only
option was to retarget the test project to `net10.0`.

Ask: a `roll_forward("Major")` (or similar) setter on the dotnet builders that
threads `--roll-forward`/`DOTNET_ROLL_FORWARD` into the test (and run) invocation,
so a net8-targeted assembly can run on a newer runtime without retargeting. This
matters for CI boxes that track the latest SDK while a project pins an older TFM.

## Not blocking

We worked around Bug 2 by targeting net10.0 (matches the box). Bug 1 is the
important one — it lets a broken .NET test node push green, which defeats the
gate. Our `ci/run.sh` log-scan currently catches it, but the builder itself
should fail.

---

## RESOLVED (2026-08-30, verified on a net10-only box, .160)

All three fixed in lib/dotnet + covered/proven:

Bug 1 had TWO root causes, both fixed:
  1a. `dotnet.test` ran `dotnet test … | tee log`, so exit_code was TEE's
      (~always 0), masking the failure. Fixed: `> log 2>&1` redirect, which
      preserves dotnet test's own exit code. Proven on .160: the identical
      `dotnet test` returns 0 via `| tee` and 1 via `> redirect`.
  1b. Even once test()/build_project() saw the non-zero exit, they only
      `return exit_code` — swallowed by the immediate build() block — so the
      node was never marked failed. Fixed: they now call bldr.fail(ctx, …)
      (like _run_project already did). End-to-end on .160 a net8 test node on
      a net10 box now goes from "0/0 PASS, aeb exit 0" to "0/0 FAIL, aeb exit
      1"; both a build failure and a testhost-abort redden the node.

Bug 2: added a roll_forward("Major") setter on the dotnet builders that
  threads DOTNET_ROLL_FORWARD into the test/run. Verified on .160: a net8
  test that aborts without it ("Framework 'Microsoft.NETCore.App' 8.0.0")
  runs and passes with DOTNET_ROLL_FORWARD=Major. For test_existing(), use
  env("DOTNET_ROLL_FORWARD","Major") (same proc_env path).

Unit coverage in tests/test_dotnet_cmd.ae (_roll_forward_prefix cases).
Suite 127/127.
