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

**Implication for aeb:** the cut-down decision is correct. The native
entrypoint's Windows arm should spawn + wait the build directly and skip
group-reap, accepting that a leaked daemon won't be swept. This matches
that `os.run_supervised` is POSIX-only upstream (its Windows stub reports
"unsupported"). Document the missing group-reap as a known Windows gap,
don't try to hand-roll Job Objects for parity.

## 2. Process termination: `taskkill /F /PID` vs `kill` (a copyable mapping)

When aeb's native entrypoint needs to enforce a timeout (TERM→KILL the
build), it can't `kill -TERM -<pgid>` on Windows. Nushell's
`nu-system/src/util.rs` (`build_kill_command`) shows the portable shape it
actually ships — and notably, it *also* just shells out rather than using
Win32 APIs:

| Platform | Command Nushell builds |
|----------|------------------------|
| Windows  | `taskkill /F /PID <id>` (one `/PID <id>` per target; without `/PID` taskkill behaves like `killall`) |
| POSIX    | `kill -<signal> -- <id>...` (or `kill -9 -- <id>...` to force) |

So the aeb Windows entrypoint, lacking group semantics, can at minimum
force-kill the top-level build PID on timeout via `taskkill /F /PID`. For
a process *tree* (the children the build spawned), `taskkill /F /T /PID
<id>` terminates the PID and its descendants — the closest Windows analog
to group-reap, and a reasonable cut-down substitute worth using on the
timeout path. (`/T` is the tree flag; Nushell's user-facing `kill` doesn't
use it, but the timeout-reap case wants it.)

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
