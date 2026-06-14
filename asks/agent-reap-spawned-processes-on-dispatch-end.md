# aeb-agent should reap processes a dispatch spawns but doesn't reap

> **STATUS: IMPLEMENTED** (Option 1 — reap-by-default + `keep_alive` opt-in).
> The raw-command path (run_on=host AND run_on=vm) now runs each dispatch
> `command` in its own process group and group-reaps survivors on return
> (TERM → 1s grace → KILL), matching the `aeb` trampoline's discipline
> (`_reap_wrap` in `tools/aeb-agent.ae`). A dispatch sets `"keep_alive": true`
> to opt out (the driver-gate "serve then drive" case); the agent then leaves
> the process up and returns `"kept_alive": true` in the verdict so the leak is
> accountable and the caller knows to tear it down (a follow-up
> `command:"pkill …"` dispatch, itself reaped). The macOS/Windows guide's
> driver-gate example now shows `keep_alive: true` + teardown, resolving the
> doc/impl contradiction below. Proven: a backgrounded `sleep` (via `&` AND via
> a subshell) is reaped on return; with `keep_alive` it survives. Suite 109/109.
> The `/reap` endpoint + `/ping`-lists-survivors refinements (richer than the
> verdict flag) remain a possible follow-up but were not needed to close the
> footgun. CIDR-style refinements N/A here.


**Filed by**: aether-ui (using `aeb-agent --run-on host` on a Mac mini, and
`--run-on vm` on winbaz, to build + drive its native GUI backends).
**Severity**: not blocking (workaround: `pkill` on the host) — but it wedged the
single build slot and silently leaked a GUI process across dispatches; a clean
lifecycle contract would have prevented an hour of confusion.
**Cross-ref**: the existing "Build-level process-group reaping + `aeb --timeout`"
work (the `aeb` trampoline reaps its own build's process group on exit) — this
asks for the *same discipline* in the **agent's raw-command path**, which
currently has none. Also cross-refs the agent's own guide
(`getting-windows-and-macos-green-via-remote-agents.md`), which **recommends**
backgrounding a server in the dispatch `command` — see the contradiction below.

## What happened

Running the AppKit driver gate exactly as the agent's guide says:

```
# dispatch command (from the guide):
"./build.sh example_testable.ae build/testable && build/testable &"   # driver on :9222
```

The dispatch returned `result:pass` (the `command` exited 0). But the
backgrounded `build/testable` — a GUI app that never exits — **kept running on
the host**, and every subsequent dispatch got `503 busy` ("all 1 build slot(s)
in use"), even though `/ping` intermittently reported `busy:false`. The slot was
effectively wedged by a process the prior dispatch had spawned and detached.
Recovery required a manual `pkill -f build/testable` on the host — which, for the
Mac, means physically/remotely getting to the box (the whole point of the agent
was *not* needing that).

## The gap

The agent's `run_on=host` (and `run_on=vm`) raw-command path runs the command via
a plain `build._sh` shell-out (`tools/aeb-agent.ae`). It does **not**:
- put the command in its own process group, or
- reap what the command spawns when the command returns.

So anything the `command` backgrounds (`… &`, `nohup`, a daemonized server)
**outlives the dispatch indefinitely** — holding ports, resources, and (if the
slot accounting keys off the process group) the build slot itself. There is no
lifecycle contract for dispatch-spawned processes at all.

`aeb` the trampoline already solved this for its own builds (process-group
reap: TERM → grace → KILL on completion). The agent's raw-command path just
doesn't apply it.

## The contradiction worth highlighting

The agent's macOS/Windows guide **tells you to background a server in the
`command`** to stand up the AetherUIDriver so the harness can drive it
(`build/testable & … test_automation.sh`). That's the documented, intended
usage. But the agent has **no story for that backgrounded process's lifecycle** —
it leaks, and (as we hit) wedges the slot. The doc and the implementation
disagree: one says "background a server," the other silently never cleans it up.

## What's wanted

**Reap dispatch-spawned processes when the dispatch ends — by default.** Run each
raw command in its own process group and group-reap it (TERM → grace → KILL,
the existing `aeb`-trampoline discipline) when the command returns, so a leaked
background process can't outlive its dispatch or wedge the slot. The host returns
to a clean state after every dispatch, with no manual `pkill`.

**…with an explicit opt-out for the legitimate long-lived-server case**, because
the driver gate *needs* a server to outlive the build step long enough to be
driven. Two coherent shapes:

1. **Reap-by-default + a `keep-alive` dispatch field** (or `--allow-background`
   agent flag). Normal dispatches are fully reaped on exit; a dispatch that
   declares `keep_alive: true` (or names the port/PID it intends to leave up) is
   allowed to leave its server running — and the agent then **tracks and exposes
   it** (reports the surviving PID(s)/port in the verdict, lists them on `/ping`,
   and offers a `/reap` or accepts a follow-up `command:"pkill …"` dispatch to
   tear it down). This makes the leak *intentional and accountable* instead of
   silent.

2. **A two-phase "serve-and-drive" dispatch** — the agent itself launches the
   server, runs a *second* command (the harness) against it, then reaps the
   server, all within one dispatch/one slot. This is the cleanest fit for the
   driver-gate use case the guide describes (no backgrounding in user `command`
   at all), but it's more surface than #1.

Option 1 is the recommendation: reap-by-default fixes the footgun for everyone;
the `keep_alive` opt-in preserves the documented driver-gate pattern and makes
the surviving process visible rather than orphaned.

## What is NOT being asked

- Not asking to forbid background processes — the driver gate genuinely needs
  one. The ask is *accounting* for them (reap, or track-and-expose), not banning.
- Not asking for full cgroup/job-object containment — process-group reap (what
  the trampoline already does) is enough for the leak/slot-wedge we hit.
- Not a slot-accounting redesign — though "a detached child shouldn't silently
  count against `max_jobs` while `/ping` says idle" is a related symptom worth a
  look (the `busy:false` + `503 busy` mismatch we observed).

## Acceptance

A dispatch whose `command` backgrounds a process leaves the host clean after the
dispatch returns (the process is reaped) — UNLESS the dispatch opts into
`keep_alive`, in which case the surviving PID/port is reported in the verdict and
visible on `/ping`, and a subsequent `/reap` (or teardown dispatch) cleans it up.
The single build slot is never wedged by a prior dispatch's leaked child. Proven
against the driver-gate flow: launch `testable`, drive it with
`test_automation.sh`, and the agent returns to idle with no manual `pkill`.

## Scope / impact

Any agent whose dispatches launch servers/daemons (test gates, integration
fixtures, the AetherUIDriver flow the guide itself recommends) hits this. On a
single-slot agent it's acute — one leaked process locks out all future builds —
and on an unreachable host (the Mac, no ssh) the only recovery is physical
access, defeating the agent's purpose.
