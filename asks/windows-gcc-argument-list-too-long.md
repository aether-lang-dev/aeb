# Windows: `gcc: Argument list too long` blocks every aeb build

**Filed by**: Paul + LLM session, 2026-07-25, from a winbaz run that set
out to verify something else (whether the multi-node parallel path works
under MSYS `make` — it does; see below).
**Status**: **FIXED and VERIFIED on winbaz** (2026-07-25, `da9bfff`).
**Severity**: was high — no aeb build completed on native Windows at all,
regardless of project size, with no user-side workaround.

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

## Cause — measured, not guessed

The failing `gcc` invocation was captured on winbaz with a shim that
dumps its own argv:

```
=== ARGC=621 ===
=== TOTAL BYTES=39369 ===
-O2
-pipe
-w
C:/Users/paul/winmake-test/target/_aeb/_orchestrator.c
C:/Users/paul/winmake-test/target/_aeb/a__D_tests_D_ae.c
-IC:/Users/paul/aether/build/..
-IC:/Users/paul/aether/build/../.github
-IC:/Users/paul/aether/build/../.github/scripts
-IC:/Users/paul/aether/build/../asks
-IC:/Users/paul/aether/build/../benchmarks
-IC:/Users/paul/aether/build/../benchmarks/cross-language/scala/project
…
```

**39 KB against a ~32 KB `CreateProcess` ceiling** (POSIX `ARG_MAX` is
~2 MB, which is why Linux never notices). Two `.c` files contribute ~130
bytes; **the other 39 KB is `-I` flags.**

The mechanism is `aeb-link.ae`'s include block, which embeds a shell
expansion into the command:

```
$(find <inc_root> -type d -name .git -prune -o -type d -name build -prune \
   -o -type d -print | sed -e s,^,-I,)
```

— one `-I` per directory under the include root. The root comes from
`_resolve_aether_include`, which tries, in order: `$AETHER_INCLUDE`,
`<prefix>/share/aether`, `<prefix>/include/aether`, and finally a
**dev-tree fallback** of `<aether_dir>/..` — the entire Aether *source
tree*.

On winbaz, Aether is a git clone rather than an installed prefix, so the
first three probes miss and the fallback fires:

| Include root | Dirs `-I`'d |
|---|---|
| dev-tree fallback (`aether/build/..`) | **607** — `.github`, `asks`, `benchmarks/…`, everything |
| the actual header trees (`runtime/` + `std/`) | 9 + 81 |

So this is **not** "Windows paths are long" (my first guess) and not the
file list. It is the dev-tree fallback `-I`-ing 600+ directories that
have no headers in them. The code comment at that block already notes
"a dev-tree root holds 600+ dirs" and prunes `.git`/`build` — that
pruning is simply not close to enough.

### No user-side workaround

`AETHER_INCLUDE` does *not* rescue it: the variable sets the *root* that
gets `find`-expanded, not the flag list, so pointing it at the Aether
root produces the same 600-dir expansion. Verified — still
`Argument list too long`. Anyone hitting this on Windows is stuck until
the code changes.

### Why Linux never sees it

Same 39 KB command line, but `ARG_MAX` ~2 MB. Linux dev-tree users have
been carrying a 600-entry `-I` list (a real, if invisible, compile-time
cost) all along.

## Fix shapes (not chosen)

The measurement reorders these from the original filing. Since the bulk
is `-I` flags for directories containing no headers, **stop generating
them** is both the smaller change and the one that helps every platform:

1. **Narrow the dev-tree fallback to the header subtrees.** Instead of
   returning `<aether_dir>/..`, return only the dirs that actually carry
   headers (`runtime/`, `std/`) — 90 dirs instead of 607, and a ~6 KB
   line instead of 39 KB. Fixes Windows *and* removes a real
   compile-time cost Linux dev-tree users have been paying silently.
   Cheapest, most targeted, no new mechanism. **Most likely correct.**
2. **Prune harder, or `-I` only dirs containing a `.h`.** Same idea,
   more general: filter the `find` by header presence rather than
   hardcoding subtree names. Robust to Aether's layout changing;
   slightly slower `find`.
3. **gcc `@response-file`.** Write the args to a file, invoke
   `gcc @args.rsp`. This is the standard Windows answer and raises the
   ceiling regardless of what fills the line — but it *only* raises the
   ceiling. With (1) or (2) done, 39 KB becomes 6 KB and the response
   file is not needed today. Worth doing as **belt-and-braces** for
   genuinely large builds (many modules → long `.c` list), not as the
   primary fix.
4. ~~Shorten the paths~~ — a mitigation of a constant factor. Now clearly
   not worth it on its own.

Recommended: **(1) or (2) now, (3) later if a real build ever needs it.**
Whatever ships should be unconditional, not Windows-gated — the flag
list is wrong on every platform; Windows is just the only one that
refuses to tolerate it.

## Resolution

Shipped as option (1)/(2) combined in `da9bfff`: the include block now
finds `*.h` files and strips to their parent dirs, rather than printing
every directory. Layout-agnostic (no hardcoded `runtime`/`std` names)
and **not Windows-gated** — the old flag list was wrong everywhere;
Linux merely tolerated it under a ~2 MB `ARG_MAX`. The gcc
`@response-file` was NOT needed and was not added.

### Acceptance — all met on winbaz

| Check | Result |
|---|---|
| `aeb a/.tests.ae`, `AEB_JOBS=1` | **exit 0**, `_ae_build_all.exe` BUILT, `1/1 PASS` |
| Two-node DAG, default (`make -jN`) | **exit 0**, `build.mk` emitted, both members ran, `2/2 PASS` |
| Two-node DAG, `AEB_JOBS=1` | **exit 0**, no Makefile, both members ran |
| Linux unchanged | `tests/run.sh` 115/115, `presubmit-smoke` 14/14, smoke green |

Link line, measured with the same gcc shim as the diagnosis:

| | ARGC | Bytes |
|---|---|---|
| before | 621 | **39,369** (over the ~32 KB ceiling) |
| after | 82 | **3,478** |

A 91% reduction, from 7 KB over the ceiling to comfortably under it.

**This is the first aeb build known to complete on native Windows.**

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
