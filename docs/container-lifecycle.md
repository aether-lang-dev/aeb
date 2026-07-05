# Container lifecycle in one inline-Aether step

A common shape: **bring a container up, exercise an endpoint inside it,
then tear it down.** A container's lifetime is one cohesive unit of
work — it *must* be torn down, and shouldn't outlive the step that
needs it — so aeb expresses the whole up → poke → down as a single
[inline-Aether step](inline-build-steps.md): plain `os.exec` for
`podman`/`docker`/`curl`, an adjacent helper, and `build.target_dir(b)`
for the captured artifact.

The runnable example is one file:
[`docs/examples/container-lifecycle/.up_poke_down.ae`](examples/container-lifecycle/.up_poke_down.ae).
(The `.up_poke_down.ae` suffix is non-canonical on purpose — aeb runs
*any* dot-prefixed `.ae` file, not just `.build.ae` / `.tests.ae` /
`.dist.ae`; the filename documents the phases.)

## Why one step, not three nodes

You could model up / poke / down as three dep-ordered `.build.ae` nodes
(and for *independent* build artifacts that's the right shape — see
[inline-build-steps.md](inline-build-steps.md)). But a container is a
**resource that must be released**, and a single step is the better fit:

- **Teardown can't be skipped.** With three DAG nodes, a detached
  container outlives the `up` node; if the `poke` node errors hard, the
  `down` node may never run and the container leaks. In one `main()` you
  run `down` *unconditionally* via ordinary control flow.
- **You still get a real pass/fail.** After teardown, `return 1` iff the
  poke didn't pass. The three-node form forced an either/or — "always
  tear down" *or* "fail on a bad poke"; one step gets both.

## The step

```aether
_engine() {                        // podman if present, else docker
    out, _ = os.exec("command -v podman >/dev/null 2>&1 && echo podman || echo docker")
    return string.trim(out)
}

main() {
    b = build.start()
    eng = _engine()
    name = "aeb-cldemo"
    port = "18080"
    url = "http://localhost:${port}/"

    // UP — start detached, then poll until it actually serves.
    _rm0 = os.system("${eng} rm -f ${name} >/dev/null 2>&1")   // idempotent
    rc = os.system("${eng} run -d --name ${name} -p ${port}:80 caddy:2-alpine >/dev/null")
    if rc != 0 { println("up: failed to start ${name}")  return 1 }
    ready = 0
    i = 0
    while i < 50 {
        probe = os.system("curl -fsS -o /dev/null '${url}' 2>/dev/null")
        if probe == 0 { ready = 1  i = 50 }
        else { _s = os.system("sleep 0.2")  i = i + 1 }
    }
    println("up: ${name} serving at ${url}")

    // POKE — hit the endpoint, capture status into an artifact.
    status = "no-response"
    if ready == 1 {
        status_raw, _ = os.exec("curl -fsS -o /dev/null -w '%{http_code}' '${url}' 2>/dev/null")
        status = string.trim(status_raw)
        tdir = build.target_dir(b)
        build.mkdirs(tdir)
        _w = io.write_file(path.join(tdir, "response.txt"), "url=${url}\nstatus=${status}\n")
        if string.equals(status, "200") == 1 { println("poke: PASS — HTTP ${status}") }
        else { println("poke: FAIL — HTTP ${status}") }
    } else {
        println("poke: SKIPPED — never became ready")
    }

    // DOWN — unconditional teardown (never leak the container).
    _stop = os.system("${eng} stop ${name} >/dev/null 2>&1")
    _rm = os.system("${eng} rm -f ${name} >/dev/null 2>&1")
    println("down: stopped + removed ${name}")

    // Fail the build iff the poke failed — AFTER teardown.
    if string.equals(status, "200") == 0 { return 1 }
    return 0
}
```

## Running it

```
$ aeb docs/examples/container-lifecycle/.up_poke_down.ae
up:   aeb-cldemo serving at http://localhost:18080/
poke: PASS — http://localhost:18080/ -> HTTP 200
down: stopped + removed aeb-cldemo
aeb: 1 up_poke_down
```

The poke artifact is left for inspection / a later archive step:

```
$ cat target/docs/examples/container-lifecycle/response.txt
url=http://localhost:18080/
status=200
```

(Verified with podman 5.4.2 against the locally-available
`caddy:2-alpine`, which serves an HTTP welcome page on `:80`.)

## Relation to the container SDK

`lib/container` ships `container.image(b)` (build an OCI image),
`container.lxc(b)`, and `container.run(b)` (run a *one-shot* `--rm`
container and capture pid-1 stdout). None of those is a long-running
up/poke/down lifecycle — `container.run` exits when its command
finishes. This inline-Aether pattern is the lighter answer when you
need a service standing for the duration of a step. For the same
"spawn / exercise / kill" shape in *tests*, `bash.test`'s
`fixture_server` grammar does it within a single test builder.

## In-tree native servers: one-shot, or a reaped fixture — never a bare `&`

The example above backgrounds with `docker run -d`, which is safe because
the container daemonizes *into* the docker daemon — nothing is left
running in aeb's own process tree. A **native, in-tree** server (an
Aether `std.http.server`, a Go/Node test server, …) is different: if a
step launches it with a hand-rolled `os.system("./server &")` and doesn't
reliably reap it, the server can outlive the step. Under a sandboxed
agent/CI harness a lingering native server has been observed to **poison
the build's exit code** (a SIGURG/`144` or `1` with truncated output),
even though the build logic itself succeeded. (aeb now group-reaps the
whole build on completion, so a leak no longer poisons aeb's *own* exit —
but a one-shot or reaped fixture is still the right shape.)

Two safe shapes, in order of preference:

1. **One-shot** — the server's whole lifecycle lives in a single process
   that starts it, self-probes over loopback, stops it, and exits (the
   `.up_poke_down.ae` shape above). Nothing is ever left backgrounded.
2. **A reaped fixture** — `bash.test`'s `fixture_server` (and
   `aether.driver_test`'s) launch the server with its stdin detached and
   tear it down with `TERM → grace → KILL → wait`, so it is gone before
   the step returns regardless of how the server handles signals. Use
   this when a test needs the service standing while it runs.

Avoid the third shape — a bare `os.system("server &")` in a build step
with an ad-hoc `kill` — precisely because the reap can race and leave the
server lingering into aeb's exit.
