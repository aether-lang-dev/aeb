# aeb's container grammar as an instance of the principles of containment

Status: **design / position.** Not a feature spec — the framing that explains
*why* the container grammar (`container.image` / a future `container.start` /
`container.run` / `container.service`) is shaped the way it is, and *where* it
can run at full fidelity versus degraded. Written the day we hit the boundary
on a Bazzite (immutable) host and understood it was a boundary, not a bug.

Reference: Paul Hammant, **"The Principles of Containment"** (paulhammant.com,
2016-12-14). The load-bearing claim, quoted:

> The thing doing the containing can see the component it is containing. The
> latter really only suspects it is contained, and cannot casually reach the
> container to interact with it explicitly, unless the container configured it
> to do so. … these should be nestable and each contained item be further
> restricted without knowledge of its nesting depth.

Two properties to hold onto: containment is **directional** (container sees in;
contained cannot casually reach out), and it is **nestable** (each layer
restricts the next, which need not know its own depth).

## The grammar IS containment, expressed as a build DSL

aeb's container SDK lets a `.ae` file declare a container the way the 2016 post
describes Exhibit 3 (Docker-style containers): the container is configured *from
the outside* with exactly the inputs/outputs it's granted — ports, mounts, the
tokens file — and the contained service runs as if it were on a normal host,
only suspecting its confinement.

```
container.image(b)   { from(...) run_step(...) expose(...) entrypoint(...) }  # build the image
container.service(b) { image_ref(...) publish(...) volume(...,:Z) name(...) }  # run it, configured from outside  (DESIGN)
```

Every setter is the container (aeb) *configuring* the contained: `publish`
opens an incoming port the contained didn't choose; `volume` grants a file the
contained couldn't otherwise see; `expose` declares an output. The contained
`aeb-agent` receives these as its environment and cannot reach back to
reconfigure aeb. That directionality is the post's claim, in DSL form.

## The nesting we actually built this session

The principle's *nestable* clause is not aspirational here — it's the
architecture that emerged across the agent work, four layers deep, each
restricting the next without the next knowing its depth:

```
aeb (control plane)                       sees + configures everything below
  └─ aeb-agent container                  granted ports/mounts/tokens; only suspects confinement
       └─ the leased pre-integration build agent's --workdir/--repo bound the build
            └─ spawn_sandboxed build subtree   fs/exec/tcp grants (docs/design/build-veto-and-sandbox.md)
```

- aeb contains the **agent container** (Exhibit 3): the deploy configures its
  published port, its tokens mount (`:Z`), its workdir. The agent only knows
  it's listening on 9440 — not that podman placed it there.
- the agent contains the **leased build**: `--repo`/`--workdir` bound where a
  dispatched build may fetch/checkout/patch/run (`docs/design/agent-lifecycle.md`).
  The build doesn't know it's leased.
- the build is contained again by **`spawn_sandboxed`**: an `LD_PRELOAD` grant
  list (fs_read/fs_write/exec/tcp) the build subtree can't see or escape
  (`docs/design/build-veto-and-sandbox.md` § "Veto is policy; containment is enforcement").
  This is the post's "further restricted without knowledge of its nesting
  depth" exactly — `gcc`, `cc1`, `javac` all run gated and none of them know.

Each boundary is a place where "the container can see the contained; the
contained only suspects." aeb didn't set out to implement the 2016 post; the
post turns out to describe what a correct leased-build system *is*.

## The boundary we hit: control plane vs. an immutable host

For aeb to be the *top* container — the control plane that builds and starts
the agent container — aeb itself must run on the host with a real toolchain
(`gcc`, the Aether compiler) and `podman`. On a **mutable** Linux host (Debian,
Arch, a traditional Fedora) this works at full fidelity: `aeb .image.ae` builds
the image, `aeb .service.ae` starts it — the whole grammar, natively, the
control plane the post's diagram implies.

On an **immutable host** (Bazzite / Fedora Atomic / Silverblue-family) it does
not — and the reason is itself containment, applied at a layer that crosses
purposes:

> The immutable OS contains *the operator* out of the host's mutable userspace,
> to keep the host an unbreakable appliance. That serves the host vendor's
> goal. But it simultaneously denies the operator the ability to *be the
> container* — to run aeb on the host as the control plane. The directionality
> that protects the host is the directionality that blocks the control plane.

Concretely: there is no `gcc` and no place to install a toolchain on the bare
Bazzite host (by design), so `aetherc` cannot compile there, so `aeb` cannot
run there. `podman` *is* present (it's how an immutable host gets a mutable
userspace at all) — which is the tell: **on an immutable host, the only
sanctioned place to do mutable work is inside a container.** The host says "do
your containing from within a container," which is coherent, but it means aeb
can't be the *outermost* container; it has to be one level in.

## Full-featured vs. degraded — the platform-conditional grammar

The container grammar is therefore **platform-conditional**, and that's the
honest design statement, not a TODO to make disappear:

| Host kind | `image` | `start`/`service`/`run` | aeb as control plane |
|---|---|---|---|
| **Mutable** (Debian, Arch, classic Fedora) | builds natively | runs natively | ✓ full — aeb is the outermost container |
| **Immutable** (Bazzite, Atomic, Silverblue) | **emit-only** (generate Dockerfile, build elsewhere) | not on the host | ✗ aeb can't be outermost; runs one level in, or off-box |

The **emit-only** path (`AEB_CONTAINER_EMIT_ONLY`) is precisely the
**immutable-host adapter**: aeb runs where the toolchain *is* (a dev box, CI, a
mutable peer) to *generate* the Dockerfile from the inline DSL, and a host that
has only `podman` builds it. aeb still owns the recipe end-to-end; it just
can't be co-resident with `podman build` on an immutable host. The grammar
degrades gracefully — `image` becomes generate-not-build — rather than failing.

Two other ways to run the grammar's *build/run* verbs on an immutable host,
both keeping aeb one level in rather than fighting the host:
- **aeb-in-container** — run aeb inside a toolchain-bearing image, mounting the
  host's `podman` socket so its `podman build`/`run` act on the host. Idiomatic
  for the platform; adds rootless-nesting complexity.
- **off-box control plane** — aeb on a mutable peer drives the immutable host
  over the network (this is, in fact, what `aeb --use-remote-agents` already
  is: a mutable originator leasing a contained agent).

## The OS that doesn't exist yet

The thing we wanted — and the reason this doc exists — is an OS that is **both**
an operator-controllable control plane **and** strongly self-containing: where
aeb could run on the host *as* the outermost container (build/start/run the
full grammar) while the host still gave the appliance-grade integrity that
immutability buys. Today you pick one:

- mutable host → full control-plane grammar, weaker host integrity;
- immutable host → strong host integrity, aeb relegated to emit-only / in-a-
  container / off-box.

No mainstream Linux gives both at once. The principles of containment describe
the *shape* of the system we'd build on such an OS — directional, nestable,
each layer granting the next only what it needs. aeb implements that shape as
far as today's hosts allow; the emit-only adapter is where the implementation
meets the boundary of what the host will permit. When (if) the
mutable-yet-containing OS arrives, the grammar is already written for it — only
the adapter falls away.

## What this means for the code

- Keep the full grammar (`image` now; `start`/`service`/`run` next) as the
  target shape — it's correct for the mutable-host and the eventual
  nirvana-OS case, and it's the DSL expression of the containment principle.
- Treat `AEB_CONTAINER_EMIT_ONLY` as the **named immutable-host adapter**, not
  a workaround — document it as such where it lives.
- Don't try to give aeb a toolchain on an immutable host. That's fighting the
  host's own (legitimate) containment. Run aeb where it belongs — a mutable
  peer, or inside a container — and let it contain *downward* from there.
