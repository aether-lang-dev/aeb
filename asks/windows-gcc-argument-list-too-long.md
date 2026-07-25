# Windows: `gcc: Argument list too long` blocks every aeb build

**Filed by**: Paul + LLM session, 2026-07-25, from a winbaz run that set
out to verify something else (whether the multi-node parallel path works
under MSYS `make` — it does; see below).
**Status**: **OPEN — real blocker, not yet fixed.**
**Severity**: high for the Windows cut-down runner. No aeb build
completes on native Windows today, regardless of project size.

## Symptom

On `winbaz` (Win11 VM, MSYS2, GNU Make 4.4.1, gcc 16.1.0, `ae 0.413.0`
reporting `windows-x86_64`), any `aeb <target>` fails at the link step:

```
C:/msys64/tmp/_aeb_link_3640_1758918480.sh: line 1: /mingw64/bin/gcc: Argument list too long
C:/msys64/tmp/_aeb_sh_6784_712472023.sh: line 1: .../target/_ae_build_all.exe: No such file or directory
  tests: tests:a — FAILED
```

`target/_ae_build_all.exe` is never produced, so every node then fails
looking for it. The `[telemetry]` block still renders and the summary
still classifies correctly — the failure is confined to link.

## It is not the parallel/Makefile path

This turned up while verifying
`docs/windows-cross-platform-notes.md` § 4, so the scheduling layer was
ruled out directly:

- **Reproduces with `AEB_JOBS=1`**, where the driver writes no Makefile
  and never invokes `make`.
- **Reproduces on a single node with 2 generated `.c` files.** Not a
  large-project scaling limit — the minimum viable build hits it.

So it is `tools/aeb-link`'s gcc invocation, independent of how nodes are
scheduled.

## Cause

`aeb-link` assembles **one** `gcc` command containing every generated
`.c` file for the node plus the include/lib flags
(`-I`, `-L`, `-l…`, `-Wl,--allow-multiple-definition`), and runs it
through the `build._sh` chokepoint, which on Windows writes it to a temp
script and runs it under MSYS `sh`.

The ceiling is Windows', not `sh`'s: `CreateProcess` caps a command line
at roughly 32 KB, where POSIX `ARG_MAX` is ~2 MB. Absolute Windows paths
are long (`C:/Users/paul/winmake-test/target/_aeb/a__D_tests_D_ae.c`),
and aeb passes absolute paths throughout — so a command line that is
unremarkable on Linux blows the Windows limit almost immediately.

That it fires with only two `.c` files suggests the flag/lib portion of
the line is doing most of the damage, not the file list. Worth measuring
before designing the fix.

## Fix shapes (not chosen)

1. **gcc `@response-file`.** Write the arguments to a file and invoke
   `gcc @args.rsp`. This is the standard Windows answer, gcc supports it
   natively, and it is a contained change at the one place that builds
   the command. Most likely correct.
2. **Split compile from link.** Compile each `.c` to `.o` separately
   (short commands), then link the objects — possibly still needing (1)
   if the object list itself is long.
3. **Shorten the paths.** Emit relative paths, or `cd` into
   `target/_aeb` first. Reduces the constant factor without removing the
   ceiling; a mitigation, not a fix.

Whichever is chosen should be Windows-gated or, if harmless, applied
everywhere — a response file works fine on POSIX too, and keeping one
code path is worth more than saving a temp file.

## Acceptance

- `aeb a/.tests.ae` completes on winbaz and produces
  `target/_ae_build_all.exe`;
- the two-node DAG fixture (`.presubmit.ae` → `a` + `b`) builds green in
  BOTH modes: default (`make -jN`) and `AEB_JOBS=1`;
- Linux behaviour is unchanged (`./tests/run.sh` still 115/115, and a
  `/tmp/aeb-*-smoke` run still passes).

## What this run DID verify

Worth recording, because it was the original question and the answer is
positive: the driver's Makefile path works correctly on native Windows.
`command -v make` found MSYS `/usr/bin/make`; `build.mk` was emitted with
correct topology; recipes carried native paths and the `.exe` suffix;
`make` ran them and `sh` interpreted the POSIX bodies with no `cmd.exe`
involvement; `.rc` markers and telemetry came back; `AEB_JOBS=1` correctly
skipped the Makefile entirely. See
`docs/windows-cross-platform-notes.md` § 4.

## Related

- `docs/windows-cross-platform-notes.md` § 4 — the scheduling-layer
  verification this run produced.
- `TODO.md` § "Windows support (cut-down runner)" — the umbrella effort.
- `LLM.md` § "Known upstream Aether issues affecting aeb" — the macOS
  duplicate-symbol note is the other place where `aeb-link`'s single-gcc
  design meets a platform limit.
