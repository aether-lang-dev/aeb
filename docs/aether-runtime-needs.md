# Aether enhancements wanted by `aeb`

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

The trampoline exists because of three things Aether can't currently express
without shelling out:

1. **Resolve the running binary's directory** — to find the sibling
   `tools/` folder. Bash does `AEB_HOME="$(cd "$(dirname "$0")" && pwd)"`.
   Aether equivalent wanted:
   ```
   extern aether_argv0() -> string         // path the OS launched us with
   extern realpath(p: string) -> string    // canonicalize symlinks etc.
   ```

2. **Replace the current process** — the trampoline finishes with `exec
   "$AEB_MAIN_BIN" ...`. Without execv, an Aether-language `aeb` would
   either spawn a child (extra process layer, double signal handling) or
   inline aeb-main into itself. Neither is bad but a real `execv` is
   simpler:
   ```
   extern os_execv(prog: string, args: ptr) -> int   // returns only on failure
   ```

3. **Read environment variables** — Aether already has `os_getenv`, so this
   one is solved. Listed for completeness.

If we get (1) and (2), the bash trampoline collapses into a self-bootstrapping
`aeb.ae` that the user runs directly, and the `#!/bin/bash` line goes away.

## B. Reduce per-call subprocess forks inside the tools

The tools all live as separate native binaries that the bash
trampoline (or each other) `exec` into. Inside each tool, several `os_system`
/ `os_exec` calls remain that could become native:

| Pattern                        | Used in                                     | What's needed                       |
|--------------------------------|---------------------------------------------|-------------------------------------|
| `mkdir -p`                     | aeb-init, aeb-link, aeb-main                | `extern fs_mkdir_p(path) -> int`    |
| `ln -s` / `rm` / `readlink`    | aeb-init                                    | `extern fs_symlink(target, link) -> int`, `fs_readlink(p) -> string`, `fs_unlink(p)` |
| `dirname $(command -v ...)`    | aeb-link, aeb-main                          | `extern os_which(name) -> string`   |
| `test -L` / `[[ -L ]]`         | aeb-init                                    | `extern fs_is_symlink(p) -> int`    |
| `git sparse-checkout add ...`  | gcheckout                                   | unavoidable shell-out, but see (D)  |
| `gcc -O2 ...` (the link step)  | aeb-link                                    | unavoidable shell-out (gcc/clang)   |
| `find ...` (already gone)      | scan-ae-files uses fs_glob                  | done                                |
| `sed`/`grep`/`awk` (gone)      | encode-name, extract-deps, topo-sort, etc.  | done                                |

Most of these are simple POSIX wrappers and would also benefit any other
Aether program that touches the filesystem.

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
   `string_concat` calls. The Aether stdlib's `path_join` already exists
   but isn't used; auditing every concat to use it would be a one-pass
   refactor on top of:
   ```
   extern path_join(a: string, b: string) -> string
   extern path_normalize(p: string) -> string
   extern path_separator() -> string
   ```

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
   `DOCKER_HOST`. Trivial to port to Aether once `fs_is_socket` /
   `os_user_id` exist:
   ```
   extern fs_is_socket(path: string) -> int
   extern os_user_id() -> int
   ```

6. **`gcc` invocation** — the link step assumes a POSIX shell line. On
   Windows we'd point at `gcc.exe` (MinGW) or `cl.exe` (MSVC). The argv
   layout is similar; the wrappers and `-L` / `-l` flags differ for MSVC.
   Out of scope for `aeb` itself but worth noting that Aether's own
   compiler assumes gcc-compatible flags.

## D. VCS abstraction (so `aeb gcheckout` isn't Git-only)

`aeb gcheckout` shells out directly to `git sparse-checkout`. Mercurial has
the `narrowhg` extension; Subversion has `svn update --set-depth`; jj has
its own thing. The dep-walking logic is VCS-agnostic — it produces a list
of directory paths to include. Wanted:

- Either a runtime `extern vcs_sparse_add(repo, path) -> int` that the
  Aether stdlib implements per VCS, or
- A pluggable strategy file (`.aebvcs` at repo root) that names the
  shell command to run for each directory addition (and the analogues
  for init / reset).

The first is cleaner; the second is a one-day fix that'd unblock Mercurial
users immediately.

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
- ✅ `aeb` migration itself — encode-name, infer-type, file-to-label,
  resolve-dep, extract-deps, scan-ae-files, topo-sort, aeb-link,
  aeb-init, aeb-main, gcheckout all in Aether.

## Priority

If the goal is "Windows works, bash trampoline gone":

1. ~~**`os_run` argv-based launcher**~~ — ✅ **SHIPPED** as
   `os.run_capture` / `os.run_pipe*` (aether 0.124). Was the highest-value
   item; the remaining work is aeb-side (migrate the rest of the
   `os.system` string-builders onto it).
2. **`fs_glob` Windows backend** — currently the only thing in `tools/`
   that absolutely won't run on Windows. Now the highest-value *open* item.
3. **`aether_argv0` + `os_execv`** — lets the bash trampoline disappear.
4. **`fs_symlink` / `fs_is_symlink` / `fs_readlink`** — lets `aeb-init`
   stop shelling out to `ln`/`readlink`/`test -L` and gives `--init` a
   Windows fallback (junctions or copies).
5. **VCS abstraction for `aeb gcheckout`** — unblocks Mercurial. Lower
   priority because git is a fine default.
