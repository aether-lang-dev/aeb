# Shape A: driver_test's sub-builders stage nothing — fixtures/env never provision

**Severity: every fixture-driven driver_test is silently broken.** Found on
avn (2026-08-28): 40 of 54 test targets fail; the 14 that pass are the
fixture-less program tests.

## Symptom

A converted Shape A node:

```aether
bldr.build() {
    dep("avn")
    aether.driver_test() {
        driver("test_commit_driver.ae")
        output("test_commit_driver")
        binary_under_test("avn") { path("target/build/avn/bin/avn") }
        fixture_seed("test_commit") {
            path("/tmp/avn_aeb_test_commit_repo")
            seed_bin("target/build-seed/avnserver/bin/avn-seed")
        }
        fixture_server("test_commit") {
            bin("target/build/avnserver/bin/avnserver")
            args("demo $TEST_COMMIT_PATH 9400")
            port(9400)
            ready_after_ms(1500)
        }
    }
}
```

builds the driver and runs it — with NO env exports, NO seed, NO server.
Captured via a logging `bash` shim on PATH; the entire synthesized chain
for the node above is:

```
bash -c AE_SPEC_FORMAT=aeocha AE_SPEC_REPORT="…/_spec_report.txt" "…/bin/test_commit_driver"; rc=$?; exit $rc
```

No `export AVN_BIN=…`, no `export TEST_COMMIT_PATH=…`, no `rm -rf` +
seed_bin run, no server spawn, no teardown. The driver then reads empty
env and every content assertion fails (or worse: it talks to residue —
stale /tmp repos and WCs from pre-rework runs — and fails confusingly
half-way through, which is how this presented).

The failure is SILENT at build level: the node goes red only on the
driver's own assertions. Nothing says "0 fixtures staged".

## Root cause

`lib/aether`'s Shape A sub-builders all begin:

```aether
builder binary_under_test(name: string): int {
    b = builder_context()
    if b == 0 { return 0 }        // <- silently no-ops
    …stage onto b._pending_binaries_under_test…
```

(same for `fixture_seed`, `fixture_server` — and lib/bash's copies).

Per aether's builder-context contract
(docs/closures-and-builder-dsl.md "Builder Context Stack"): a trailing
block runs with the ENCLOSING CALL'S RETURN VALUE pushed as the context.
For a `builder`-keyword function the block executes BEFORE the body, so
inside `aether.driver_test() { … }` the pushed context for that block
isn't the build ctx — the value isn't available yet, and
`builder_context()` returns 0. The build ctx that the old
`binary_under_test(b, …)` received explicitly is one level further up
the stack, which `builder_context()` (top-of-stack only) can't reach.

So the two-stage staging contract ("stage onto `b`, the enclosing test
builder drains `_pending_*`") lost its `b` in the (b)-stripping codemod:
`_drain_pending_fixtures` runs fine but the pending lists are empty.

## Repro

Any avn driver test: `cd ~/scm/avn && aeb working_copy/.tests-commit.ae`
(aeb v0.282-43-g3326633, ae 0.590.0). Manually exporting the env vars and
hand-spawning seed+server, then running the built driver binary, passes
8/8 — drivers, binaries, and the report transport are all fine; only the
provisioning is missing.

## Fix shapes (pick one)

1. **Module-global pending cells** in lib/aether (and lib/bash): the
   sub-builders append to module-level lists instead of `b`; the
   enclosing test builder's body drains-and-clears them. Node processes
   are single-threaded per node, so a global is safe, and it removes the
   need for a context handle entirely — most faithful to the b-free
   spirit.
2. An aether-side `builder_context_nearest()` / stack-walking accessor so
   sub-builders can find the first real build ctx above them — bigger
   hammer, needs an upstream ask.
3. Have `bldr.build` stash its ctx somewhere process-visible
   (`bldr._current_ctx`) that `builder_context()==0` falls back to —
   variant of (1) with the existing record formats untouched.

Also worth adding whichever fix lands: a LOUD failure when a
driver_test declares a `driver(…)` but zero binaries_under_test AND zero
fixtures were staged at drain time — this bug class should never be
silent again.

Filed by the avn sibling; avn is fully converted to Shape A and
otherwise green (the 14 non-fixture targets pass on ae 0.590.0).
