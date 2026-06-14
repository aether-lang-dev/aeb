# Operating `aeb-agent` — running a remote build agent

`aeb-agent` is a standalone, auth-gated HTTP server that accepts **dispatch**
requests (a base commit + an optional uncommitted patch + a purpose) and builds
them, returning a structured verdict. It is the "lease a machine to build *this*,
no commit as a result" capability: ephemeral, fail-closed, and — with lease
auth — scoped to a purpose and a time window.

This is the **operator how-to**: how to stand one up, every flag, the auth
modes, and the three run-modes (with the winbaz `build.sh` recipe). For *why*
the model is shaped this way (policy class, purpose-in-the-token, the
sovereign-peer mesh) read
[`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md);
for the per-dispatch *lifecycle* (fetch→checkout→apply→veto→build) read
[`agent-lifecycle.md`](agent-lifecycle.md).

> **Opt-in, separate binary.** The agent is a network-listening server, not core
> build machinery — `make` deliberately does **not** build it. Build + install
> it on its own:
> ```
> aeb tools/agent/.install.ae      # → ~/.local/bin/aeb-agent
> ```
> (Or `ae build tools/aeb-agent.ae --lib lib -o <bin>`.) The lessor-side mint
> tool is the same: `aeb tools/lease/.install.ae` → `~/.local/bin/aeb-lease`.

---

## Endpoints

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /health` | open | dumb liveness (`ok`) — no auth, reveals nothing |
| `GET /ping`   | required | identity + capability descriptor (`platform`, `accept`, `busy`, `max_jobs`, `auth`, **`aeb_version`**, **`aether_version`**) — an authorized prober confirms it's really an aeb-agent, and learns *which toolchain it would build with*, before dispatching. `aether_version` is the **live** `aetherc` (what it builds with now); useful to gate a build whose feature needs a minimum Aether across a mixed-version fleet. |
| `POST /dispatch` | required | the build request (see [the wire](#the-dispatch-wire)) |

The agent is **fail-closed**: with no auth configured it refuses *all* dispatches
(and `/ping`). Auth is lease tokens (`--lease-secrets`), below.

---

## Capacity & serialization (`--max-jobs N`)

The agent serves **N build slots** (`--max-jobs N`, default **1**). Each accepted
dispatch atomically claims a free slot; when all N are taken, further dispatches
get **`503 busy`** (status `busy`) — the originator can fall back or retry. The
slot is released on every exit path (done / failed / vetoed / prep-failed), and a
prior crash's leaked slots are cleared at startup.

The slot is an atomic lock-dir (`mkdir`-based — race-safe across the server's
worker threads *and* across processes; co-located agents key their slots by port).
The idiomatic actor-owned-state version awaits a synchronous actor `call`
([aether#736](https://github.com/aether-lang-org/aether/issues/736)); the lock-dir
ships now and is crash-robust.

**Per-slot tree isolation:** slot `i` builds in **`<workdir>/<i>`** (its own
checkout), so `--max-jobs N` runs N genuinely-concurrent builds with no tree
clobbering. How each `<workdir>/<i>` is provisioned (pre-cloned, branch-tracking,
or auto-cloned) is the **provisioning mode** — see
[`agent-provisioning-modes.md`](agent-provisioning-modes.md) and
`--provision-modes`. A 64-core box can declare a large N; a NUC/Mac, 1.

---

## Auth — lease tokens (`--lease-secrets FILE`, required)

There is **one** auth mode, and it is **required** — without `--lease-secrets`
the agent is fail-closed (refuses all). HMAC-signed, **expiring**,
**purpose-bound** tokens. A lease is one bearer string:

```
ae1.<purpose>.<expiry-unix-ms>.<hmac_sha256_hex>
```

The agent **verifies** (signature against the shared secret, not expired, and
the embedded purpose *covers* the dispatch's purpose) and **never mints**.
Issuance lives with the lessor, who holds the same secret and mints with
`aeb-lease`:

```bash
# Operator (lessor) mints a 30-minute lease scoped to preint/* :
aeb-lease --secret /etc/aeb/lease.secret --purpose 'preint/*' --ttl-mins 30
# → ae1.preint/*.1781376938918.e93854ad54d80...    (hand this to the requester)
```

- The secret is read from a **file** (never the command line). `--lease-secrets`
  holds **one or more** secrets, one per non-blank line (`#` comments ignored).
- **Zero-downtime rotation:** a token signed by **any** listed secret is
  accepted. To rotate without killing live leases: add the new secret as a
  second line → switch minters to it → once all old-secret leases have expired
  (≤ max TTL), drop the old line. (A list is for *rotation*, **not roles** — a
  secret is a key, not a role; any accepted secret can mint any purpose. Keep the
  list short: an unknown token costs one HMAC per secret.)
- **Purpose binding** uses the scope glob: a `preint/*` lease covers
  `preint/rust`, but a `preint/rust` lease does **not** cover `ci/main`. A leaked
  lease can't be replayed outside its purpose.
- **Canonical purpose grammar (enforced at mint):** a `--purpose` must be a
  lowercase slash-path — segments of `[a-z0-9_-]+` separated by `/`, with an
  optional trailing `/*` scope (`preint/phammant/rust`, `ci/aether/main`,
  `preint/macos/*`). `aeb-lease` rejects spaces, uppercase, `.`, unicode, empty
  segments, and a bare `*` — fail-closed, naming the offending character. The
  purpose is *inside the signed bytes*, so it must read back unambiguously across
  every system ("a purpose in a token", constrained at issuance).
- **Revocation** today = rotate the secret (kills every outstanding lease).
- Refusal reasons (expired / bad-signature / wrong-purpose) are logged but **not**
  returned on the wire — a caller learns only `rejected`.

See [`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
§ "Lease tokens" for the trust model and what's still design (issuance-side
constraint, per-token revocation, asymmetric keys).

---

## Run modes — `--run-on host | podman | vm`

Set once at agent start; the same for every dispatch (per-dispatch `image` /
`command` fields tune it within the mode).

### `host` (default)

`cd <workdir> && aeb <target>` on the agent's own box. Needs the toolchain
installed locally. Nothing else to configure.

```bash
aeb-agent --port 9440 --accept 'preint/*' \
          --workdir ~/checkout --repo ~/checkout \
          --lease-secrets /etc/aeb/lease.secret
```

**Raw command on host** — like the vm path, a **non-aeb project** (build.sh /
make / cmake, no `.build.ae`) can run its own build command **natively in the
workdir** via the dispatch's `command` field, gated by `--allow-vm-command`
(fail-closed; a `command` without the flag is `rejected`). No ssh, no transport,
no shell-wrapping — the agent IS on the build box. This is the setup for a
dedicated native builder, e.g. a **Mac mini doing AppKit builds** of aether-ui:

```bash
# On the Mac mini (aeb already installed there):
aeb-agent --host 0.0.0.0 --port 9440 --accept 'preint/*' \
          --workdir ~/aether-ui --repo ~/aether-ui \
          --run-on host --allow-vm-command \
          --lease-secrets ~/.aeb/lease.secret
```
```jsonc
// Requester's dispatch — "command" runs in ~/aether-ui on the Mac:
{ "guid":"…", "purpose":"preint/macos", "target":".build.ae",
  "command":"./build.sh example_counter.ae build/counter" }
// → clang compiles aether_ui_macos.m against AppKit; exit code → pass/fail.
```

(`run_on=host` is the right mode when the agent runs **on** the build machine.
Use `run_on=vm` when a *different* box dispatches to it over ssh.)

### `podman` — build in a toolchain container

The dispatched build's compile runs **inside `--ctr-image`** (the aeb-ctr
two-phase duality: compile in the container, execute on the host), so a
toolchain-less / immutable host still builds. `--ctr-image` is required.

A dispatch may request a **per-job image** via the `image` field — a Rust job
asks for `aeb-tc:rust`, a JDK job `aeb-tc:jdk21` — so **one** agent serves
fine-grained jobs whose layers the bare host lacks. That override is honoured
only if it matches `--allow-image GLOB` (`aeb-tc:*` = prefix, `*` = any); without
`--allow-image` only the agent's own `--ctr-image` runs (a leased agent can't be
talked into pulling an arbitrary image). aeb owns **no** token→image map — the
*requester* resolves `aeb --prereqs <target>` → an image and puts it in the
dispatch.

```bash
aeb-agent --port 9440 --accept 'preint/*' \
          --workdir ~/checkout --repo ~/checkout \
          --run-on podman --ctr-image aeb-tc:slim --allow-image 'aeb-tc:*' \
          --lease-secrets /etc/aeb/lease.secret
```

### `vm` — build on an SSH-reachable VM

Ship the prepared tree to a VM (`--vm-host`, an `~/.ssh/config` alias that owns
the key/ProxyJump), build there on the VM's own toolchain, bring artifacts back.
`--vm-host` is required; fail-closed without it. The VM-host *spawning* the VM
(virsh start/clone) is a later layer — today the VM is already-running and
SSH-reachable.

Two build **verbs**:

1. **Default — `aeb <target>`** on the VM (the VM has its own `aeb` + toolchain).
2. **Raw `command`** — for a **non-aeb project** (build.sh / make / cmake, no
   `.build.ae`): the dispatch's `command` field runs verbatim in the tree root,
   its exit code is the verdict (aeb parses nothing). This is arbitrary command
   execution on the VM, so it is **opt-in + fail-closed** via
   `--allow-vm-command`; a `command` dispatch to an agent without that flag is
   `rejected`. In raw mode the veto's AST-emit is skipped (no aeb target) but
   Tier-A secret/banned-marker scanning still runs.

Two transport conveniences make a bare VM work with **zero install**:

- **Transport auto-fallback**: rsync both ways when the VM has it; otherwise
  `tar | ssh` (push) and `ssh cat` (fetch). A VM with no rsync needs nothing
  installed.
- **`--vm-shell PREFIX`**: a VM whose *default* ssh shell isn't POSIX (a Windows
  VM's bare ssh lands in cmd.exe, which can't `cd … && …`) — this wraps every
  remote command as `PREFIX "<cmd>"`. For an MSYS2 Windows VM:
  `--vm-shell 'C:\msys64\usr\bin\bash.exe -lc'`. The inner command must stay
  double-quote-free (the wrapper quotes it).

#### Recipe: build a `build.sh` project on a Windows VM (proven on winbaz)

```bash
# Operator: an agent that dispatches raw commands to the winbaz Windows VM.
aeb-agent --port 9440 --accept 'preint/*' \
          --workdir /path/to/project --repo /path/to/project \
          --run-on vm --vm-host winbaz \
          --vm-shell 'C:\msys64\usr\bin\bash.exe -lc' \
          --allow-vm-command \
          --lease-secrets /etc/aeb/lease.secret
```
```jsonc
// Requester's dispatch (the "command" carries the build). Note: bash -lc does
// NOT put /mingw64/bin on PATH, so the command exports it (the requester owns
// the command, not aeb):
{
  "guid": "…", "purpose": "preint/x", "target": ".build.ae",
  "command": "export PATH=/mingw64/bin:/usr/bin:$PATH; ./build.sh hello.c hello.exe && ./hello.exe"
}
// → ships the tree (tar, no rsync needed), gcc-compiles, runs the .exe on
//    Windows, returns {"status":"done","result":"pass", "log":"…"}.
```

No `.build.ae`, no `aeb`, no `rsync` on the VM is required.

---

## The dispatch wire

`POST /dispatch`, header `X-AEB-Token: <token-or-lease>`, flat-JSON body:

| field | meaning |
|---|---|
| `guid` | caller's request id (echoed in the verdict) |
| `target` | the aeb target (`aeb <target>`); a placeholder in raw-command mode |
| `purpose` | the lease/scope purpose (e.g. `preint/phammant/rust`); default `preint` |
| `ref`, `hash` | fetch-base: agent does `git fetch origin <ref> && git checkout <hash>` ("" = build the workdir as-is) |
| `patch_b64` | base64 of an uncommitted unified diff, `git apply`'d onto the base ("" = none) |
| `image` | *(run_on=podman)* per-job toolchain image override; gated by `--allow-image` |
| `command` | *(run_on=host or vm)* raw build command; gated by `--allow-vm-command` |

Verdict (response): `{ "guid", "status": done|rejected|busy|vetoed|prep-failed,
"result": pass|fail, "log": "<tail>", "artifacts": [...] }`.

### Firing a dispatch

- **From aeb itself:** `aeb --use-remote-agents <target>` with `--agents <pool>`
  (`$AEB_AGENTS`) leases a node from the pool and dispatches the working-tree
  diff. For a run_on=vm raw build, set `AEB_VM_COMMAND` to the build line.
- **By hand / from CI:** POST the JSON above (e.g. `curl`), or build the body
  with `agent.dispatch_request_json_ex(guid, target, purpose, ref, hash,
  patch_b64, image, command)`.

---

## Flag reference

```
--host H              bind address (default 127.0.0.1; 0.0.0.0 to be reachable off-box)
--allow-from IPS      comma-list of exact source IPs allowed to dispatch (before auth, fail-closed; unset = no restriction)
--port N              listen port (default 9440)
--accept GLOB         purpose scope to accept (default 'preint/*')
--workdir DIR         directory the agent runs builds in (default '.')
--repo DIR            git repo to fetch/checkout/apply into (default = --workdir)
--max-jobs N          build-slot capacity: N concurrent builds, over-capacity dispatches get 503 busy (default 1; each slot builds in <workdir>/<i>; see --provision-modes)
--scope NAME          scope label for display (default 'preint')

# Auth (REQUIRED; without it the agent refuses ALL — fail-closed)
--lease-secrets FILE  HMAC lease auth (signed/expiring/purpose-bound); one secret per line (multiple = rotation)

# Run mode
--run-on KIND         host (default) | podman | vm
--ctr-image IMG       toolchain image for --run-on podman (required then)
--allow-image GLOB    let a dispatch's "image" override --ctr-image if it matches (else only --ctr-image)
--vm-host HOST        ssh target/alias for --run-on vm (required then; config may ProxyJump)
--vm-dir DIR          remote build dir on the VM (default /tmp/aeb-vm-build)
--vm-shell PFX        wrap VM commands as PFX "<cmd>" for a non-POSIX default ssh shell (e.g. cmd.exe)
--allow-vm-command    honour a dispatch's "command" on --run-on host OR vm (run build.sh/make); off by default
```

(`aeb-agent --help` prints this list. `aeb-lease --help` covers the mint tool.)

---

## Security posture (read before exposing off-box)

- **Fail-closed everywhere:** no auth → refuse all; `--run-on podman` without
  `--ctr-image`, `--run-on vm` without `--vm-host`, unreadable `--lease-secret`
  → refuse to *start*. A `command` without `--allow-vm-command`, or an `image`
  outside `--allow-image` → reject the dispatch.
- **Arbitrary execution is opt-in:** `--allow-vm-command` (run any command on the
  VM) and `--allow-image` (pull any matching image) are both off by default. A
  leased agent can't be coerced into either.
- **Source-IP allow-list (`--allow-from`):** a comma-list of exact IPs, checked
  **before** auth against the **trusted** TCP peer address
  (`getpeername`, Aether ≥0.256 — *not* the spoofable `X-Forwarded-For` header,
  so it's a real control). An off-list peer gets 403 on `/dispatch` *and* `/ping`
  (it can't even fingerprint the agent). Fail-closed: a configured list with an
  unreadable peer addr refuses. Defense-in-depth **under** auth, not a
  replacement — bind narrowly (`--host` loopback/one NIC) and/or use a host
  firewall too; for SSH-tunnelled access the peer is `127.0.0.1`, so `--allow-from
  127.0.0.1` pins it to the tunnel. (Exact IPs only today; CIDR is a later
  thickening.)
- **The build is still unsandboxed** on the run target (the containment layer —
  `spawn_sandboxed` / the container backstop — is design; see
  [`build-veto-and-sandbox.md`](build-veto-and-sandbox.md)). Lease auth bounds
  *who and for what*; it does not yet contain *what the build does*.
- **Lease verify ⇒ could-mint** (HMAC is symmetric): the agent's `--lease-secret`
  is effectively a minting key. Fine for a single-tenant lessor; guard it
  accordingly. Asymmetric keys are design.
