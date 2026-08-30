# Running a guest language in a build

A build step sometimes needs to run code in a language that isn't the
thing being built — a Lua snippet, a Python helper, a Ruby fixture.
aeb has two ways to do that, and they sit at opposite ends of an
isolation/cost tradeoff. This note explains both and when to reach for
which.

The two mechanisms, with the same hello-world done each way, are the
sibling tests `tests/test_container_lua.ae` and `tests/test_host_lua.ae`.

## How aeb runs a build, in one paragraph

aeb scans the `.build.ae` files reachable from a target, topo-sorts
them, and generates **one orchestrator binary** (`target/_ae_build_all`)
that calls every module's builder function in dependency order. Every
SDK builder — `java.javac`, `container.run`, all of them — runs
*inside that single process*. This is the "one orchestrator process,
no runtime subprocesses, no file-based coordination" model. It matters
here because it decides where a guest language ends up running.

## Way 1 — a container: a separate process

`container.run` shells out: the orchestrator `os.exec`s
`podman run …`, which forks a wholly separate process with its own
PID namespace, filesystem, and kernel-enforced isolation.

```aether
out = container.run(b) {
    image_ref("docker.io/nickblah/lua:5.4-alpine")
    command("lua -e 'print(\"hello\")'")
}
```

The guest language runs as the container's pid 1; aeb captures its
stdout off a pipe. The aeb binary itself links nothing
language-specific — Ruby, Lua, Node, anything, it's all external. A
container is, by definition, a separate process: there is no
"in-process" option here, and that's not a limitation to fix — it's
what a container *is*.

## Way 2 — in-process hosting: same process as aeb

Aether can embed Lua / Python / Perl / Ruby / Tcl / JS *in-process*
via `contrib.host.<lang>` — the interpreter is linked into the binary
and runs in its address space.

```aether
import contrib.host.lua

lua.run("print('hello')")          // runs inside the caller's process
```

Because builders run inside the orchestrator, a `.build.ae` that did
this would execute the guest language **inside the orchestrator
process** — sharing an address space with aeb's own build logic. That
is the purest fit for aeb's one-process model: no fork, no IPC.

**Status:** in-process hosting is demonstrated by `test_host_lua.ae`
(built by the `test_host_lua.build.sh` sidecar, which links the
`contrib.host.lua` C bridge). It does **not** yet work from a real
`.build.ae`: aeb's orchestrator linker (`tools/aeb-link`) doesn't link
foreign-language bridges. Enabling it means teaching `aeb-link` to
spot `import contrib.host.<lang>` in a module closure and add the
bridge `.c` + `-DAETHER_HAS_<LANG> -DAETHER_HAS_SANDBOX` +
`pkg-config` flags — exactly what the test sidecar does today.

## The tradeoff

| | in-process host | container |
|---|---|---|
| Process | inside aeb's orchestrator | separate |
| Guest crash / OOM / hang | takes the **whole build** down with it | aeb survives; kill the child |
| Guest state between steps | **shared** — one interpreter persists across every step in the run | fresh per step |
| Isolation | grant-list + `LD_PRELOAD` syscall checks only | kernel namespaces |
| Toolchain at build time | links `lib<lang>` into the binary (needs the dev package) | none — the image carries it |
| Cost at run time | none — no fork | fork/exec + a container runtime |

In-process hosting buys speed and one-process purity. The container
buys survivability, real isolation, and a fresh environment per step.
Neither replaces the other:

- Reach for **in-process hosting** for small, trusted, fast glue —
  a Lua expression, a Python transform — where a fork per call would
  dominate the cost and you want the guest sandboxed by grants.
- Reach for a **container** when the guest is heavy, untrusted, may
  misbehave, needs its own toolchain/filesystem, or must not leak
  state into the next step — i.e. anything you want the build to
  *survive*.

## Practical notes

- The in-process bridge has two compile modes: **linked** (the dev
  library is present — real interpreter) and **stub** (no dev library
  — every entry point returns "not available"). `test_host_lua.ae`
  gates on the return code and passes cleanly either way.
- The installed Aether tree currently ships `contrib/host/<lang>/`
  with `.ae` / `.h` / `README` but **not** `aether_host_<lang>.c`, so
  the bridge source is located from a sibling Aether checkout. Until
  Aether ships the bridge `.c` (or folds the stubs into `libaether`),
  in-process hosting from an installed-only Aether isn't linkable.
- A container needs no Aether-side build support at all — `container.run`
  is a normal builder; the image is the only dependency.
