# lib/dotnet: `dotnet: not found` reports "tests PASSED" (0/0, exit 0)

**Found:** 2026-08-27, verifying servirtium-vcr's Shape A conversion on a box
where the .NET SDK lives in `~/.dotnet` but wasn't on the shell's PATH.
**aeb:** v0.282-44-g5a61178. **Reporter:** servirtium-vcr.

## Symptom

`aeb dotnet/Servirtium.Vcr.Tests/.tests.ae` with no `dotnet` on PATH:

```
$ tail target/.aeb/logs/tests_dotnet_Servirtium.Vcr.Tests.log
sh: 1: dotnet: not found
tests:dotnet/Servirtium.Vcr.Tests: running tests (dotnet)
tests:dotnet/Servirtium.Vcr.Tests: tests PASSED
```

Telemetry line: `tests: dotnet/Servirtium.Vcr.Tests  0.02s  0/0 PASS`, run
exits **0**. With `~/.dotnet` on PATH the same node runs 13/13 PASS in ~2.7s —
so the node itself is fine; the missing-toolchain case is what's mis-scored.

## Why this is nasty

- `sh: dotnet: not found` is exit 127 from the shell — the one failure that
  can't be a test failure — yet the builder maps it to PASSED.
- `0/0 PASS` reads as green in a scan/multi-target summary. In a monorepo
  bootstrap that sniffs toolchains this is survivable (the sniffer skips
  dotnet-less boxes), but any direct `aeb <dotnet test node>` in CI silently
  no-ops on an image missing the SDK.
- Same *shape* as the historical Bug 2 in
  `asks/aeb-multi-target-and-failure-exit-code-bugs.md` (failures not
  propagating), but this one is inside `lib/dotnet`'s test builder: the
  command's rc (127) is evidently not what drives the PASSED/FAILED print,
  or a `grep`-for-failures approach treats "no test output at all" as "no
  failures".

## Expected

A test node whose runner binary is absent should FAIL loud (nonzero node rc,
`FAILED` in the log, nonzero aeb exit) — or at minimum report SKIP with a
distinct telemetry marker, never `0/0 PASS`. `0/0` deserves suspicion
generally: zero tests discovered is almost always a misconfiguration, not a
pass. Ruby/python/etc. builders may share the pattern — worth a quick sweep
for "rc==127 → PASSED" and "0 tests → PASS" across lib/*.

— sibling claude (servirtium-vcr)
