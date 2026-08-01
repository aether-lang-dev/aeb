# Aether enhancements wanted by `aeb`

> **STATUS (re-audited 2026-08-01 against aether 0.472.0).** Most of this
> file has been overtaken by events. Section A is **fully shipped**, so
> the bash trampoline is no longer blocked on upstream; section B's
> filesystem primitives are **all shipped**. Three items remain genuinely
> open upstream — see **Priority** near the end for the current list and
> for what is now aeb-side work.
>
> Two cautions for whoever audits this next:
> * **Verify by CALLING, not by grepping.** The `fs` wrappers are exported
>   as `fs.<op>` over `fs_<op>_raw` externs, so searching for the names as
>   written in section B ("fs_mkdir_p") reports *absent* when they exist.
>   This audit made that mistake first.
> * **"std has a function with this name" does not mean aeb should use
>   it.** std's `path.join`/`dirname`/`basename` differ from aeb's on
>   trailing separators, absolute right-hand sides, and Windows drive
>   prefixes — see the audit at the end of this file.

`aeb` is now a bash trampoline (~600 lines — it also carries the
build-level process-group reap + `--timeout` watchdog, plus the
`--vet`/`--sandbox`/remote-agent dispatch arms) plus a suite of
Aether-language tools under `tools/`. The bash bit sets `AETHER` /
`AEB_HOME` / `ROOT`, auto-detects the Podman socket, runs the build in its
own process group and reaps survivors, and dispatches to `tools/aeb-main`,
`tools/aeb-init`, or `tools/gcheckout`. Everything else — argument
parsing, DAG discovery, dep extraction, topo sort, per-file compile, link,
node scheduling, exec — is Aether.

What's left preventing the trampoline from going away entirely, and what
would let `aeb` run unmodified on Windows.

> **The pure-Aether entrypoint already exists.** `tools/aeb-cli` is a faithful
> facsimile of the bash `aeb` — full flag parity (all build flags + `--sandbox`,
> `--version`, `--init`), the supervised exec (own process group, signal
> forwarding, timeout, group-reap — one cross-platform `os.run_supervised` call,
> POSIX process groups / Windows Job Objects), and an A/B harness (`ab.sh`)
> proving it produces identical exit code + artifact set + telemetry to the bash
> trampoline across C/Rust targets. It compiles and serves natively on Windows
> too. **It may become the default `aeb` once the items in §A below are closed
> upstream in Aether** — at which point the bash trampoline is retired and `aeb`
> is pure Aether end to end (and Windows-native without MSYS/bash). Until then,
> bash `aeb` ships as the default and `aeb-cli` is the proven-equivalent
> alternate. See `mingw_a_b_plan.md` for the A/B methodology.

## A. Make the bash trampoline disappear

> **✅ ALL THREE SHIPPED — this section is no longer blocked on Aether.**
> Re-audited 2026-08-01 against 0.472.0 and functionally tested, not just
> grepped. What remains is aeb-side work, not an upstream ask.

1. ✅ **Resolve the running binary's directory.** `aether_argv0()` is
   declared in `std/os` and `fs.realpath(p)` in `std/fs` (returns a
   3-tuple: path, rc, err). Both verified working.
   ```
   extern aether_argv0() -> string         // path the OS launched us with
   fs.realpath(p) -> (string, int, string) // canonicalize symlinks etc.
   ```

2. ✅ **Replace the current process.** `os_execv` is exported from
   `std/os`.

3. ✅ **Read environment variables** — `os_getenv`, solved long ago.
   Listed for completeness.

**So the bash trampoline can collapse into a self-bootstrapping `aeb.ae`
whenever someone does the work.** That is now an aeb task, and
`tools/aeb-cli` is already most of it (see the note at the top of this
file). Nothing here is waiting on upstream.

## B. Reduce per-call subprocess forks inside the tools

The tools all live as separate native binaries that the bash
trampoline (or each other) `exec` into. Inside each tool, several `os_system`
/ `os_exec` calls remain that could become native:

> **✅ EVERY FILESYSTEM PRIMITIVE ASKED FOR HERE HAS SHIPPED.** Re-audited
> 2026-08-01 against 0.472.0. The remaining work is aeb-side: migrating
> the call sites off `os.system` string-building. Nothing upstream.
>
> Note the earlier audit nearly got this wrong — the wrappers exist under
> `fs.<op>` with `fs_<op>_raw` externs beneath, so a grep for the exact
> names in this table ("fs_mkdir_p") reports *absent*. They were verified
> by CALLING them, not by name.

| Pattern                        | Used in                                     | Status                              |
|--------------------------------|---------------------------------------------|-------------------------------------|
| `mkdir -p`                     | aeb-init, aeb-link, aeb-main                | ✅ `fs.mkdir_p(path)`               |
| `ln -s` / `rm` / `readlink`    | aeb-init                                    | ✅ `fs.symlink`, `fs.readlink`, `fs.unlink` |
| `dirname $(command -v ...)`    | aeb-link, aeb-main                          | ✅ `os.which(name)`                 |
| `test -L` / `[[ -L ]]`         | aeb-init                                    | ✅ `fs_is_symlink(p)` (raw extern; no wrapper yet) |
| `git sparse-checkout add ...`  | gcheckout                                   | unavoidable shell-out, but see (D)  |
| `gcc -O2 ...` (the link step)  | aeb-link                                    | unavoidable shell-out (gcc/clang)   |
| `find ...` (already gone)      | scan-ae-files uses fs_glob                  | done                                |
| `sed`/`grep`/`awk` (gone)      | encode-name, extract-deps, topo-sort, etc.  | done                                |

All verified by calling them on 0.472.0: `mkdir_p` created a nested tree,
`symlink`/`readlink` round-tripped, `realpath` resolved `a/b/../b/c`,
`unlink` removed the link, `os.which("sh")` returned `/usr/bin/sh`.

## C. Things needed so Windows isn't left behind

`aeb` works on Linux and macOS today. For Windows (MinGW / MSYS2 / native)
the gaps are:

1. **Symlink semantics** — `lib/aether/.aeb/lib/<sdk>` is a symlink farm.
   Windows symlinks need elevation or developer mode. Alternatives Aether
   could offer:
   - Junction-point stdlib helper (`fs_junction`) for directories
   - Or: an "embed mode" where `aeb --init` copies the SDK files instead of
     symlinking, with a watcher to mirror updates
   - The current `aeb-init` always uses `ln -s`; would need a runtime
     branch.

2. **Path separator handling** — every tool uses `/` literally in
   `string_concat` calls. PARTIALLY SHIPPED as of 0.472.0:
   ```
   path_join(a, b)        ✅ present
   path_is_absolute(p)    ✅ present (not originally asked for; useful here)
   path_normalize(p)      ❌ still absent
   path_separator()       ❌ still absent
   ```
   Note aeb does NOT simply want `path.join` here — its own `_path_join`
   honours an absolute right-hand side and Windows drive prefixes, where
   std's returns `a//b`. See the audit at the end of this file. The
   remaining upstream ask is `path_normalize` / `path_separator`.

3. **Process launching** — ✅ **SHIPPED.** The argv-based launch this
   asked for landed in aether 0.124 as `os.run_capture(prog, argv, env)`
   and `os.run_pipe*` (incl. the deadlock-free
   `os.run_pipe_drain_and_wait`), which `aeb` now uses (e.g.
   `aether.driver_test`). It does what this item wanted — no shell in the
   middle, eliminating a class of quoting bugs on every platform. The
   original ask, for the record:
   > `os_system` on Windows runs through `cmd.exe` in some runtimes, and
   > the shell strings (`>/dev/null`, `&&`, `2>&1`) don't all work there;
   > an argv-based `os_run(prog, argv, env)` / `os_run_capture(...)` that
   > doesn't use a shell fixes it.

   Remaining: not every aeb shell-out has been migrated off `os.system`
   string-building to `os.run_capture` yet — that's an aeb-side cleanup,
   not an upstream ask.

4. **`fs_glob` recursive walker** — already POSIX-only on the C side
   (uses `dirent`/`fnmatch`). Windows needs the `FindFirstFile` /
   `FindNextFile` path implemented or a port of fnmatch. This sits in the
   Aether runtime, not in `aeb`.

5. **Podman/Docker socket detection** — only relevant when a build's tests
   use TestContainers. The trampoline currently does
   `[[ -S "/run/user/$(id -u)/podman/podman.sock" ]]` and exports
   `DOCKER_HOST`. **STILL BLOCKED** (re-checked 0.472.0): neither exists.
   ```
   extern fs_is_socket(path: string) -> int   ❌ absent
   extern os_user_id() -> int                 ❌ absent
   ```
   `fs.try_stat` + `fs_get_stat_kind` may already answer the socket half;
   worth checking before filing.

6. **`gcc` invocation** — the link step assumes a POSIX shell line. On
   Windows we'd point at `gcc.exe` (MinGW) or `cl.exe` (MSVC). The argv
   layout is similar; the wrappers and `-L` / `-l` flags differ for MSVC.
   Out of scope for `aeb` itself but worth noting that Aether's own
   compiler assumes gcc-compatible flags.

## D. VCS abstraction — MOVED OUT (not an Aether ask)

**Moved to `TODO.md` on 2026-08-01, under the `--since` VCS item it
belongs beside.**

This section asked for a runtime `extern vcs_sparse_add(repo, path)`
implemented per VCS in the Aether stdlib, so `aeb gcheckout` could narrow
a working copy under Mercurial/Subversion/jj as well as Git.

That is the wrong layer. **Aether is a language runtime and has no
business knowing about VCS technologies** — it would be a large, drifting
surface (four tools × their flags × their versions) added for exactly one
consumer, and every other Aether program would carry it. The alternative
the section itself offered — a per-repo-kind command table on aeb's side,
with a `.aebvcs` escape hatch — needs nothing from upstream at all.

Kept as a stub rather than deleted so the section letters in this file
stay stable and anyone following an old reference lands here.

## E. Already done

These were in the previous iteration of this doc and have since landed:

- ✅ String memory leak in loops fixed (commit on
  `feature/tinyweb-aeocha`, also in PR
  `fix/heap-tracker-and-fs-glob-dotfiles`).
- ✅ `fs_glob` recursive walker matches dot-prefixed files (same PR).
- ✅ `_heap_<var>` lazy declaration in codegen (same PR).
- ✅ Pure-Aether string operations are now sufficient: we have
  `string_index_of`, `string_substring`, `string_concat`, `string_trim`,
  `string_ends_with`, `string_starts_with`, `string_length`, plus a
  userland `string_replace_all` in `tools/encode-name.ae` (~12 lines).
  *(Superseded 2026-08-01: aether 0.463.0 added a native
  `string.replace_all`, whose C symbol collided with that userland copy
  and broke the link. aeb now uses the native one and keeps no copy —
  `AETHER_PIN` is 0.463.0 for exactly this. See
  `itests/std-symbol-collision.sh`.)*
- ✅ `aeb` migration itself — encode-name, infer-type, file-to-label,
  resolve-dep, extract-deps, scan-ae-files, topo-sort, aeb-link,
  aeb-init, aeb-main, gcheckout all in Aether.

## Priority

**Re-audited 2026-08-01 against 0.472.0.** Items 1, 3 and 4 of the previous
list have all shipped — so most of what this file asked for is done, and
the bulk of the remaining work is aeb-side rather than upstream.

Still open UPSTREAM, in rough value order:

1. **`fs_glob` Windows backend** — the POSIX `dirent`/`fnmatch` walker.
   Still the highest-value open item: the only thing in `tools/` that
   absolutely will not run on native Windows.
2. **`fs_is_socket` + `os_user_id`** — the Podman-socket probe (C5).
   Check `fs.try_stat`/`fs_get_stat_kind` first; it may already cover the
   socket half, leaving only the uid.
3. **`path_normalize` / `path_separator`** — the rest of C2. Note aeb
   deliberately keeps its own `_path_join` (absolute-RHS + Windows drive
   handling that std's lacks); see the audit below.
Now aeb-SIDE work, not upstream asks:

- **Collapse the bash trampoline into `aeb.ae`.** `aether_argv0`,
  `fs.realpath` and `os_execv` all exist; `tools/aeb-cli` is already most
  of the implementation.
- **Migrate `aeb-init` off `ln`/`readlink`/`test -L`** onto `fs.symlink` /
  `fs.readlink` / `fs.unlink` / `fs_is_symlink`.
- **Migrate remaining `os.system` string-builders** onto `os.run_capture`.

**NOTE ON FILING.** None of the open items above have ever been filed as
aether issues — this file is where they have lived. The repo convention
for an upstream ask is `asks/aether-*.md` carrying an `**Upstream
issue:**` link (see `asks/aether-actor-synchronous-call.md`). The open
items should move to that shape; this file should keep only aeb's own
status and history.

## Audit: aeb helpers vs std (2026-08-01)

Prompted by `string_replace_all` — where a local helper duplicated
something std had gained. Swept every top-level function aeb defines
against std's full exported/extern symbol set (~1355 names, read from the
installed toolchain) to find others.

**Method note**: matching by name alone produced ~46 hits, nearly all
noise — SDK setters (`release`, `path`, `bin`, `arg`) that merely share a
spelling with a std function and compile to `<module>_<name>`, so they
never collide or duplicate. The signal is in the *underscore-prefixed
private helpers*: those exist because someone needed a utility, which is
exactly where std may now have one.

| aeb helper | std equivalent | Verdict |
|---|---|---|
| `_index_of_from` (tools/aebcli) | `string.index_of_from` | **REMOVED** — identical over 7 cases |
| `_dirname` / `_basename` / `_path_join` (lib/build) | `path.*` | **KEEP** — semantics differ, see below |
| `_dirname` (aeb-query, affected-targets) | `path.dirname` | **KEEP** — differs from std AND from lib/build's |
| `_to_int` (lib/agent) | `string.to_int` | **KEEP** — deliberately lenient |
| `_csv_split` (lib/agent) | none | not a duplicate (splits + trims + drops empties) |
| `_abs` (aeb-trace) | none | shells out to `pwd` |

**Why the path helpers stay.** std.path is *not* a drop-in replacement —
measured on 0.463.0:

| input | aeb (lib/build) | std.path |
|---|---|---|
| `dirname("foo/bar/")` | `foo` | `foo/bar` |
| `basename("foo/bar/")` | `bar` | `""` |
| `join("a", "/b")` | `/b` | `a//b` |

aeb's versions ignore trailing separators, honour an absolute right-hand
side, and understand Windows drive prefixes (`C:\foo` → `C:`). These
derive build labels and target directories — the addressing contract — so
a silent semantic change there would misroute artifacts, not just look
untidy. Swapping them needs std to match, or a deliberate migration with
the label tests as the gate.

**Worth noting**: `aeb-query`'s `_dirname` returns `""` for a bare name
where `lib/build`'s returns `"."`. That divergence predates this audit and
is a latent inconsistency, not something std would fix.

**`_to_int` is a different contract, not a worse one.** std's fails closed
(`"12abc"` → error, `""` → error); aeb's is lenient by design (`"12abc"` →
12, `""` → 0) for parsing agent fields where a partial value is wanted.
