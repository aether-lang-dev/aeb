# Windows cross-platform notes — what Nushell teaches the aeb cut-down

> **Attribution.** Portions of this document and the helpers it describes
> are derived from the [Nushell](https://github.com/nushell/nushell)
> project (MIT). **Portions copyright The Nushell Project Developers.**
> See [`NOTICE`](../NOTICE).

aeb's Windows story is a deliberate *cut-down* (see TODO.md § "Windows
support"). Nushell is a mature, MIT-licensed, Windows-first shell written
in Rust, so it's a high-value reference for the exact platform seams aeb
hits. A shallow clone lives at `../nushell` for comparison. This doc
records the three findings that directly shaped aeb's design — each is the
*approach* lifted into Aether, not verbatim Rust.

## 1. No POSIX process groups on Windows — just spawn (validates the cut-down)

aeb's bash trampoline runs the build in its own process group (`set -m`),
forwards SIGINT/SIGTERM to the group, and group-reaps leaked daemons on
exit. The open question for the native entrypoint was: how do you do that
on Windows, which has no `setpgid`/`killpg`?

**Nushell's answer: you don't.** `nu-system/src/foreground.rs`
(`ForegroundChild`) gates *all* the process-group machinery behind
`#[cfg(unix)]`, with the comment:

> *"this is unix-only since we don't have to deal with process groups in
> windows"*

and on non-Unix, `spawn` is literally just `std::process::Command::spawn`
— no group, no foreground-tty dance, no reaping. A mature Windows shell
ships without replicating POSIX job control.

**Implication for aeb — UPDATED (ae 0.231+).** This section's original
conclusion ("the Windows arm skips group-reap; a leaked daemon won't be
swept") is now **superseded**. Aether's `std.os.run_supervised` is
**cross-platform**: the *same* call that uses POSIX process groups maps onto
**Windows Job Objects** under the hood (`AssignProcessToJobObject` for the
group, `TerminateJobObject` for timeout/signal, and
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` for the leaked-daemon group-reap). So aeb
gets **full Windows group-reap parity for free** — it does NOT hand-roll Job
Objects and does NOT degrade. Nushell skips group control on Windows because
Rust std hands it no equivalent primitive; aeb has one, so the Nushell finding
here is interesting context, not the path aeb takes. (The drive-letter and
path-separator findings below remain fully in force — those are real ports.)

## 2. Process termination: `taskkill /F /PID` vs `kill` (context, not aeb's path)

> **Superseded for aeb's own use (ae 0.231+):** aeb does not build kill
> commands at all — `os.run_supervised` enforces the timeout (POSIX
> TERM→grace→KILL; Windows `TerminateJobObject` reporting exit 124) and the
> group-reap internally, cross-platform. The mapping below is retained as
> Nushell reference for *why* a shell without that primitive shells out.

When a supervisor lacks a group-aware primitive and must enforce a timeout
(TERM→KILL the build), it can't `kill -TERM -<pgid>` on Windows. Nushell's
`nu-system/src/util.rs` (`build_kill_command`) shows the portable shape it
actually ships — and notably, it *also* just shells out rather than using
Win32 APIs:

| Platform | Command Nushell builds |
|----------|------------------------|
| Windows  | `taskkill /F /PID <id>` (one `/PID <id>` per target; without `/PID` taskkill behaves like `killall`) |
| POSIX    | `kill -<signal> -- <id>...` (or `kill -9 -- <id>...` to force) |

`taskkill /F /T /PID <id>` (`/T` = kill the process tree) is the closest
shell-level analog to group-reap — what you'd reach for *without* a
group-aware primitive. aeb doesn't need it: `os.run_supervised`'s Job Object
already terminates the whole tree. Kept here only to record what the
primitive replaces.

## 3. Drive-letter disambiguation: the `Prefix::Disk` rule (ported helper)

aeb's target-synonym grammar (`path/to:name`) uses `:`. On Windows,
`C:\proj` also uses `:`. Naively splitting on `:` turns `C:\proj` into
path `C` + synonym `:\proj`. Nushell's `nu-path` leans on Rust std's
`std::path::Prefix::Disk` for exactly this distinction; the rule is:

> A Windows drive prefix is a **single ASCII letter** immediately followed
> by **`:`**, and then either end-of-string (the cwd-relative `C:` form) or
> a path separator (`C:\` / `C:/`).

Ported to Aether as `build._has_windows_drive_prefix(s)` in
`lib/build/module.ae` (pure string analysis; runs identically on every
host, unit-tested in `tests/test_platform_helpers.ae`). The native
entrypoint's arg parser checks this *before* splitting a `:name` synonym,
so a Windows drive path is never mistaken for a synonym. A real target
like `java/foo:bar` never matches (multi-char path before the colon, a
non-separator after it). Known limitation, matching the conservative rule:
the rare drive-*relative* form `C:name` (no separator) is **not**
recognised as a drive prefix.

## 4. The node driver emits a POSIX Makefile — which is fine, via `sh`

`tools/aeb-driver.ae` schedules nodes by, **by default**, writing
`target/.aeb/build.mk` and running `make -jN -k -f <mk> all`. That file
is POSIX-shell through and through: single-quoted paths, `2>&1`, `$$?`,
`$$((_e-_s))` arithmetic, `date +%s%3N`, `case`/`esac`. `cmd.exe` rejects
essentially all of it.

It works on Windows anyway, for the same reason the rest of aeb does:
**the driver never calls `os.system` directly.** Both the probe and the
run go through `build._sh_capture` / `build._sh`, and those are the
POSIX-shell chokepoint (§ `lib/build/module.ae`, "_sh(cmd)") — on
Windows they write the command to a temp file and run it under `sh`,
i.e. the MSYS/MinGW shell the trampoline already depends on. So the
recipe bodies are interpreted by `sh`, never by `cmd.exe`.

The consequences worth knowing:

- **`make` must be the MSYS/MinGW one.** The probe is
  `command -v make` executed under `sh`, so it finds whatever `make` is
  on the MSYS `PATH`. A `nmake`-style Windows make would not understand
  these recipes — but it also would not be found by that probe.
- **No `make` → sequential, silently and correctly.** If MSYS `make` is
  absent, `have_make` stays 0 and the driver runs its in-process
  sequential loop over the same `_ae_build_all` binary, writing no
  Makefile at all. Same for `AEB_JOBS=1`. Windows without `make` is
  therefore a *supported* configuration, just a serial one — the
  fallback is the Windows story, not a degraded mode.
- **This is untested on Windows.** The reasoning above is from reading
  the chokepoint, not from a winbaz run. The Axis-2 work has proven
  native compile+run through the trampoline; whether the *multi-node
  parallel* path has ever been exercised there is not recorded. Treat
  "aeb builds a multi-node DAG under MSYS make" as unverified.

Related: `asks/halting-guarantees-and-build-termination.md` § the
per-node timeout gap — any future per-node bound must work in *both*
scheduling modes, which on Windows matters more than elsewhere because
the sequential mode is the likelier one.

## What aeb did NOT take

- **Win32 Job Objects.** Nushell doesn't use them for the foreground/kill
  paths above, so neither does aeb. If true process-tree containment on
  Windows is ever wanted, `taskkill /F /T` is the cut-down answer; Job
  Objects are a larger lift better filed upstream against the Aether
  Windows backend than hand-rolled in aeb.
- **`nu-command`'s coreutils-as-library** (native `ls`/`str`/`path`/etc.).
  Not copied, but it's the existence proof for aeb's going-forward rule
  (TODO § Windows item 6B): a Windows shell replaces coreutils with native
  ops rather than shelling out. aeb converts its ~47 coreutils shell-outs
  to `std.string`/`std.fs` opportunistically for the same reason.
