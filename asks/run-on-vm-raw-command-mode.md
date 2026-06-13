# `run_on=vm` should support a raw build command, not only `aeb <target>`

**Filed by**: the aether-ui GUI-toolkit project (sibling claude session), after
bringing the native **Win32** backend up green-ish on the **winbaz** Windows VM
by hand (tar+ssh → `build.sh` on the VM → tunnel the AetherUIDriver back → run
the test harness). That hand loop is exactly what `run_on=vm` automates — except
it can't, because the build isn't `aeb <target>`.
**Severity**: blocking for using `aeb-agent` / `run_on=vm` as the
patch→build→verdict path for aether-ui on Windows. Not blocking the project
overall — the tar+ssh substitute works (got us 15/17 on the driver gate).
**Cross-ref**: `docs/run-policy-class-and-cloud-leverage.md` (run_on=vm, lease
auth); the winbaz "Path B" section of aether-ui's
`docs/getting-windows-green-via-winbaz.md`, which already names this gap and
recommends the raw-command mode over a `.build.ae` bridge.

## The shape today

`run_on=vm` (proven end-to-end) does: rsync the prepared tree to an
SSH-reachable VM (an `~/.ssh/config` alias that owns key/ProxyJump, fail-closed
without `--vm-host`), **run `aeb <target>` there on the VM's own toolchain**,
rsync the artifacts JSON back. The build step is hardcoded to `aeb <target>`.

## Why that doesn't fit aether-ui (and the class of project like it)

aether-ui is **not an aeb project** — it has no `.build.ae`. It builds with a
hand-rolled `build.sh` that drives `aetherc` + `gcc`/`clang` directly, branching
on `uname` for the GTK4 / AppKit / Win32 backend C files and link flags. The
canonical Windows bring-up loop is:

```
./build.sh example_testable.ae build/testable    # on the VM (MSYS2/MinGW64)
build/testable.exe &                              # starts AetherUIDriver on :9222
./test_automation.sh 9222                          # HTTP-driven pass/fail
```

There's no `aeb <target>` anywhere in that. So `run_on=vm` can't drive it as-is.

The winbaz doc's two workarounds, and why neither is great:

1. **A `.build.ae` bridge** that shells out to `build.sh` via `bash._sh`. Works,
   but it's a fake aeb node whose only job is to launch a foreign build — it
   carries no real dep DAG, no per-source cache key, no artifact JSON worth
   speaking of. It exists only to satisfy the `aeb <target>` assumption.
2. **The raw-command mode asked for here.** Strictly smaller for the consumer
   (no bridge file to write/maintain) and a clean, general addition aeb-side.

## What's wanted

A way to tell a `run_on=vm` dispatch: **run THIS command on the VM** (in the
rsynced tree's root), instead of `aeb <target>`. The agent still does the
rsync-out → run → rsync-back and folds the command's exit code into the verdict
(0 → pass, non-zero → fail), exactly as it does for `aeb <target>`.

Sketch (one of):

1. **A dispatch field / flag — `--vm-command '<cmd>'`** (originator side:
   `run_on("vm")` with a `command("./build.sh … && ./test_automation.sh …")`
   setter). When present, the agent runs `<cmd>` on the VM instead of
   `aeb <target>`; when absent, current behavior (`aeb <target>`) is unchanged.
   The command runs through the same shell chokepoint `bash._sh` already uses
   (which the doc notes handles the MSYS2/Windows quoting), in the tree root,
   with the dispatch's env.
2. **Or** a target-kind that means "opaque foreign build": the target string is
   passed verbatim to a shell rather than to `aeb`.

Option 1 is the recommendation — it's additive, leaves the proven `aeb <target>`
path untouched, and is the minimal thing that lets an agent drive a `build.sh`-
or-`make`-based project.

## What is NOT being asked

- Not asking aeb to understand `build.sh` / parse its output — exit code +
  whatever the command writes to the rsync-back artifact dir is enough.
- Not asking for the VM **spawn/loan** layer (virsh start/clone) — winbaz is
  already-reachable, which is the case `run_on=vm` explicitly supports today.
- Not asking to change `aeb <target>` semantics — this is an *alternative*
  build verb on the same transport, selected per-dispatch.
- Not asking for lease/auth changes — the existing `--lease-secret` /
  purpose-bound token model is exactly right for "let CI build aether-ui on
  Windows for the next 30 min, nothing else."

## A second, smaller prerequisite (worth noting, not the core ask)

`run_on=vm` uses **rsync both directions**, and winbaz has **no rsync** (and no
`aeb`) installed. The hand loop substitutes `tar | ssh`. Two options, your call:
- document rsync (+ `aeb` if you keep the `.build.ae` bridge path) as a winbaz
  prerequisite (`pacman -S rsync` in the MSYS2 MinGW64 env), or
- let the transport fall back to `tar | ssh` when rsync is absent (more robust
  for fresh/locked-down VMs; tar+ssh is what actually worked for us).

The raw-command mode is the load-bearing ask; the transport fallback is a nice-
to-have that would make a bare VM work with zero install.

## Acceptance

From a Linux originator, a single `run_on("vm")` dispatch with `--vm-host winbaz`
and a raw command (`./build.sh example_testable.ae build/testable`) builds the
Win32 example on winbaz and returns pass/fail from the command's exit code —
**no `.build.ae` and no `aeb` on the VM required**. (Ideally the same dispatch
can chain the AetherUIDriver harness, but launching a server + tunneling the
driver port back is a separate concern; exit-code-of-a-command is the unit.)

## Scope / impact

Unblocks using `aeb-agent` + lease auth as the Windows (and any
non-aeb-native) build/test path — the "build *this uncommitted patch* on
Windows, tell me pass/fail" one-shot the run-policy doc describes — for the large
class of real projects that build with `build.sh`/`make`/`cmake` rather than a
`.build.ae`. aether-ui is the immediate consumer; the tar+ssh hand loop is the
working substitute until this lands.
