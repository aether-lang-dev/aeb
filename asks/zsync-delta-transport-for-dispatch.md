# zsync as a third, ssh-free, delta transport for dispatch (alongside rsync/tar/patch)

**Filed by**: aeb Claude, 2026-06-15, after the RBE / two-shapes discussion.
**Status**: design note — not yet implemented. Prereq: re-verify the Aether
zsync port (`../zsync`) still builds/tests green on current Aether.

## The idea

aeb already moves a build's source onto an agent three ways:

- **git fetch/checkout** (Shape 1, committed build),
- **`patch_b64`** inline in the dispatch (Shape 2, patch-on-base — an
  uncommitted git diff over a pinned base),
- and for `run_on=vm`, a TREE transport that is **rsync (needs ssh) with a
  tar-stream fallback** (`tools/aeb-agent.ae` `_vm_push`, `_vm_has_rsync`).

Add a **fourth, content-delta transport: zsync** — fetch only the *changed
blocks* of a file/tree vs. a version the agent already holds, **over plain HTTP,
no ssh, no special server**. This is exactly zsync's contract (rsync rolling
checksum + a `.zsync` control file over HTTP range requests) and exactly aeb's
agent ethos (lease-gated HTTP, no shell account on the build box).

There is a pure-Aether port of zsync at `../zsync` (rsync engine, `.zsync`
format, HTTP-range downloader, native test server — all Aether + a small C shim
for positional file I/O). It is destined for `aether/std/http/zsync`.

## Why it composes WITH patch-on-base (not instead of)

They solve different halves and stack cleanly:

| | what travels | granularity | best for |
|---|---|---|---|
| `patch_b64` | a git diff | source lines | the human's uncommitted change |
| **zsync** | changed binary blocks | rsync block-delta | large/binary INPUTS the agent partly holds |

So a dispatch can use **zsync to get the base tree/inputs there cheaply** (delta
over what the slot already cached — vendored crates, the `libs/` tree, big test
fixtures, prebuilt artifacts, a tree with no clean git base) and **`patch_b64`
to carry the source change on top**. zsync moves the bulk; the patch moves the
intent.

## Why it's a good fit for aeb specifically

- **The ssh-free delta transport the `run_on=vm` rsync fallback wanted to be.**
  rsync needs an ssh/rsh account; tar ships the whole tree every time. zsync is
  delta-over-HTTP with no server requirement — same no-special-server principle
  as the lease-gated agent.
- **Attacks the "we ship whole trees" RBE gap.** Hyperscale RBE (Bazel) streams
  content-addressed blobs through a CAS and does Build-without-the-Bytes; aeb
  currently rsyncs/tars/bind-mounts whole trees. zsync is a lightweight,
  content-delta step in that direction — pull only what changed.
- **Immutable-host friendly.** No daemon, no account — a `.zsync` file beside
  the artifact is enough; the agent's existing HTTP server can host it.

## Wire shape (sketch)

Mirror the existing rsync|tar selection in `_vm_push`, adding `zsync`:

- **Agent (server side):** the slot already holds version N (pre-cloned/cached
  from a prior dispatch). The agent generates a `.zsync` control file for the
  target version and serves it + the file over its existing HTTP listener.
- **Requester / agent (client side):** instead of tar-the-whole-tree, run zsync
  against the `.zsync` URL with version N as the seed → only changed blocks
  transfer → version N+1 lands.
- Selection: a `--transport rsync|tar|zsync` agent flag and/or a per-dispatch
  hint, defaulting as today (rsync if available, else tar); zsync chosen when
  the slot has a usable seed version and the source exposes a `.zsync`.

## The LICENSE boundary (load-bearing — do not muddy)

**zsync is Artistic-2.0; aeb is MIT.** The port deliberately keeps ITSELF free
of any aeb/aeocha dependency so it can stay Artistic and land in Aether's stdlib
(`aether/std/http/zsync`). aeb must therefore **INVOKE zsync as an external tool
/ HTTP protocol** — the same way it shells out to `git`, `cargo`, `rsync` — and
must **NOT vendor or import zsync source** (that would pull Artistic code into an
MIT tree). Concretely: aeb depends on the zsync *binary* (or the
`std.http.zsync` API once it lands in Aether, under Aether's own license terms),
not on `../zsync`'s sources. This is the same arms-length relationship aeb has
with every other external tool, so it's clean — but it must be stated, because
inverting it would relicense-contaminate aeb.

## Prerequisite

The `../zsync` port "might need updating" (its Makefile pins
`aether/build/ae` 0.218+; current Aether is 0.257). Before wiring anything,
`cd ../zsync && make test` (≈94 parity-gated asserts vs the Go oracle) must be
green on current Aether, and `aether/std/http/zsync` should be the agreed home
for the API aeb would call.

## Acceptance (when implemented)

A dispatch whose source tree differs from the agent slot's cached version by a
small delta transfers ONLY the changed blocks over HTTP (no ssh, no full-tree
tar), then builds — proven by a transfer-bytes count far below the tree size,
and result:pass. Composes with `patch_b64` (zsync the base, patch the change).

## Cross-ref

- `tools/aeb-agent.ae` `_vm_push` / `_vm_has_rsync` (the transport seam)
- `docs/agent-container-ladder.md` (RBE shapes; the "ships whole trees" gap)
- `../zsync` (the Aether port) + its `LLM.md` (Artistic-2.0, no-aeb-dep rule)
