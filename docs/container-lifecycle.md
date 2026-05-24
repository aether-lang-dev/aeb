# Container lifecycle as dep-ordered steps

A common orchestration shape: **bring a container up, exercise an
endpoint inside it, then tear it down** — as three ordered steps. aeb
expresses this as three dep-ordered build nodes, each an
[inline-Aether step](inline-build-steps.md): plain `os.exec` for
`podman`/`docker`/`curl` between (or instead of) the SDK builders, with
`dep()` edges providing the ordering.

The runnable example is
[`docs/examples/container-lifecycle/`](examples/container-lifecycle/):

```
docs/examples/container-lifecycle/
├── up/.build.ae      # docker/podman run -d … ; poll until serving
├── poke/.build.ae    # dep up ; curl the endpoint ; capture response
└── down/.build.ae    # dep poke ; stop + rm the container
```

## Why three directories (not one)

The three steps live in **separate directories** so each is a clean
`.build.ae` — its own DAG node, its own `target/<dir>/`. (Multiple
same-type tagged files in one directory — `.build-up.ae` /
`.build-down.ae` — currently hit an orchestrator symbol-mangling bug;
separate dirs sidestep it.) The edges are repo-root-relative paths:

```aether
// poke/.build.ae
dep(b, "docs/examples/container-lifecycle/up/.build.ae")
// down/.build.ae
dep(b, "docs/examples/container-lifecycle/poke/.build.ae")
```

`dep()` makes the DAG `up → poke → down`, so a single invocation runs
them in that order.

## The steps

**up** — start the container detached, then *poll until it actually
serves* (don't declare "up" on a race), and record the endpoint as an
artifact:

```aether
_engine() {                       // podman if present, else docker
    out, _ = os.exec("command -v podman >/dev/null 2>&1 && echo podman || echo docker")
    return string.trim(out)
}

main() {
    b = build.start()
    eng = _engine()
    name = "aeb-cldemo"
    port = "18080"

    _rm = os.system("${eng} rm -f ${name} >/dev/null 2>&1")   // idempotent
    rc = os.system("${eng} run -d --name ${name} -p ${port}:80 caddy:2-alpine >/dev/null")
    if rc != 0 { println("up: failed to start ${name}") return 1 }

    ready = 0
    i = 0
    while i < 50 {
        probe = os.system("curl -fsS -o /dev/null http://localhost:${port}/ 2>/dev/null")
        if probe == 0 { ready = 1  i = 50 }
        else { _s = os.system("sleep 0.2")  i = i + 1 }
    }
    if ready == 0 { /* … cleanup … */ return 1 }

    tdir = build.target_dir(b)
    build.mkdirs(tdir)
    _w = io.write_file(path.join(tdir, "endpoint.txt"), "http://localhost:${port}/")
    println("up: ${name} serving at http://localhost:${port}/")
    return 0
}
```

**poke** — `dep` on up, curl the endpoint, capture the HTTP status and
first body line into a `response.txt` artifact:

```aether
main() {
    b = build.start()
    dep(b, "docs/examples/container-lifecycle/up/.build.ae")

    url = "http://localhost:18080/"
    status_raw, _ = os.exec("curl -fsS -o /dev/null -w '%{http_code}' '${url}' 2>/dev/null")
    status = string.trim(status_raw)

    tdir = build.target_dir(b)
    build.mkdirs(tdir)
    _w = io.write_file(path.join(tdir, "response.txt"), "url=${url}\nstatus=${status}\n")

    if string.equals(status, "200") == 1 { println("poke: PASS — HTTP ${status}") }
    else { println("poke: FAIL — HTTP ${status}") }
    return 0          // return 0 so teardown ALWAYS runs (see below)
}
```

**down** — `dep` on poke, stop and remove the container:

```aether
main() {
    b = build.start()
    dep(b, "docs/examples/container-lifecycle/poke/.build.ae")
    eng = _engine()
    _stop = os.system("${eng} stop aeb-cldemo >/dev/null 2>&1")
    _rm = os.system("${eng} rm -f aeb-cldemo >/dev/null 2>&1")   // idempotent
    println("down: stopped + removed aeb-cldemo")
    return 0
}
```

## Running it

Target the last step; target mode walks its deps, so all three run in
order:

```
$ aeb docs/examples/container-lifecycle/down/.build.ae
up:   aeb-cldemo serving at http://localhost:18080/
poke: PASS — http://localhost:18080/ -> HTTP 200
down: stopped + removed aeb-cldemo
aeb: 3 compile + 0 dist + 0 test
```

The `poke` artifact is left for inspection / a later archive step:

```
$ cat target/docs/examples/container-lifecycle/poke/response.txt
url=http://localhost:18080/
status=200
first-line=<!DOCTYPE html>
```

## Two design notes

- **Teardown always runs.** `poke` returns `0` even on a non-200 so a
  bad response doesn't abort the pipeline before `down` cleans up — the
  pass/fail verdict lives in the log and `response.txt`, not the exit
  code. If you *want* a failed poke to fail the build, return non-zero
  and accept that the container is left running for inspection (or move
  teardown into the poke step's own cleanup path).
- **Shared constants over artifact hand-off.** The three steps share
  the container name and port as plain literals rather than passing
  them through artifacts. The `dep()` edges already give the ordering;
  the only thing the steps must agree on is the handle, and a constant
  is the simplest way. (When a step genuinely *produces* data a later
  step consumes — a generated file, a resolved version — write it into
  `target/<module>/` and read it back; see
  [inline-build-steps.md](inline-build-steps.md).)

## Relation to the container SDK

`lib/container` ships `container.image(b)` (build an OCI image),
`container.lxc(b)`, and `container.run(b)` (run a *one-shot*
`--rm` container and capture pid-1 stdout). None of those is a
long-running up/poke/down lifecycle — `container.run` exits when the
command finishes. This inline-Aether pattern is the lighter answer when
you need a service standing for the duration of a few steps. If the
"spawn a server, run something against it, kill it" shape recurs for
*tests*, `bash.test`'s `fixture_server` grammar does it within a single
test builder; the three-node form here is for build/dist pipelines
where the up/poke/down phases are distinct graph nodes.
