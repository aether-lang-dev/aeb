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

## The LICENSE boundary — linking a `.so` is fine; vendoring source is not

**zsync is Artistic-2.0; aeb is MIT.** Artistic-2.0 is NOT copyleft — it
explicitly permits linking/embedding into a differently-licensed larger work:

> (7) "You may **aggregate** the Package … with other packages and Distribute
> the resulting aggregation … licensing fees for **other components** in the
> aggregation are permitted."
> (8) "You are permitted to **link** … Standard Versions with other works, to
> **embed the Package in a larger work of your own** … and Distribute the result
> without restriction, provided the result does not expose a direct interface to
> the Package."

So the **cleanest design is: aeb links/loads a prebuilt zsync `.so`** (client +
server), or shells out to the zsync binary — NOT vendor zsync `.ae` source into
aeb's tree. The distinction:

| approach | effect | verdict |
|---|---|---|
| vendor zsync `.ae` SOURCE into aeb | Artistic source files in an MIT tree — muddies provenance | avoid |
| aeb **links a prebuilt zsync `.so`** | clause (7)/(8): aggregation/linking OK; zsync keeps its notices, aeb stays MIT | **preferred** |
| aeb shells out to the zsync binary | arms-length, also clean | fine fallback |

Conditions to honour (all easy): don't charge a licensing fee for zsync itself,
keep zsync's copyright notices alongside the `.so`, and don't re-expose zsync's
own interface as if it were aeb's. The `.so` carries its license with it; aeb's
tree never holds Artistic *source*. (This mirrors how the zsync port itself
already links a small C shim `rcksum/fileio.c` — same pattern, one layer out.)

### The `.so` capability EXISTS — the task is small + mechanical

Earlier worry resolved: **aetherc already emits shared libraries.**
`aetherc --emit=<exe|lib|both>` — "lib produces .so/.dylib" — plus
`--emit-header` for the C embedding header and `--emit-main` for a thin shim.
So "can Aether produce a `.so` aeb can link?" is **yes**, today. (No `c-shared`
tinygo-style gap here.)

What's actually missing is just build targets + a stable export surface in the
zsync port — it currently builds **executables only** (`make bins` →
`fileserver`, `server_dsl_example`; no `.so`). Verified green on Aether 0.257:
`make test` = 94/94, several byte-parity-gated vs the original Go (not bit-rotted).

The client/server split maps to two libs:
- **client** = `zsync/control.ae` (parse `.zsync`) + `zsync/download.ae` (HTTP
  range fetch of changed blocks) → `libzsync_client.so`
- **server** = `cmd/fileserver.ae` / `cmd/serverdsl.ae` (serve file + `.zsync`
  over HTTP) → `libzsync_server.so`

So the work (in the **zsync** repo, keeping it aeb-free and Artistic-2.0) is:
1. add a `make libs` target: `aetherc --emit=lib <client modules> -o
   build/libzsync_client.so` (+ `--emit-header`), same for the server;
2. if the current functions aren't a clean C-ABI, add a thin `extern`-exported
   wrapper `.ae` exposing the two entry points (client: seed + `.zsync` URL →
   fetch; server: path → serve file + `.zsync`).
Then **aeb links those `.so`s** (Artistic §7/§8 — fine; keep the notices). This
is the explicit motivation: pull zsync's client + server `.so` into aeb to use
as the delta transport described above — that is WHY the port was made `.so`-able
in the first place.

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
