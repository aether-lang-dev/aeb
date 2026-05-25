# server-daemon snafu: a backgrounded `std.http.server` daemon kills the capturing (sandboxed) command

**Reporter**: servirtium-go ↔ aeb session (Claude, 2026-05-24)
**Toolchain**: ae 0.184.0, aeb 0.0.0-dev (2f39cada), Linux
**Severity**: medium for agent/CI use — silently breaks any aeb build step
that launches a long-running HTTP server in the background (the natural
shape for an `up_poke_down` / `docs/examples/container-lifecycle`-style
"bring a service up, poke it, tear it down" step). Not a wrong-output bug;
the whole command is killed and its output is truncated/empty.

## Symptom

When a shell command (run inside a sandboxed agent harness) launches a
**backgrounded Aether `std.http.server` daemon**, the *foreground* command is
terminated abnormally: trailing statements never run, the captured stdout is
truncated or empty, and the harness reports a non-zero exit (observed: `1`,
and `144` = 128+16/SIGURG when the daemon was still lingering at command
end). The daemon's own first lines ("Server running at …") may appear before
the command dies.

This bit the servirtium-go aeb migration: the `up_poke_down` build step
(modeled on `docs/examples/container-lifecycle`) launched a VCR playback
server with `os.system("... &")` and polled it — every `aeb` invocation then
died with no output. The fix there was to make the demo a **one-shot**
(start + self-probe + stop in a single process, no backgrounding); once
nothing was left running in the background, `aeb` captured normally.

## Minimal reproducer (no servirtium, plain `std.http.server`)

`listener.ae`:

```aether
// A plain HTTP daemon: bind a port, start the accept loop on the background
// (detached) thread, then linger.
import std.http

extern http_server_start_background_raw(server: ptr) -> int
extern sleep(ms: int)

main() {
    s = http.server_create(18077)
    if s == 0 { println("bind failed"); return 1 }
    rc = http_server_start_background_raw(s)
    if rc < 0 { println("start failed"); return 1 }
    println("listening on 18077 (background accept thread)")
    sleep(30000)            // linger, holding the socket + detached thread
    http.server_stop(s)
    return 0
}
```

Build and reproduce:

```sh
ae build listener.ae -o listener

# Background the daemon (as an up_poke_down-style step would), then try to
# continue the command:
./listener >listener.out 2>&1 &
echo "launched pid=$!"
sleep 1
echo "DONE"          # <-- this line never runs; the command is killed here
```

Observed: `launched pid=…` prints, `listener.out` shows
`Server running at http://0.0.0.0:18077 / Press Ctrl+C to stop`, then the
command dies — **`DONE` is never printed** and the harness reports exit 1
(or 144). The same happens whether the server binds `0.0.0.0` (default) or
`127.0.0.1` (via `http_server_set_host`).

## What is and isn't the trigger (probes)

Run inside the same sandboxed harness, capturing output:

| Probe | Result |
|---|---|
| `echo` / `ls` / arbitrary non-server commands | ✅ fine |
| `aeb --version` (trampoline) | ✅ fine |
| `ae build --emit=lib …` (aetherc + gcc) | ✅ fine |
| `aeb <trivial print-only target>` (orchestrator runs) | ✅ fine |
| `aeb <native `--emit=lib` step>` | ✅ fine |
| **plain `std.http.server` daemon, foreground, binds + exits** | ✅ fine |
| **python `socket` listener (127.0.0.1), backgrounded, `sleep 30`** | ✅ fine — command completed, output shown |
| **Aether `std.http.server` daemon, backgrounded, lingering** | ❌ command killed, output truncated |

So it is **not**: binding a socket per se, lingering background processes per
se, aeb's orchestrator, the Aether compiler, or `0.0.0.0` vs loopback. It
**is** specific to a **backgrounded, lingering Aether `std.http.server`
daemon**. The distinguishing factors vs. the (harmless) python listener are
on the Aether-server side:

- it runs its accept loop on a **detached `pthread`**
  (`http_server_start_background_raw`);
- it prints `"… Press Ctrl+C to stop"`, implying it installs a **SIGINT/
  signal handler** and/or expects signal-driven shutdown;
- it uses epoll/kqueue pollers (`std/net/aether_http_server.c`).

The leading hypothesis: the harness sandbox treats the command as "done" when
the foreground process returns, but a backgrounded child that has its own
**process group / session, signal handlers, and a detached accept thread
holding a listening fd** races with the harness's process-group teardown —
the teardown signal (SIGURG/SIGHUP/SIGTERM to the group) reaches the
foreground shell, killing it before trailing statements run. A plain python
listener doesn't install handlers or detach a thread, so it's reaped cleanly.

## Why aeb cares

The `up_poke_down` / container-lifecycle pattern — "start a server detached,
poll it, tear it down" — is a first-class aeb idiom (`docs/examples/
container-lifecycle/.up_poke_down.ae` does exactly this with `docker run
-d`). `docker run -d` is safe because it daemonizes *into the docker daemon*
(no server process in aeb's own tree). But the same step launching a **native
in-tree** server (an Aether `std.http.server`, a Go/Node/etc. test server)
leaves a real backgrounded process in aeb's process group — and under a
sandboxed agent/CI harness that trips this snafu.

## Suggested directions

1. **aeb / lib examples**: for "exercise a server" steps, prefer a **one-shot
   driver** (the server process starts, self-probes over loopback, and exits)
   over "background + poll + kill". This is the shape `bash.test` /
   `aether.driver_test` fixtures should encourage; document it next to
   `container-lifecycle` as the in-tree-server counterpart to `docker -d`.
2. **Aether `std.http.server`**: consider a quiet/embedded mode that does not
   print the `"Press Ctrl+C to stop"` banner and does not install a SIGINT
   handler when started via `http_server_start_background_raw` (an embedded/
   backgrounded server should be controlled by `http_server_stop`, not Ctrl+C).
   See also the related embed-noise note in
   `../aether/vcr_embed_surface_and_strict_ignore_wish.md` §3.
3. **Repro harness**: the `listener.ae` above is a 12-line, dependency-free
   repro — good for bisecting whether it's the detached thread, the signal
   handler, or the poller.

## Workaround (in use)

servirtium-go's `demo/.up_poke_down.ae` runs a one-shot `vcrdemo` binary that
does up→poke→down in a single process and exits 0/1 — no backgrounded daemon,
so it captures cleanly. That's the recommended pattern until the above is
resolved.

---

## Resolution (2026-05-24, aeb side)

Reproduced at the aeb level (a build step backgrounding a native
`std.http.server` makes `aeb` itself exit non-zero), and narrowed:

- A plain lingering `sleep &` is fine; only a lingering **Aether
  `std.http.server`** poisons the exit (SIGURG / 144). It even
  cross-contaminates later commands while the server is alive.
- **`setsid` (own session/PG) did NOT suppress it** — so this is not
  process-group hygiene aeb can fix from the launch side; it's the
  server runtime's signal behavior. Filed to aether as
  `std-http-server-background-sigurg-poisons-harness.md` (request: a
  quiet/embedded mode that installs no SIGINT handler / banner when
  started via `http_server_start_background_raw`).

What aeb *can* own — never leave a server lingering past the step:

1. **Hardened `fixture_server` teardown** (`lib/build` `_synth_fixture_pre`/
   `_synth_fixture_post`): the server is launched with stdin detached
   (`< /dev/null`) and torn down with `TERM → grace-poll → KILL → wait`,
   so it dies and is reaped before the step returns even if it ignores
   TERM. Validated: `aeb --tests` exits 0 across repeated runs with an
   in-tree backgrounded `std.http.server` fixture. (For a TERM-respecting
   server the prior `kill`+`wait` already worked; the KILL escalation is
   defense for a TERM-ignoring one.)
2. **Docs** (`docs/container-lifecycle.md`): an in-tree native server step
   should use a **one-shot** driver or the reaped `fixture_server` — never
   a bare `os.system("server &")`, which is the fragile shape that started
   this. `docker run -d` stays safe (daemonizes into docker).

Caveat: (1)/(2) ensure the server doesn't *linger*; during the window it
must be alive to be probed, a harness can still observe the SIGURG. The
durable fix is the aether-side quiet/embedded mode.

---

## Update (2026-05-25): build-level reaping + `--timeout` landed

aeb now reaps the **whole build's process group** on completion, so this
is contained even for a *hand-rolled* `os.system("server &")` — not just
declared `fixture_server`s:

- The trampoline runs the entire build (`aeb-main` → `aeb-link` →
  orchestrator → anything a step spawned) as one `set -m` job in its own
  process group, and on completion group-kills survivors
  (`TERM` → grace → `KILL`). So a leaked native server is **killed before
  `aeb` exits**, and can't poison aeb's exit code. Always on; a no-op
  when a build leaks nothing.
- `aeb --timeout N` (or `AEB_TIMEOUT=N`, seconds) caps total wall-clock
  and exits **124** on overrun — so a wedged server-poll can't hang CI.

### Advice for servirtium-go (in priority order)

1. **Keep the one-shot `vcrdemo` (`up_poke_down` in a single process).**
   Still the best shape — deterministic, nothing backgrounded, nothing to
   race. You don't need to change it.
2. **If a test needs the server *standing* while it runs**, use
   `bash.test`'s `fixture_server { bin(...); port(...); ready_after_ms(...) }`
   (or `aether.driver_test`). aeb launches it stdin-detached and reaps it
   (`TERM → grace → KILL → wait`) when the test step ends.
3. **If you must hand-roll a background server in a step**, you're now
   safe from the *poisoned-exit* symptom — aeb group-reaps it at build
   end. But still avoid it where you can: while the server is alive
   *during* the build a harness can still observe the SIGURG, so a
   one-shot or fixture is cleaner. Never rely on your own ad-hoc `kill`.
4. **In CI**, set `aeb --timeout <seconds>` so a hung probe fails fast
   (124) instead of wedging the runner.

The **durable** fix is still aether-side: a quiet/embedded
`std.http.server` mode that installs no SIGINT handler / banner when
started via `http_server_start_background_raw`
(`../aether/std-http-server-background-sigurg-poisons-harness.md`). Until
that lands, aeb's reaping + `--timeout` keep it from breaking your build;
they don't stop the server from *emitting* the SIGURG while it's alive.
