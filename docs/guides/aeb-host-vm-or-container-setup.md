# Setting up a host (or VM, or container) for aeb duties

What a machine needs before it can build with aeb, and what it does *not*.
The operational counterpart to `aeb-agent-operating.md` (the agent's HTTP
surface), `agent-provisioning-modes.md` (how the source tree gets there),
and `two-aeb-duality.md` (compile-in-container, execute-on-host).

The deliberate contrast is aeo's `docs/operations/agent-host-setup.md`.
Read it — the shapes are close enough that the *differences* are the whole
point, and the difference is one sentence:

> **aeo ships one self-contained binary and needs no toolchain on the node.
> aeb is a build system: a toolchain on the node is the entire job.**

aeo's agent is Aether compiled to a native executable with every driver
statically linked in; `scp`ing it *is* delivering all of aeo's host-side
logic. aeb cannot work that way, because what a build node does is *run
compilers*. So the two docs answer the same question with opposite
answers, and neither is wrong.

**aeb does not depend on aeo.** They are separate projects. But if you are
standing up a fleet, aeo is a reasonable way to *create* the node (jail,
VM, container, Pi) that you then set up for aeb duties per this doc. That
composition is a convenience, not a coupling.

---

## The three tiers

Pick by what the node must do, not by what looks tidiest.

| Tier | Node holds | Builds what | Cold start |
|---|---|---|---|
| **1. Full node** | Aether + aeb + every language toolchain a target needs | anything | minutes |
| **2. Bootstrap node** | Aether only (or nothing — see below) | anything, after self-setup | ~30s + toolchains |
| **3. Container-out** | a container engine; toolchains live in images | whatever the image has | image pull |

### Tier 1 — full node

The obvious one. Install Aether, install aeb, install `jdk`/`node`/`rust`/…
for the targets involved, done. `aeb --prereqs <target>` states exactly
which toolchains a target needs and `aeb --preflight <target>` fails closed
(exit 3, `unmet-prereqs: [tok …]`) if any are missing — so you can *ask the
build* what the node needs instead of guessing.

Note what aeb deliberately will **not** do: install those toolchains.
Resolving `jdk:21` to a package is unbounded (every toolchain × distro ×
version × arch, drifting constantly), so aeb **states the need and stops**
— see `build-prerequisites-and-provisioning.md`. An agent, a Dockerfile, or
a human resolves it.

### Tier 2 — bootstrap node

The interesting one, and the reason this doc exists. **aeb can rebuild
itself from source on a node that has nothing but a C compiler and a
network.**

Measured on a clean tree, no prebuilt binaries at all:

| Shipped | Size |
|---|---|
| `aeb` (bash trampoline) | 36 KB |
| `tools/*.ae` (27 sources) | 436 KB |
| `lib/` (SDK sources) | 1.2 MB |
| **total** | **1.7 MB** |

→ cold run built 11 of the 27 tools on demand in **28 seconds** and the
build passed. The other 16 (`aeb-agent`, `aeb-vet`, `aeb-sbom`, …) stay
unbuilt until something invokes them, so you pay only for what you use.

And Aether itself is a **binary tarball where one is published**, with a
source build as the fallback:

```
https://github.com/aether-lang-dev/aether/releases/download/v0.463.0/aether-0.463.0-linux-x86_64.tar.gz
```

Measured (v0.472.0, one box): **under 1 s** to download and extract, versus
**69 s** to build the same version from source — and the source path also
needs a C compiler and GNU make on the node, which the prebuilt does not.
The archive ships the complete layout (`bin/`, `include/`,
`lib/libaether.a`, `share/`) with no wrapper directory, so it extracts in
place.

Published assets today: `linux-x86_64`, `macos-arm64`, `macos-x86_64`,
`windows-x86_64.zip`, and — since 0.472.0 only — `freebsd-x86_64`.

**The asset set is not a constant, which is why the source path stays.**
FreeBSD appeared mid-series, and there is **no `linux-arm64` asset at all**
— a Raspberry Pi or a Graviton node has nothing to download. So the
trampoline tries the prebuilt first and falls back to building from source
when the platform is unmapped, the asset is unpublished, or the download
fails. Neither path is "the" path; the fast one is an optimisation over the
one that always works.

So a genuinely cold node is **~1s of Aether + ~28s of aeb ≈ 30 seconds**
where a prebuilt exists, and roughly **70s + 28s ≈ 100 seconds** where one
does not.

> **No published checksum.** Upstream ships no `.sha256` beside these
> assets (checked at 0.472.0), so aeb cannot verify the download against a
> published hash the way it verifies its *own* release payload. The
> integrity gate on this path is the compile probe below — which is a
> weaker guarantee than a hash, and is stated here rather than glossed.
> Fetching over TLS from GitHub is the same trust the source path already
> places in the tarball *it* downloads, so this is not a step down from
> what came before; it is just not a step up.

> **Probe by compiling, not by `--version`.** This bit for real and the
> fix is instructive. v0.449.0's `aetherc` needed `GLIBC_2.38` and died on
> Debian 12 (glibc 2.36) — while `ae --version` reported success, because
> the version banner does not invoke the compiler. A setup script that
> checks `--version` would have declared that toolchain healthy.
>
> **Already fixed upstream**: Aether's `release.yml` pins the Linux build
> to **`ubuntu-22.04` (glibc 2.35)** rather than `ubuntu-latest` (24.04 =
> 2.39), precisely because "ubuntu-latest … broke the release on Debian 12
> (glibc 2.36) and other still-current distros". glibc symbol versioning
> is forward-only, so building on the *oldest* supported runner is what
> makes a binary portable *forward*. Verified: v0.452.0's floor is
> **GLIBC_2.34** and it compiles here; v0.449.0's was 2.38 and did not.
> Re-checked when AETHER_PIN moved to 0.463.0 (for `string.replace_all`):
> both 0.463.0 and 0.472.0 still measure **GLIBC_2.34**, so the bump costs
> no portability.
> Their `docs/release-glibc-portability.md` records musl-static as the
> longer-term plan.
>
> The lesson survives the fix: **a node-setup script must probe by
> actually compiling something**, since `--version` succeeds on a
> toolchain that cannot build. Same class of trap as an `os.exec` probe
> that reports success on a failed command. When the probe fails, fall
> back to the source build.
>
> **The trampoline does this.** It extracts a downloaded prebuilt into a
> temp dir, compiles a one-line program with it, and only then moves the
> tree into the cache. A toolchain that downloads cleanly but cannot
> compile never becomes the cached one — which matters more than it
> sounds, because the cache is checked with `-x .../bin/ae` on every
> later run, so a bad tree admitted once would be reused forever.
> Verified against a deliberately corrupted archive: rejected, not cached,
> fell through to source.

### Tier 3 — container-out: binaries made inside, used outside

The node holds a container engine and (nearly) nothing else; toolchains
live in images. Two distinct shapes, and they are often confused:

**(a) Per-node toolchain images.** `aeb-agent` with `run_on=podman` picks a
toolchain image *per dispatch* from the build's declared prereq
(`rust:1.75` → `aeb-tc:rust-1.75`), so one node serves a cross-language
monorepo without installing a single compiler on the host. See
`agent-container-ladder.md` (Rung 4) and `per-job-agent-image`.

**(b) The two-aeb duality.** A host-side aeb orchestrates the DAG and runs
host-native steps; a container-side aeb compiles against libraries the
immutable host lacks; artifacts land on a shared mount and are used
*outside* the container. This is the "binaries made in a container then
made available outside" case — written up in full in
`two-aeb-duality.md`, proven for seven host languages.

For both, the host requirement is just the engine (podman/docker) plus the
sibling-mount setup — no Aether, no aeb toolchain, no language runtimes.

---

## What a node actually needs

| Need | Tier 1 | Tier 2 | Tier 3 |
|---|---|---|---|
| C compiler (`cc`/`gcc`/MinGW) | yes | yes | no (in-image) |
| Aether (`ae` + `aetherc`) | yes | fetched | no (in-image) |
| aeb tools | installed | self-built | no (in-image) |
| `make` | optional¹ | optional¹ | — |
| language toolchains | yes | yes | no (in-image) |
| container engine | no | no | **yes** |
| network at setup time | no | yes | yes |

¹ `make` is used to *schedule* nodes concurrently, not to build. Without
it aeb runs a sequential in-process loop — same artifacts, no warning, just
serial. `AEB_SCHED=native` removes the dependency entirely (an in-process
scheduler over `os.spawn_proc`/`wait_any`), which matters most on Windows
where the alternative is requiring MSYS `make`. See
`windows-cross-platform-notes.md` §§ 4–5.

### The one thing aeb fetches for itself

aeb pins the Aether release its **own** machinery is built against
(`AETHER_PIN`) and will fetch that version into its own cache
(`~/.cache/aeb/toolchain/aether-<ver>/`) if what is on `PATH` is older.
That copy is **private** — never on `PATH`, never in a system or user
prefix. `which ae` answers the same before and after aeb runs.

This is not a contradiction of "aeb never provisions". The rule is about
the *unbounded* case (everyone else's toolchains); aeb fetching its own
single pinned dependency is bounded and known at release time. See
`../asks/two-aethers-pinned-toolchain-vs-declared-dep.md`.

It tries the **prebuilt release tarball** for the node's platform first
and **falls back to building from source** (upstream's `get.sh`) when
there is no asset for that platform, the download fails, or the downloaded
toolchain fails the compile probe. The fetch is logged to
`~/.cache/aeb/toolchain/fetch-<ver>.log`, which is where the failure
message points.

Off switches: `AETHER=/path/to/ae` (explicit, no pin check),
`AEB_NO_FETCH=1` (assert the floor and explain, exit 2 — never a silent
`E0301` from a generated file), or `AEB_FETCH_SOURCE=1` (skip the
prebuilt and build from source — for reproducing a source-only node, or
when you would rather not trust an unchecksummed download).

---

## Planting an agent on the node

If the node is to serve *remote* builds, it runs `aeb-agent` — an
auth-gated HTTP server. The shape mirrors aeo's plant (one ssh, then the
agent):

```
scp aeb-agent host:/tmp/aeb-agent
ssh host 'chmod +x /tmp/aeb-agent; \
  AEB_AGENT_TOKENS=<secret> setsid /tmp/aeb-agent --workdir /srv/aeb >/tmp/agent.log 2>&1 &'
```

Unlike aeo's agent, this one is **not** self-sufficient: it dispatches to
`aeb`, which needs the toolchain tiers above. Plant the agent *and* satisfy
a tier.

`GET /ping` reports `platform`, `accept`, `busy`, `max_jobs`, `auth`,
**`aeb_version`** and **`aether_version`** — so a requester can see which
toolchain a node would build with *before* dispatching. Today that version
is advisory and nothing compares it; wiring `prereq(b, "aether:X")` to it
is the open half of the two-Aethers ask.

Auth is HMAC-signed, expiring, purpose-bound lease tokens
(`ae1.<purpose>.<expiry>.<sig>`), not flat shared secrets —
`aeb-agent-operating.md` has the mint/verify detail.

---

## What GitHub Releases should hold

**Today: nothing.** `github.com/aether-lang-dev/aeb/releases` is empty —
there are tags (`v0.242`) and no release cut, so all a node can fetch is
GitHub's auto-generated `source.zip`. That happens to work (Tier 2 above
is exactly "unzip the source and let it build itself"), but it is
accidental rather than designed, and it carries no integrity guarantee.

What it *should* hold, in ascending order of ambition:

**1. A source tarball with a published SHA256** — the minimum. Tier 2
already proves 1.7 MB of source bootstraps in ~28 s; pinning its hash turns
`curl | unzip` from trust-me into verify-then-run. aeo's
`agent-host-setup.md` describes exactly this discipline (`<asset>.sha256`,
fail-closed `sha256sum -c`), and the argument transfers unchanged.

**2. A prebuilt `aeb-cli` per platform** (`aeb-cli-linux-x86_64`,
`-macos-arm64`, `-windows-x86_64.exe`). `tools/aeb-cli.ae` is the
Aether-native entrypoint that replaces the bash trampoline; TODO.md records
it as live for the core path, with the remaining work being "exec-handoffs
+ the cutover, not a missing primitive". A single `aeb-cli.exe` that
fetches its own pinned Aether tarball (~1 s) and then rebuilds the rest of
the `aeb-*` tools from a matching source zip (~28 s) is a **self-
bootstrapping single-file distribution** — and the only artifact that
cannot self-bootstrap, since something must compile *it*.

**3. Nothing else.** Resist shipping 27 per-platform tool binaries: they
rebuild in seconds from source, and every extra asset is another thing to
version-skew. The bootstrap chain is the product.

> **A bug this doc's own testing found.** The cold-bootstrap path was
> broken until 2026-07-26: the trampoline built `aeb-main` with **no
> `--lib` flags** and `2>/dev/null`, so on a source-only tree it failed
> with `E0301: Undefined function 'build._exe_suffix'`, the error was
> swallowed, and aeb exec'd a binary that did not exist — exiting 0 with no
> output. Invisible because `make install` always pre-builds `aeb-main`, so
> the path never ran. **It would have broken a source-zip release on day
> one.** Fixed with the correct `--lib` flags and a real error message. Any
> release that leans on Tier 2 should keep a cold-bootstrap test green.

---

## What actually mutates on the node

Know these before pointing aeb at a box you care about:

- **A private Aether may be downloaded** into `~/.cache/aeb/toolchain/`
  (~2.8 MB, or a source build if the prebuilt is glibc-incompatible).
  Never on `PATH`; `rm -rf` on the cache dir is always safe — worst case is
  one re-fetch.
- **aeb's own tools get built** into `tools/` in the aeb tree (gitignored).
- **`target/` appears in each built project** — artifacts, per-node logs,
  `.rc`/`.ms` markers, and the generated orchestrator.
- **The content-addressed cache grows** under `~/.cache/aeb/` (XDG;
  `$AEB_CACHE_DIR` overrides). Safe to delete.
- **Nothing is installed system-wide by aeb.** No package manager is
  invoked, no `~/.local/bin` writes, no `PATH` mutation. That is the
  sharpest contrast with aeo, whose agent *does* self-install substrate
  packages via the host package manager.
- **With an agent**: whatever the dispatched build does, plus the agent's
  workdir (`--workdir`) and its per-slot clones under
  `agent-provisioning-modes.md`'s rules.

---

## Related

- `aeb-agent-operating.md` — the agent's endpoints, auth, lease tokens.
- `agent-provisioning-modes.md` — how the source tree reaches the node.
- `agent-container-ladder.md` — per-node toolchain images (Tier 3a).
- `two-aeb-duality.md` — compile-in-container, execute-on-host (Tier 3b).
- `build-prerequisites-and-provisioning.md` — why aeb states needs and
  never installs them.
- `windows-cross-platform-notes.md` — the `make`/MSYS story and the
  `MSYSTEM=MINGW64` trap.
- `../asks/two-aethers-pinned-toolchain-vs-declared-dep.md` — the pinned
  vs declared Aether split.
- aeo's `docs/operations/agent-host-setup.md` — the one-binary,
  no-toolchain contrast this doc is written against.
