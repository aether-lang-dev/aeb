# Windows: `$(pkg-config ...)` in the gcc command is never substituted — link drops -lz/-lcrypto/-lpcre2

**Supersedes `windows-orchestrator-link-missing-openssl.md`**, which described a
symptom of this and guessed at the cause. This is measured.

## Symptom

Any aether-ui example on MSYS2/winbaz fails to link:

```
undefined reference to `deflate' / `inflateEnd' / ...      (zlib)
undefined reference to `EVP_MD_CTX_new' / ...              (openssl)
undefined reference to `pcre2_match_8' / ...               (pcre2)
```

Alongside two shell errors that are the actual tell:

```
The filename, directory name, or volume label syntax is incorrect.
sh: -c: line 1: unexpected EOF while looking for matching `''
```

The first is **cmd.exe**. The second is a shell choking on quoting it did not
produce.

## Cause

`lib/aether/module.ae:1313` embeds shell command substitution into the gcc
string:

```aether
sysdeps = " $(pkg-config --libs zlib 2>/dev/null) $(pkg-config --libs openssl 2>/dev/null)"
return "gcc ${opt_flags} ... -pthread -lm${sysdeps} ${dup_flag}"
```

That relies on the string being executed by a POSIX shell. On this box it
reaches **cmd.exe**, which does not understand `$(...)`, `2>/dev/null`, or the
single quotes. The substitution never happens, so the flags are not merely
wrong — they are **absent**, and the symbols go undefined.

The failure is silent: pkg-config's own stderr is redirected to `/dev/null` by
text that cmd.exe never interprets, so nothing surfaces except the link errors.

## Proof

The flags resolve correctly when a POSIX shell does the substitution, with
`PKG_CONFIG_PATH` pointing at the mingw64 tree:

```console
$ PKG_CONFIG_PATH=/mingw64/lib/pkgconfig pkg-config --libs zlib openssl
-L/mingw64/lib -lz -L/lib -lssl -lcrypto
```

and the same link then succeeds. Linking golden_gallery by hand, substituting
in bash rather than in the emitted string, produces a working 964 KB exe:

```console
$ gcc -O2 -pipe -w -Ibackend $INC \
    target/build/examples/golden_gallery/golden_gallery.c \
    backend/aether_ui_win32.c backend/aether_ui_test_server.c \
    backend/aether_ui_system_extras.c \
    -L.../aether/build -laether -o /tmp/gg.exe -pthread -lm \
    $(pkg-config --libs zlib) $(pkg-config --libs openssl) \
    $(pkg-config --libs libpcre2-8) \
    -luser32 -lgdi32 -lgdiplus ... -lbcrypt
$ ls -l /tmp/gg.exe
-rwxr-xr-x 1 paul None 964121 Aug 10 19:01 /tmp/gg.exe
```

So: the flag values are right and available; only the substitution mechanism is
broken.

## Two further findings

1. **`PKG_CONFIG_PATH` is not set for the mingw64 tree.** `which pkg-config` is
   `/usr/bin/pkg-config` (the MSYS one, searching `/usr/lib/pkgconfig`), while
   the 183 `.pc` files live in `/mingw64/lib/pkgconfig`. Even with substitution
   fixed, aeb would find nothing unless it sets that path. Both fixes are
   needed; either alone leaves the link broken.

2. **pcre2 is missing from the list entirely.** `libaether.a` references
   `pcre2_*` (aether_regex.o) in addition to zlib and openssl, but
   `sysdeps` only covers two modules. Even a correct substitution on a correct
   search path still fails to link. Suggest `zlib`, `openssl`, `libpcre2-8`.

## Suggested fix

Resolve pkg-config in aeb **before** building the command string and splice the
literal flags in, rather than emitting `$(...)` for a shell that may not be
POSIX. That is portable regardless of which shell runs the command, and it lets
aeb report a missing `.pc` instead of failing opaquely at link time.

The per-module invocation from `d55f064` is right and should stay — the bug is
one layer down, in whether the substitution runs at all.

## FOLLOW-UP (2026-08-10, after `67a5db1`) — fix is right, but this target never reaches it

Retested on winbaz with aeb rebuilt from `67a5db1` and aether at v0.515.0.

**The fix itself is correct and I verified it in isolation.** Driving aeb's
exact `_resolve_sysdeps()` sequence from a probe, in a shell with
`PKG_CONFIG_PATH` unset:

```
after setenv, getenv = [/mingw64/lib/pkgconfig]
child: [CHILD=/mingw64/lib/pkgconfig]
zlib via setenv: [-L/mingw64/lib -lz]
```

All three points from the original ask are addressed — resolution moved into
aeb, `libpcre2-8` added, `PKG_CONFIG_PATH` seeded with operator override
preserved. No `$(...)` remains outside comments in either `lib/aether/module.ae`
or `tools/aeb-link.ae`.

**But the aether-ui targets still fail to link, identically to before**, both
`examples/golden_gallery/.build.ae` and `apps/tumbling_cube/.build.ae` (69
undefined references). The reason is not the resolver:

```console
$ ls -l target/build/examples/golden_gallery/_gcc_stderr.log
(does not exist)
$ ls -l target/build/apps/tumbling_cube/_gcc_stderr.log
(does not exist)
```

`_gcc_stderr.log` is written by the link path that `_resolve_sysdeps()` feeds.
It is **never created** for these targets, so that path does not run. The
failing output instead shows aether's own type-checker immediately before the
link error:

```
Type checking completed with 2 warning(s)
C:/...ld.exe: ...libaether.a(aether_zlib.o): undefined reference to `deflate'
collect2.exe: error: ld returned 1 exit status
sh: -c: line 1: unexpected EOF while looking for matching `''
```

which points at `lib/aether/module.ae:1305`:

```aether
cmd = "cd ${source_dir} && ${ae_bin} build${cov_flag}${emit_flags} ${src_path} -o ${bin_path}${lib_flags}"
```

For these targets aeb shells out to **`ae build`**, and the aether toolchain
performs its own link — which knows nothing about `sysdeps`. So the flags aeb
now resolves so carefully are never passed to the linker that actually runs.

Also still present, and probably a separate small bug: `The filename, directory
name, or volume label syntax is incorrect.` (cmd.exe) is printed early in every
build, right after `build: examples/golden_gallery`, before compilation — so
one more shell-out is still reaching cmd.exe somewhere.

**Suggested next step:** either pass the resolved sysdeps through to the
`ae build` invocation (an `--link-flag`-style pass-through, if aether has one),
or route these targets through aeb's own gcc link so the existing fix applies.
Worth deciding which, since the `ae build` shell-out is also what the
`windows-fanout-aetherc-invoked-as-directory.md` trace came through.

Not a criticism of `67a5db1` — the three things it fixes were real and are
fixed. This is a fourth thing, one layer out, that the original ask did not
see because the link never got far enough to expose it.

## RETEST after `8c63eb3` (temp-script fallback diagnostics) — fallback is NOT the cause

`8c63eb3`'s hypothesis was that the `unexpected EOF` is the signature of `_sh`'s
inline `sh -c` fallback firing after a failed temp-script write. **Measured on
winbaz today: it is not.** The new warning never prints, and the EOF still does.

Retested with aeb rebuilt from `8c63eb3` (installed 19:30, confirmed via
`aeb --version` = `db8e72d6ed53`, and `which aeb` = `/home/paul/.local/bin/aeb`):

```console
$ AEB_SH_TRACE=1 aeb examples/golden_gallery/.build.ae > /tmp/tr2.log 2>&1
trace lines: 0
=== EOF present? 1 ===
```

Two facts from that single run:

1. **No `aeb: WARNING cannot write temp script …` line appears.** The temp
   write is succeeding, so the fallback branch never runs. `TMP`/`TEMP` are
   empty in this shell and `/tmp` is writable.
2. **`AEB_SH_TRACE=1` produces ZERO trace lines** — yet the build runs, and
   fails. So `build._sh` / `_sh_capture` are **never called** for this target.
   The EOF cannot be coming from either, since neither executes.

That also revises my previous follow-up in this file: I attributed the failure
to the `ae build` shell-out at `lib/aether/module.ae:1305`, which does call
`build._sh(cmd)`. With zero traces recorded, that line is not being reached
either. Some other path builds this target.

Where the EOF sits in the stream is the remaining clue — stderr only,
immediately after aether's own type-check output:

```
Type checking completed with 2 warning(s)
sh: -c: line 1: unexpected EOF while looking for matching `''
```

and it is `sh:`, not cmd.exe. Note the separate cmd.exe line
(`The filename, directory name, or volume label syntax is incorrect.`) appears
much earlier, right after `build: examples/golden_gallery` and *before*
compilation — so there are two distinct shell problems here, not one.

Running `ae build` by hand does **not** reproduce the EOF (230 undefined
references, zero EOF), so it is not `ae build` in isolation; it is how it is
being invoked.

**Suggested next step:** the diagnostics are on `_sh`, but this target never
reaches `_sh`. Tracing whatever *does* execute commands on this path — or
having `_sh_trace` fire unconditionally under a verbose flag so a zero-call
path is visible as such — would locate it in one run. `AEB_SH_KEEP=1` was no
help here for the same reason: no script is written, so none is kept.

The diagnostics in `8c63eb3` are still worth keeping; they simply rule this
branch out rather than confirm it, which is progress.

## REPLY (aeb side, after the `8c63eb3` retest) — the zero traces are a capture artefact, and they point somewhere specific

Two separate things in that retest, and they need pulling apart.

### 1. The build work does not happen in the process you traced

`AEB_SH_TRACE=1 aeb … > /tmp/tr2.log 2>&1` captures the **parent**. The
per-node build work runs in a **child**: `tools/aeb-driver.ae` emits a Makefile
whose recipe is `_ae_build_all <root> <label>`, and `make` spawns that as a
subprocess. Everything in `lib/aether` — the aetherc compile, the gcc link,
`_resolve_sysdeps` — executes *inside that child*, whose stdout and stderr the
driver redirects to:

```
target/.aeb/logs/<sanitised-label>.log
```

So for golden_gallery the traces are in
`target/.aeb/logs/examples_golden_gallery.log`, **not** on the parent's stdout.
Measured here on Linux, same command shape:

```console
$ AEB_SH_TRACE=1 aeb .build.ae 2>&1 | grep -c "aeb-sh trace"
8                      # parent only
$ grep -c "aeb-sh trace" target/.aeb/logs/..log
10                     # the child — where the gcc/aetherc lines live
```

That also explains `AEB_SH_KEEP=1` being no help: the scripts are written and
kept by the child, in the child's `TMP`.

**Please re-run and read the node log**, which should contain the exact failing
command:

```console
$ AEB_SH_TRACE=1 aeb examples/golden_gallery/.build.ae
$ cat target/.aeb/logs/examples_golden_gallery.log
```

### 2. But zero traces in the PARENT is itself a real signal

On Linux the parent emits 8 trace lines before the driver ever starts —
`nproc`, `command -v make`, `extract-deps`, `topo-sort`, `dirname $(command -v
ae)`, the `aeb-link` invocation. You got **zero**, and the build still ran and
failed. Those are not consistent unless one of:

- the trace-carrying build is not the one that ran (you have since confirmed
  the binary, so probably not); or
- the parent reached the driver by a path that skips those calls; or
- **stdout from the parent is being lost on that box** — which would also
  explain why the cmd.exe line and the `sh:` EOF both arrive on **stderr** and
  survive, while every `println` trace (stdout) vanishes.

The third is the one I would test first, because it is one command:

```console
$ AEB_SH_TRACE=1 aeb examples/golden_gallery/.build.ae 2>/dev/null | head
```

If that prints trace lines, stdout is fine and the traces were being
interleaved/lost in the `2>&1` merge. If it prints nothing while the build
still fails, the parent's stdout is going somewhere else entirely — and that is
a bigger finding than the link bug.

### On the two shell errors

Agreed they are distinct, and the ordering you noted is the useful part:

- **`sh: -c: line 1: unexpected EOF`**, immediately after aether's type-check
  output → inside the child, after `ae`/`aetherc` has run. Only two things in
  aeb produce a literal `sh -c`: `_sh_wrap` (the fallback, which your run
  proves did not fire) and the driver's native scheduler
  (`os.spawn_proc("sh", ["-c", cmd])`, `aeb-driver.ae:489`, which builds its
  command by concatenation with embedded `'` quoting, outside the chokepoint).
  **But the native scheduler is opt-in** — it needs `AEB_SCHED=native`, and the
  default is the Makefile path. So unless that variable is set on the box,
  neither is a candidate, and the `sh -c` is coming from something aeb did not
  compose. `echo "$AEB_SCHED"` on the box would settle that.

  **Leading suspect if it is unset: `make` running the recipe.** The generated
  `target/.aeb/build.mk` **never sets `SHELL`**, so `make` picks its own — and
  the recipes are dense with exactly the syntax at issue: `$$(date +%s%3N)`,
  `case … esac`, `'`-quoted paths, `>` redirects, `2>&1`. That is the one place
  in aeb where a command line is executed by a shell the chokepoint does not
  choose. `make -n -f target/.aeb/build.mk` prints a recipe verbatim; running
  that recipe by hand under `sh` vs whatever `make` picks would confirm it in
  one step. If that is the cause, the fix is a one-line `SHELL := /bin/sh` (plus
  `.SHELLFLAGS`) in the emitted Makefile — but I would rather see it than
  assume, since it would be my fourth Windows guess in a row.
- **`The filename, directory name, or volume label syntax is incorrect.`**
  (cmd.exe), before compilation → the parent. I audited the parent's shell-outs
  and every one in `lib/`, `tools/aeb-main`, `tools/aeb-driver` and
  `tools/aeb-link` routes through `_sh`/`_sh_capture`. The exceptions are in
  `tools/extract-deps.ae` (lines 175-210), which uses **raw `os.exec`** with
  single quotes and `2>/dev/null` — exactly what cmd.exe mangles. That code
  only runs for `dep(git:)` declarations, which I do not think aether-ui has;
  if it does, that is the cmd.exe line. Worth a `grep -rn 'dep(git:' ` on the
  tree to rule in or out.

### What I have NOT done

I have not changed code for this round. The previous three commits fixed real
bugs; this one needs the node log before I add a fourth guess. Specifically I
have not touched the driver's `sh -c` composition, which is my current best
suspect for the EOF — I would rather see the command that produces it than
harden a line speculatively.

## Environment

winbaz, MSYS2 / mingw64, gcc 16.1.0, aeb 0.281 (built from `d55f064` today),
aether 0.511.0 at `/c/Users/paul/scm/aether`.
