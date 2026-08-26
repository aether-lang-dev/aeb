# Windows / MSYS2 / MinGW — current state and what is left

**As of:** 2026-08-11, aeb `ae57442`, aether **0.516.0**, winbaz (Windows 11,
MSYS2 MINGW64, gcc 16.1.0).

**Not committed deliberately** — this is a working note, not a repo artefact.

---

## Where we are

| | Before this run | Now |
|---|---|---|
| Linux suite | 117/117 | **118/118** |
| Windows suite | 94/118 | **105/118** |
| Windows *build* failures | 10 | **0** |
| Windows end-to-end build of a target | impossible | **works** |
| aether-ui cold fan-out (79 targets, Linux) | — | exit 0, no failures |

13 Windows run-failures remain. Nothing is a regression: the pre-session
baseline measured 94/118, and 10 of those were build failures that no longer
exist.

---

## THE ONE LAW BEHIND ALL OF IT

Everything below is a consequence of a single fact, measured on the box:

```
fs.exists ("/c/Users/paul/scm/aether/build/libaether.a")  -> 0
fs.exists ("C:/Users/paul/scm/aether/build/libaether.a")  -> 1
dir.exists("/c/Users/paul/scm/aether/runtime")            -> 0
dir.exists("C:/Users/paul/scm/aether/runtime")            -> 1
```

`std.fs` / `std.dir` / `std.file` are **native Win32 calls**. An MSYS `/c/...`
path is a fiction the MSYS layer maintains for its own processes; a native stat
sees no such file and answers **"does not exist"** for every one of them.

**Why it hid for weeks:** `sh` accepts *both* forms, so any command line built
out of POSIX paths still *runs*. Only aeb's own `exists`-style probes lied — and
each one failed by silently choosing a fallback rather than erroring. Nothing
said "a path was dropped."

### The second law (same family, different layer)

`os.exec` routes through **cmd.exe** on Windows, which honours neither POSIX
single quotes nor `2>/dev/null`. Measured:

```
os.exec("cygpath -m '${d}' 2>/dev/null")  -> ""     (silently)
os.exec("cygpath -m ${d}")                -> C:/msys64/tmp/tmp.EMYjIYQ0Qh

os.exec("cd '/tmp' && echo OK")           -> ""     (silently)
os.exec("cd /tmp && echo OK")             -> OK
```

The tell in the output is a cmd.exe line: `The system cannot find the path
specified.` It is easy to dismiss as noise. It is not noise.

`lib/build`'s `_sh` / `_sh_capture` chokepoint exists precisely to avoid this —
it writes the command to a temp `.sh` and runs `sh <file>`, so cmd.exe never
parses contents. **Anything calling raw `os.exec`/`os.system` bypasses that
protection.**

---

## Steps of elimination on winbaz (what was ruled OUT, and how)

Recording the dead ends, because three of them were confidently reported as
causes and were wrong.

1. **"The orchestrator is written to `target/target/`."**
   RULED OUT by argument, before touching the box: `build_dir` and `out_bin` are
   composed from the same `root` two lines apart, so a bad root would nest
   *both*. It cannot produce a correct Makefile path *and* a deep binary. The
   `target/target/` dir was a stale artefact dated Aug 4.

2. **"The gcc line carries no `-lcrypto`."**
   Half right. The flags *were* on the line — appended after `-o`, which is why
   a truncated paste looked like they were missing. The real defect was that
   `pkg-config --libs zlib openssl` is **all-or-nothing**: one missing `.pc`
   prints nothing and exits 1, taking the other module's flags with it. Fixed by
   querying per module (`d55f064`), then by resolving in aeb rather than emitting
   `$(...)` for a shell that may not be POSIX (`67a5db1`).

3. **"The temp-script write fails because `/tmp` is not natively resolvable."**
   **WRONG — my theory, disproved on the box.** `io.write_file("/tmp/x")`
   *succeeds*, and MSYS keeps `TMP=/tmp` populated even across an explicit
   `env -u TMP`, so that branch never fires there. Corrected in `8533298`; the
   code was kept as defensive-only with an honesty note.

4. **"`_gcc_stderr.log` is never created, so `ae build` must be doing the link."**
   RULED OUT: routing cannot differ by OS. `no_closure_regen()` + `ui_backend()`
   make `_has_manual_overrides` true on every platform, forcing
   `_compile_and_link`. Verified on Linux: one `gcc -O2`, zero `ae build`.

5. **"`AEB_SH_TRACE=1` produces zero traces, so `_sh` is never called."**
   PARTLY an artefact: per-node work runs in a **child** whose output the driver
   redirects to `target/.aeb/logs/<label>.log`, not the parent's stdout. But the
   parent genuinely emitted zero too — because the binary under test predated the
   instrumentation (see 6).

6. **THE PROCESS BUG THAT COST THE MOST: `install.sh` does not build your tree.**
   It downloads a tarball for `$REF` and builds *that*. Afterwards both look
   identical, because the banner says `installed <today>` — which reads as "my
   changes are in" when it means "a fresh install of released code." **Three
   consecutive Windows reports were measured against a binary predating the fix
   under test**, including one that "disproved" a hypothesis that was correct.
   `a0fd182` added a warning when it is run from inside a checkout.
   The reliable check is content, not banner:
   ```sh
   strings ~/.local/share/aeb/aeb | grep -c "cannot write temp script"
   ```

7. **Two different machines were being measured.**
   A plain `ssh winbaz` lands in **Git-Bash** (`/` = `C:\Program Files\Git\`),
   which has **no gcc, no pkg-config, no make**. The MSYS2 world is under
   `C:\msys64` with 183 `.pc` files and gcc 16.1.0. The incantation that reaches
   the real environment:
   ```sh
   ssh winbaz 'MSYSTEM=MINGW64 /c/msys64/usr/bin/bash.exe -l -c "..."'
   ```

8. **`ae`'s own build cache serves stale binaries.**
   Repeatedly reported `Built (cache hit)` and ran old code even with a fresh
   output name. Workaround: `export AETHER_HOME=$(mktemp -d)` before a build
   loop. This masked at least one measurement (FAIL count moved 8→10 for no
   real reason).

---

## What was actually fixed (all verified on winbaz)

| Commit | Fix |
|---|---|
| `d55f064` | pkg-config queried **per module** — one missing `.pc` no longer voids the set |
| `67a5db1` | pkg-config + `find` **resolved in aeb**, not emitted as `$(...)`; **pcre2 added**; `PKG_CONFIG_PATH` seeded with `/mingw64/lib/pkgconfig` → 69 undefined refs → **0** |
| `405105d` | one `--lib` flag per entry, never the `;`-joined `AEB_COMPILE_LIB` (the `;` was splitting the command in two — that is why the repo root ran as a command) |
| `8c63eb3` | `AEB_SH_TRACE=1`, `AEB_SH_KEEP=1`, and a warning when the lossy `sh -c` fallback fires |
| `b1c41fa` | **the big one** — normalise the toolchain dir to native form; teach `_resolve_aether_include` the **dev-tree** layout (`<root>/runtime`, `<root>/std`). Was: 0 `-I` flags → `fatal error: aether_panic.h`. Now: 78 `-I` flags, builds, runs, `[hit]` on re-run |
| `fc39525` | `mktemp` results given native form before reaching `fs.*` — **13 production sites**. Java/Kotlin/Scala/TS/dotnet/Clojure/Groovy caching was silently broken on Windows |
| `ff64a77` | same for the tests' `_mktempdir`, with **cmd.exe-safe** (unquoted) cygpath |
| `ae57442` | `AETHER_PIN`/`AETHER_FETCH` → 0.516.0 |

**Upstream (aether):**
- `fs.read_binary` now names the path and cause instead of `"cannot read file"` (0.506.0) — also fixed a silent-truncation bug where reading a directory returned `("", "")`, i.e. **success with no content**.
- Leading-underscore functions no longer emitted into C's reserved namespace (**0.516.0**, `cf4f2bd5`). `_write` collided with MSVCRT's `_write`; that alone was all **10** Windows build failures.

---

## The remaining 13

```
test_aeb_query_cmd              test_aether_extern_diagnostics
test_aether_no_closure_regen    test_aether_resolvers
test_aether_transitive_regen    test_approval_cmd
test_bash_run                   test_cache_tree_roundtrip
test_extract_deps_prereqs       test_extract_deps_scan
test_javac_cmd                  test_program_binary_contract
test_remote_cache_roundtrip
```

All are `(assertions)` — they compile and run, then produce **empty strings
where content is expected**:

```
FAIL: classpath_file joins file contents
  expected: /m2/x.jar:/m2/y.jar:/m2/z.jar
  actual:                                     <- empty

FAIL: scan: 3 .tests.ae files at varying depths (sorted)
  expected: 'apps/baz/.tests.ae lib/bar/.tests.ae ...'
  actual:   ''                                <- empty
```

**Leading hypothesis, with direct evidence.** `test_extract_deps_scan` builds
its subprocess call as:

```aether
abs_raw, _e1 = os.exec("readlink -f '${extract_bin}'")
raw,    _e2 = os.exec("cd '${workdir}' && '${abs_bin}' '${target}'")
```

and the second form is *measured* to return empty under cmd.exe while the bare
form works. That is law #2 above, in the tests rather than in `lib/`.

**Not yet confirmed for all 13** — two were sampled, both consistent. The others
share the shape (assertion failures, empty actuals) but have not been read
individually. Do not quote "13 = one cause" until each is checked; that is
exactly the sort of claim that has needed retracting twice already.

### Suggested next step

Sweep the test tree for raw `os.exec`/`os.system` carrying single-quoted paths
or `&&`, and either de-quote them or route them through the `_sh` chokepoint.
Then re-measure. If the count does not move, the hypothesis is wrong — measure
before believing it, per the pattern above.

---

## Reproduction recipe (winbaz)

```sh
# The ONLY shell that is the real MSYS2 environment:
ssh winbaz 'MSYSTEM=MINGW64 /c/msys64/usr/bin/bash.exe -l -c "..."'

# Repos on the box
#   aether : /c/Users/paul/scm/aether   (dev tree; build/ae.exe, build/aetherc.exe)
#   aeb    : /c/Users/paul/aeb
#   lab    : /c/Users/paul/claude-lab   (scratch prefix + throwaway project)

# Build aeb from the checkout — NOT install.sh, which fetches a tarball
export PATH=/c/Users/paul/scm/aether/build:$PATH
make install PREFIX=/c/Users/paul/claude-lab/prefix \
             AETHER=/c/Users/paul/scm/aether/build/ae.exe

# Run the suite
AETHER=/c/Users/paul/scm/aether/build/ae.exe ./tests/run.sh

# Force a genuine rebuild when `ae` claims "Built (cache hit)"
export AETHER_HOME=$(mktemp -d)
```

**Gotchas that will bite again**
- `scp` resolves through Git-Bash, so use a Windows-form destination:
  `scp file 'winbaz:C:/Users/paul/claude-lab/file'`.
- Heredocs with `${...}` get mangled through the ssh + bash + MSYS layers.
  Write the probe locally, `scp` it, then run it.
- Per-node build output is in `target/.aeb/logs/<label>.log`, **not** stdout.
- `make` is absent from Git-Bash but present in MSYS2 — a "no make" result
  usually means the wrong shell, not a missing package.
