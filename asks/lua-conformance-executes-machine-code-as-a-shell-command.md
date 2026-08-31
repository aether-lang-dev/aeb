# BUG: `lua.conformance` runs a CORRUPTED string as a shell command, and its `env()` never reaches the run

**From:** html-sanitizer (2026-08-31), on aeb `v0.286-55-g3421c1c` / ae 0.613.0.
**Severity: memory corruption.** A previously-green node now fails, and the
first line of its log is machine code being handed to `/bin/sh`.

---

## RESOLVED — root cause was a variable/function NAME COLLISION, not memory corruption or an ae codegen bug. Fixed in `lib/lua/module.ae`.

The corrupt bytes were not a dangling pointer — they were a **function
pointer**, rendered deterministically (they only *looked* random because ASLR
shifts the function's address each process).

`conformance()` used a local variable `run_cmd`:

```aether
run_cmd = "cd '${source_dir}' && ... ${interp} '${conf}'"
run_cmd = string.concat(bldr._env_export_prefix(_builder), run_cmd)
rc = bldr._sh(run_cmd)
```

But `run_cmd` is ALSO a top-level setter function in the same module
(`run_cmd(_ctx, cmd)`, added for `consumer_example`). In Aether, a local named
identically to a top-level function makes reads of that name bind to the
**function pointer**, not the variable. So `${run_cmd}` / `_sh(run_cmd)` handed
the address of the `run_cmd` function — an x86 prologue `push rbp; mov rbp,rsp;
…` = `UH..SH..` — to `/bin/sh`. This is the same footgun that previously bit
`thin_jar` (`jar_name` vs `jar_name()`) and `install_launcher` (`root` vs
`root()`).

It also explains defect #2 (`env()` "not reaching"): the env prefix was
assembled fine, but the whole command downstream of it was garbage, so the
export never applied — nothing to do with `aa55d49`'s drain.

**Why it "broke on the 0.613/0.290 upgrade":** it didn't break with the
toolchain. The collision became live the day `run_cmd()` the SETTER was added to
lib/lua (the consumer_example work), which happened to land around the same
upgrade. Before that, no `run_cmd` function existed, so the local was
unambiguous.

**Fix:** rename the local to `run_command` (collision-free). Verified end to end
against html-sanitizer `lua/.tests.ae` on ae 0.613.0:

```
tests:   lua    1/1 PASS
=== 28 passed, 0 failed ===
```

env() now reaches the run (the suite finds the engine via HTMLSANITIZER_LIB) and
the command is a real string.

**Not filed as an Aether bug** — the language behaves as specified (a
same-name local shadows/aliases the function symbol). The real gap is that aeb
has no lint for local-shadows-top-level-function; a repo-wide audit for the same
class is underway.

Original report follows.

---

## Symptom

```
$ aeb lua/.tests.ae
  tests:   lua    2.30s [n/a] 0/1 FAIL

$ cat target/.aeb/logs/tests_lua.log
sh: 1: UH��SH��H�=l�: not found          <-- x86-64 prologue, executed as a command
tests:lua: building Lua C extension (gcc)
tests:lua: no lua5.4 on PATH — building bundled host
tests:lua: using bundled ./lua54 host
tests:lua: running test/conformance.lua (lua)
tests:lua: conformance FAILED
```

`UH‰åSH‰ûH‹=…` is `push rbp; mov rbp,rsp; push rbx; mov rbx,rdi; mov rdi,…` —
a function prologue. Some string handed to `bldr._sh()` is pointing at code
rather than at a NUL-terminated command. The exact bytes vary run to run
(`H�=Λ`, `H�=l�`), which is the signature of a dangling pointer rather than a
fixed bad constant.

It appears BEFORE the builder's own first `println`, so it is emitted during
the probe/setup phase, not by the `run_cmd` at module.ae:256.

## The node passes when run by hand

The command `lua.conformance` assembles (module.ae:254) works perfectly:

```
$ cd lua && HTMLSANITIZER_LIB=<path> sh -c "cd '<src>' && \
    LUA_CPATH='./?.so;;' LUA_PATH='./src/?.lua;;' './lua54' 'test/conformance.lua'"
=== 28 passed, 0 failed ===
EXIT=0
```

28/28, exit 0 — against both the freshly built engine and any other. So the
binding, the C extension, the bundled `./lua54` host and the suite are all
fine. Only the aeb-driven invocation fails.

## Second, possibly related defect: `env()` does not reach the run

Our leaf sets the engine path the documented way:

```aether
lua.conformance() {
    c_source("src/htmlsanitizer.c")
    host_source("host/lua54.c")
    test_file("test/conformance.lua")
    env("HTMLSANITIZER_LIB", lib)
}
```

`conformance` does call `bldr._env_export_prefix(_builder)` (module.ae:255),
and `env()`/`_env_export_prefix` look consistent when read side by side. But
the run behaves as if the variable were unset: with the engine present only at
the `env()`-supplied path, the suite reports

```
Last dlerror: libhtmlsanitizer.so: cannot open shared object file
```

Suspect `aa55d49` ("drain sub-builder records from the builder's own config
map") — if the drain consumes `proc_env` before `conformance` reads
`_builder`, the prefix renders empty. That is a guess; the corruption above is
not.

## Why it went unnoticed until now

This node was green two days ago. It only broke on the ae 0.613.0 / aeb 0.290.0
upgrade, and it stayed *invisible* longer than that because our
`lua/src/htmlsanitizer.lua` has a `../core/native/` fallback in its search
path, and a **stale Aug-24 `core/native/libhtmlsanitizer.so`** (left behind by
the pre-`aether.shared_lib` layout) was satisfying it. Deleting that stale
artifact is what made the env problem observable. Worth noting as a general
hazard: a loader fallback plus a stale artifact will mask an env-plumbing
regression indefinitely.

## Repro

`html-sanitizer` at `aaaafbb`, `aeb lua/.tests.ae`. The corrupted `sh:` line
reproduces on every run; only the garbage bytes differ.
