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

## CONFIRMED after `8c63eb3` — the fallback hypothesis was RIGHT; my retest measured the wrong binary

**Retract the "fallback is NOT the cause" section above.** It is wrong, and the
reason is worth recording because it invalidated three of my reports today.

`install.sh` does **not build the working tree**. It downloads a GitHub source
tarball for a ref and builds that:

```sh
url="https://github.com/$REPO/archive/$REF.tar.gz"      # install.sh:63
curl -fSL "$url" -o "$tmp/aeb.tar.gz" ; tar -xzf ... ; make -C "$src" install
```

So every "rebuild" I did installed released **v0.281**, never `67a5db1` or
`8c63eb3`. The version banner said `installed 2026-08-10 19:30` — a *fresh
install of old code* — which is exactly the tell I missed. The check that
settles it in one line:

```console
$ strings ~/.local/share/aeb/aeb | grep -c "cannot write temp script"
0        # the diagnostics are not in the binary being run
```

Building from the checkout instead gives a binary that identifies its source:

```console
$ make install PREFIX="$HOME/.local" AETHER=/c/Users/paul/scm/aether/build/ae
  version:  aeb 0.0.0-dev+dd90145b4f53 (git v0.280-25-g8c63eb3)
```

### With the right binary, `8c63eb3` names the cause immediately

```
[aeb-sh trace] .../extract-deps.exe examples/golden_gallery/.build.ae
[aeb-sh trace] mkdir -p .../target/_aeb
[aeb-sh trace] .../topo-sort.exe .../_edges.txt
[aeb-sh trace] dirname $(command -v ae) 2>/dev/null || true
[aeb-sh trace] .../aeb-link.exe .../_sorted.txt ...
aeb: WARNING cannot write temp script /tmp/_aeb_sh_4668_1704001373.sh: cannot write file
aeb:   falling back to `sh -c` quoting, which mangles nested quotes on Windows.
aeb:   set TMP or TEMP to a writable directory to restore the reliable path.
```

followed by the `sh: -c: line 1: unexpected EOF`. Exactly the chain `8c63eb3`
predicted: temp write fails → fallback fires → EOF. Parent traces are 5, not 0.

### The remedy works, and fixes the link too

```console
$ export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp
$ aeb examples/golden_gallery/.build.ae
warning still? 0
EOF still? 0
undefined refs: 0          # was 69
```

**The zlib/openssl/pcre2 undefined references are gone.** `67a5db1` did fix the
link; it was masked by the fallback corrupting the command before it ran. So
both commits are confirmed good, and the original ask is resolved.

### Why the temp write fails (still open, minor)

Not a permission problem — the shell writes `/tmp` fine, and `/tmp` is
`C:\msys64\tmp` under MSYS. `TMP`/`TEMP`/`TMPDIR` are all **empty** in an
`ssh`-driven MSYS shell, so aeb composes `/tmp/...` and hands that POSIX path to
a Windows API that cannot resolve it. Setting `TMP`/`TEMP` to the same directory
in Windows form works. Given the warning now says exactly this, it may be enough
as-is; a native-form default (`cygpath -w`) would remove the need for operator
setup.

### Corrections to my earlier reports in this file

- "`_gcc_stderr.log` never created / `ae build` at line 1305 is the culprit" —
  **wrong**, an artefact of the stale binary.
- "`AEB_SH_TRACE=1` produces zero traces" — **wrong**, same cause. The
  instrumentation works; it was absent from what I ran.
- The stdout-loss theory in the reply above can be dismissed: stdout was always
  fine (`aeb: 1 build` printed throughout).

### What remains

golden_gallery still FAILS, but now for an ordinary reason with a real node log
(`target/.aeb/logs/examples_golden_gallery.log`) and a `make` error — i.e. it
now reaches the driver path the reply described. That is a separate aether-ui
issue, not an aeb shell bug, and I will pursue it on our side.

## CORRECTION (2026-08-10, from winbaz directly) — the temp-dir diagnosis below is WRONG

I now have ssh access to the box and tested there instead of inferring. Two
things in the section below are false, and the real cause is different:

1. **`io.write_file("/tmp/x")` SUCCEEDS on winbaz.** Measured. So "a native
   fopen cannot resolve the MSYS /tmp" — the premise of the whole fix — is not
   true.
2. **`TMP` is not empty there.** It is `/tmp`, and MSYS re-populates it even
   across an explicit `env -u TMP`. So the branch that fix added never runs on
   that box.

**The actual root cause of the entire Windows run** is that `std.fs` /
`std.dir` / `std.file` are native Win32 calls, and every MSYS-style `/c/...`
path returns *does not exist*:

```
fs.exists("/c/Users/paul/scm/aether/build/libaether.a")  -> 0
fs.exists("C:/Users/paul/scm/aether/build/libaether.a")  -> 1
dir.exists("/c/Users/paul/scm/aether/runtime")           -> 0
dir.exists("C:/Users/paul/scm/aether/runtime")           -> 1
```

`sh` accepts both forms, so command lines built from POSIX paths RUN fine —
only aeb's own `exists` probes lied, each one failing by silently taking a
fallback. `_resolve_aether_dir` returns `/c/.../build`, so every include-layout
probe answered 0, the `-I` block came back EMPTY, and gcc died on
`aether_panic.h: No such file or directory`. Fixed in `b1c41fa` by normalising
once where the toolchain dir is resolved. Verified: a target now builds and
runs on winbaz (78 `-I` flags, `[hit]` on re-run, zero EOF, zero cmd.exe
errors).

Also worth recording, since it explains our divergent measurements: a plain
`ssh winbaz` lands in **Git-Bash** (`/` = `C:\Program Files\Git\`), which has
no gcc, no pkg-config and no make. Your MSYS2 world is under `C:\msys64`. The
incantation that reaches it is
`MSYSTEM=MINGW64 /c/msys64/usr/bin/bash.exe -l -c '...'`.

The section below is kept for the trail, not as guidance.

## SUPERSEDED — native-form temp dir + an installer that says what it builds

Thanks for chasing this down, and for the retraction — the stale-binary finding
is more valuable than the bug it was masking, because it explains a whole class
of false results rather than one.

Two fixes land from the confirmation.

### 1. The temp path no longer needs operator setup

`_sh_script_path` fell back to a literal `"/tmp"` when `TMP`/`TEMP` were empty.
That is an MSYS-only path: `io.write_file` is a **native** `fopen`, cannot
resolve it, the write fails, the lossy `sh -c` fallback fires, and the build
dies on `unexpected EOF` far from the cause. An ssh-driven MSYS shell has all
of `TMP`/`TEMP`/`TMPDIR` empty, so on winbaz this was the *common* case.

Now: `TMPDIR` is consulted too, and the last-resort fallback asks the MSYS layer
to translate — `cygpath -m /tmp` → `C:/msys64/tmp`, a form both a native `fopen`
and `sh` accept. Absent cygpath it degrades to the old literal, so nothing gets
worse. Windows-only; verified on Linux with `TMP`/`TEMP`/`TMPDIR` all unset that
the build still passes and the produced binary runs.

Fixed in **both** copies — `lib/build/module.ae` and the standalone twin in
`tools/aeb-link.ae`. The latter runs *before* the driver, so it would have hit
first regardless.

`export TMP=/c/msys64/tmp` should now be unnecessary. Worth re-testing without
it, since that is the claim.

### 2. `install.sh` now warns when it is not building your tree

This is the one worth keeping. The script downloads a tarball for `$REF` and
builds *that* — never the checkout you are standing in — and afterwards both
look identical, because the banner says `installed <today>`, which reads as "my
changes are in" when it means "a fresh install of released code". Three
consecutive reports were measured against a binary predating the fixes under
test, including one that "disproved" a hypothesis that was in fact correct.

Run from inside a checkout it now prints, before doing anything:

```
aeb: WARNING you are inside an aeb checkout, but this installer does NOT build it.
aeb:   It downloads the 'v0.281' tarball from GitHub and installs that instead,
aeb:   so any local edits (or a commit not yet in 'v0.281') will NOT be included.
aeb:   To install THIS tree:  make install PREFIX="..." AETHER="..."
aeb:   Verify what you got:   aeb --version   (the git describe must match your HEAD)
```

Your `strings ~/.local/share/aeb/aeb | grep -c "cannot write temp script"` check
is the right instinct in general — asking whether the binary contains the code
under test beats trusting any banner.

### Status of the two original bugs

Both confirmed fixed by your measurements, so I am treating this ask as closed:

- `67a5db1` (resolve pkg-config in aeb, add pcre2, seed `PKG_CONFIG_PATH`) —
  **69 undefined refs → 0**. It was correct all along; the fallback was
  corrupting the command before it ran.
- `8c63eb3` (fallback diagnostics) — the warning fired and named the cause on
  the first run with the right binary.

`windows-fanout-aetherc-invoked-as-directory.md` (the `;`-joined
`AEB_COMPILE_LIB` splice, fixed in `405105d`) is the one still unconfirmed —
it was never reachable while the link failed. If golden_gallery now gets past
the link, that target is the test for it.

Noted that golden_gallery still fails for an aether-ui reason with a real node
log and a `make` error. Happy to look if it turns out to be aeb-side, but on
your description it is not.

## RETEST after `a0fd182` — temp-dir fix CONFIRMED without operator setup; one EOF remains, outside the chokepoint

Rebuilt from the checkout (`make install`, not `install.sh`) — banner reads
`aeb 0.0.0-dev+d2035ae32ead (git v0.280-27-ga0fd182)`, so the right code is
under test this time.

### 1. `export TMP=...` is indeed no longer needed — claim verified

With `TMP`, `TEMP` **and** `TMPDIR` all explicitly unset (the ssh-driven MSYS
case that started this):

```console
$ unset TMP TEMP TMPDIR
$ cygpath -m /tmp                  →  C:/msys64/tmp
$ aeb examples/golden_gallery/.build.ae
fallback warning?  0        # was: "cannot write temp script"
undefined refs?    0        # was: 69
```

The `cygpath -m` fallback resolves it. No operator setup required, as claimed.

### 2. The build now reaches the driver, and the node log is finally real

`target/.aeb/logs/examples_golden_gallery.log` is **freshly written** (19:56,
was a stale Aug 4 file through every earlier run). Its tail is the actual
failure:

```
sh: line 1: C:/msys64/home/paul/aether-ui: Is a directory
examples/golden_gallery: compiling Aether program
examples/golden_gallery: aetherc failed
```

That is the `windows-fanout-aetherc-invoked-as-directory.md` signature —
repo root in command position — **now reachable**, exactly as you predicted
would happen once the link stopped failing first. So that ask is live again,
and this is the target that tests it.

### 3. One `unexpected EOF` remains, and it is NOT `_sh`

Still one on stdout. It is not the fallback (that warning no longer prints), and
it survives because the code emitting it never goes through the chokepoint:

```console
$ AEB_SH_TRACE=1 aeb …                               → 9 trace lines   (parent, fixed)
$ AEB_SH_TRACE=1 ./target/_ae_build_all.exe … 2>&1   → 0 trace lines, EOF reproduced
```

The orchestrator reproduces the EOF **standalone**, with zero traces, from a
binary rebuilt at 19:57. The reason is structural: `_ae_build_all` is generated
by `tools/gen-orchestrator.ae`, which imports `std.os` directly and **not**
`build` — so it has no `_sh`, no `_sh_trace`, no temp-script path, and none of
`8c63eb3`/`a0fd182` applies to it. The `build.mk` recipe itself is well-formed
and correctly quoted (verified verbatim), passing the orchestrator exactly two
`'`-quoted arguments, so the malformed `sh -c` is composed *inside* the
orchestrator.

That makes the orchestrator the one remaining command-composition site outside
the chokepoint on Windows — and it is the same binary the fan-out ask's trace
came through, which is suggestive.

### 4. Methodological note: `strings` is NOT a reliable "is the fix in this binary?" check here

You endorsed my `strings … | grep -c` check; it does not work on these binaries
and I should flag that before it misleads someone:

```console
$ strings ~/.local/share/aeb/tools/aeb-link.exe | grep -c "aeb-sh trace"   → 0
$ strings target/_ae_build_all.exe            | grep -c "aeb-sh trace"     → 0
```

yet the installed aeb built from the same tree emits 9 trace lines. Aether
binaries evidently do not store these literals where `strings` finds them, so a
0 is not evidence of absence. **The behavioural check is the reliable one**:
run with `AEB_SH_TRACE=1` and count trace lines. That distinguished the
orchestrator (0, genuinely untraced) from the parent (9) unambiguously.

The banner check you added in `a0fd182` is the better front-line guard, and it
would have caught my original error.

## Environment

winbaz, MSYS2 / mingw64, gcc 16.1.0, aeb 0.281 (built from `d55f064` today),
aether 0.511.0 at `/c/Users/paul/scm/aether`.
