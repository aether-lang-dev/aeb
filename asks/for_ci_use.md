# Ask: `--telemetry-json <path>` — machine-readable build report

Filed from Paul's request, 2026-07-07.

## Who is asking

A self-hosted **CI daemon for the Aether family** is in design (it lives in
the former Snap CI archive repo; the product name is provisional, so this
doc doesn't use one). It watches git repos, commissions a pipeline per
branch, and executes stages in aeo-confined containers. Its zero-config
convention: a repo containing dot-prefixed `.ae` build nodes and no
pipeline file gets the implicit CI pipeline `aeb --since <ref>` inside a
contained toolchain container.

To render build records, per-target status, and failing-test surfacing,
the daemon needs **per-target outcomes** from that run. This ask does not
block the daemon (stdout scraping is the fallback), so it de-risks timing
rather than gates it.

A second ask (the `lib/cache` store exposed as a consumable contract for
CI stage-caching) is anticipated but **deliberately deferred** until the
daemon's caching phase nears — one ask at a time.

## What this is

The per-target information already exists — the `[telemetry]` block
(per-node wall-time, cache outcome, `14/14 PASS` / `28/30 FAIL` test
counts, fed by the driver's `.rc` markers and the aeocha IPC report) —
but only as a human-facing stdout block. Scraping it is fragile: the
format is unversioned prose, and under `make -jN` it interleaves with
build output.

aeb's LLM.md already anticipates this exact consumer: *"Future renderers
(file dump, web view) plug in via `build.render_telemetry` and the
records list."* This ask is that file-dump renderer, with a locked
schema.

## The shape

A flag on the normal build invocation (env-var equivalent
`AEB_TELEMETRY_JSON=<path>` for trampoline/driver plumbing, mirroring
`AEB_COVERAGE`):

```
aeb --telemetry-json target/_aeb/telemetry.json path/to/.build.ae
```

At end of run — both driver paths, the parallel Makefile mode *and* the
`AEB_JOBS=1` sequential loop — aeb writes (tmp + rename, atomic):

```json
{
  "version": 1,
  "aeb_version": "…",
  "since_ref": "abc1234 | null",
  "targets": [
    {
      "label": "java_app/.tests.ae",
      "type": "test",
      "status": "pass | fail | skipped | cache-hit",
      "duration_ms": 4180,
      "cache": "hit | miss | n/a",
      "rc": 0,
      "tests": { "total": 30, "passed": 28, "failed": 2, "errored": 0 }
    }
  ],
  "summary": { "built": 12, "failed": 1, "skipped": 3, "duration_ms": 61240 }
}
```

- `targets[]` in the topo order the driver ran them; keys insertion-
  ordered per the std.json contract.
- `tests` is `null` for non-test targets and for hand-rolled drivers
  with no aeocha report (exit-code-mapped targets report `rc` only) —
  the same granularity split `_parse_aeocha_report` already handles.
- `label` is the human-display label (`:tag` suffix preserved), matching
  `--graph` node names, so a consumer can join telemetry to the DAG.
- The stdout `[telemetry]` block is unchanged; the JSON is additive.
- Exit code semantics unchanged.
- A run that dies before the render (compile error in the orchestrator,
  signal) may leave no file — consumers treat absence as "run did not
  complete," which is why atomic rename matters (never a half-written
  file).

## What's NOT being asked

- No JUnit XML aggregation (that's the separate ◐ "structured XML
  reports" roadmap line; this is aeb-native JSON, one file per run).
- No streaming/NDJSON progress events (a future ask if the daemon wants
  live per-target status; end-of-run is enough for v1).
- No schema ceremony beyond the `"version": 1` field.
- No CI detection / CI-specific behaviour — aeb stays CI-agnostic; this
  is a renderer over records aeb already keeps.

## Acceptance criteria

- Flag + env var both work; absent → byte-identical behaviour to today.
- Parallel (`make -jN`) and sequential driver paths produce the same
  document for the same build.
- Per-target rows agree with the stdout `[telemetry]` block (same
  labels, same counts) for a build containing: a cache-hit target, a
  failing aeocha test target (e.g. `2/3 FAIL` granularity preserved),
  and a hand-rolled exit-code-only test target.
- File is written atomically; a killed run never leaves a partial file.
- `tests/` unit coverage for the JSON assembly (pure string-builder,
  per house style) + one end-to-end smoke.

## Status — delivered

Shipped in `1e94b1f` (the renderer + flag/env plumbing) and validated
by the acceptance harness in `tests/telemetry-json-smoke/` (a three-
target fixture: a cache-hit `aether.program`, a failing aeocha
`driver_test` → `2/3 FAIL`, and a hand-rolled exit-code-only
`program_test`). Building that harness surfaced two defects the
follow-up commit fixed:

1. **`rc` disagreed with `status` for a failed test.** A test node
   whose process exits 0 but whose aeocha report shows failures was
   recorded `status:"fail"` with `rc:0`. Now both driver paths derive
   `rc` from the logical outcome (fail → `rc:1`), so a row never reads
   `fail`/`rc:0`.
2. **Exit-code-mapped targets emitted a fake `tests` object.** A
   passing `program_test` reported `tests:{total:1,passed:1,…}` even
   though the `1/0` was synthesised from the exit code, not a per-test
   report. The ask calls for `tests:null` there ("exit-code-mapped
   targets report `rc` only"). A `report=` line on the
   `.aeb_test_result` marker now distinguishes genuine per-test counts
   (aeocha, junit5, pytest, …) from exit-code-synthesised ones; the
   renderer emits `tests:null` for the latter.

The smoke asserts both driver paths produce byte-identical documents
(modulo `duration_ms`) and all per-target rows. Run it directly:
`tests/telemetry-json-smoke/run-smoke.sh` (not part of `tests/run.sh`,
which is string-builder units with no toolchain build). Unit coverage
for the exit-code `tests:null` gating is in
`tests/test_telemetry_render.ae`.
