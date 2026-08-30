# What's left: aeb releases, and aeo-infra → aeb build nodes

**Filed by**: Paul + LLM session, 2026-07-27.
**Status**: **PLAN — nothing here is built yet.** The vision is: `aeci`
stands up infrastructure via `aeo`, and those nodes immediately become aeb
build nodes. This enumerates what aeb still owes that story, in dependency
order, with what is already true marked as such.

## The family seam (why this is aeb's problem at all)

```
aether  the language
aeb     builds artifacts          <- this repo
aeo     stands up + contains nodes
aeci    watches repos over time -> per-branch pipelines
```

aeci **shells out** to aeb across a CLI boundary — its own docs are
explicit: *"drives `aeo` for containment and shells to `aeb` for build"*,
*"across a file-and-CLI boundary rather than linking them"*. So aeb owes
exactly one thing: **be fetchable and self-sufficient on a node aeci did
not prepare by hand.** Nothing about aeci's design needs to change; aeb
just has to be gettable.

## Already true (measured, not assumed)

- **aeb self-bootstraps from source.** ~440 KB packaged (trampoline +
  27 `.ae` sources + `lib/`, minus the 7.3 MB Maven resolver only
  `lib/maven` needs), zero prebuilt binaries → builds the tools it needs
  on demand in **~27 s**, build green. (Fixed a latent bug to get there: the
  cold path built `aeb-main` with no `--lib` and `2>/dev/null`, so it died
  with `E0301` and exited 0 with no output.)
- **aeb fetches its own pinned Aether**, privately, never on `PATH`.
  `AETHER_PIN` (floor) / `AETHER_FETCH` (which release) split, cache keyed
  on the fetch version. **Prefers the prebuilt tarball, falls back to a
  source build** — see below.
- **Aether ships prebuilt tarballs** for linux-x86_64, macos-arm64,
  macos-x86_64, windows-x86_64, and (since 0.472.0) freebsd-x86_64 —
  measured under 1 s to fetch+extract vs 69 s to build, and no C compiler
  needed on the node. Built on `ubuntu-22.04` for a portable glibc floor.

  *Corrected 2026-08-01*: this bullet previously read as though the
  prebuilt was what aeb fetched. It was not. The trampoline shelled out to
  upstream's `get.sh`, which is a **source** installer (source tarball +
  `make install`) — it has no platform detection and cannot consume a
  prebuilt at all. Only `release.yml`'s verify step used the fast path,
  under a comment claiming it did so "the same way a cold node would",
  which was untrue. The trampoline now tries the prebuilt first and falls
  back to `get.sh`. The fallback is not vestigial: there is **no
  `linux-arm64` asset**, so a Pi or Graviton node still builds from
  source, and upstream publishes no `.sha256`, so the compile probe — not
  a hash — is the integrity gate on the fast path.
- **`tools/aeb-cli` drives a real build end to end.** Verified: `aeb-cli
  app/.tests.ae` → `1/1 PASS`. The native entrypoint is not hypothetical.
- **`aeb-agent` exists** with lease auth, `/ping` capability reporting,
  provisioning modes, and per-node toolchain images.

## The gaps, in dependency order

### 1. aeb has no releases at all — the blocker

`github.com/aether-lang-dev/aeb/releases` is **empty**. `autotag.yml` tags
every push to `main` (`v0.242`) but cuts no release, so the only fetchable
artifact is GitHub's auto-generated source tarball for a tag. That happens
to work — it is exactly the 1.7 MB self-bootstrap above — but it is
accidental, unversioned as an *artifact*, and carries no integrity
guarantee.

**Needed**: a `release.yml`, triggered on the existing tags, publishing:

| Asset | Why |
|---|---|
| `aeb-src-<tag>.tar.gz` + `.sha256` | the ~440 KB bootstrap payload; SHA turns `curl \| tar` into verify-then-run |
| `aeb-cli-<os>-<arch>[.exe]` + `.sha256` | the single-file entrypoint (see gap 2) |

Deliberately **not** 27 per-platform tool binaries: they rebuild in seconds
from source, and each extra asset is another version-skew surface. The
bootstrap chain is the product.

Copy aeo's discipline verbatim (`docs/releasing-aeo.md`,
`docs/operations/agent-host-setup.md`): one tag → one immutable asset set →
SHA256s retained forever, a companion `<asset>.sha256`, and a run-summary
table to pin. Their plant snippet is the model:

```
SHA=<pinned from a prior cut>
curl -fsSL .../releases/download/<tag>/$ASSET -o /tmp/$ASSET
echo "$SHA  /tmp/$ASSET" | sha256sum -c -    # fail-closed
```

Not adopting aeo's `gcc -static`: measured, `aeb-cli` links only libc
(no openssl/zlib/nghttp2 — it imports no `std.http` or crypto) with a
`GLIBC_2.34` floor. The runtime-deps axis aeo had to remove does not exist
here. Revisit if `aeb-cli` ever grows those imports.

### 2. `aeb-cli` cannot self-bootstrap — the fetch logic is bash-only

This is the real work. The pinned-Aether fetch lives entirely in the bash
trampoline; `tools/aeb-cli.ae` and `tools/aebcli/module.ae` contain **zero**
references to `AETHER_PIN`/`AETHER_FETCH`. So a released `aeb-cli.exe`
dropped on a bare node cannot do step 1 of its own bootstrap.

**Needed**: port the fetch to Aether so `aeb-cli` can:

1. read `AETHER_PIN` / `AETHER_FETCH`,
2. probe the `ae` on `PATH` — **by compiling, not by `--version`** (the
   version banner succeeds on a toolchain whose `aetherc` is
   glibc-broken; this bit for real),
3. fetch the platform tarball into `~/.cache/aeb/toolchain/aether-<ver>/`
   and verify its SHA,
4. fetch its own matching `aeb-src-<tag>.tar.gz`, verify, unpack,
5. lazy-build the `aeb-*` tools from it.

`std.http.client` is native and `lib/fetch` already implements the
http_archive shape (fetch + verify + unpack), so this is wiring rather
than invention. Note the circularity, and state it rather than discover
it: **`aeb-cli` is the one artifact that cannot self-bootstrap** — some
release machine must compile it.

Cold-node budget once this lands: **~1 s Aether + ~28 s aeb ≈ 30 s.**

### 3. Nothing consumes the agent's reported toolchain version

`aeb-agent`'s `/ping` already reports `aeb_version` and `aether_version`,
and **nothing compares them to what a build needs**. With `aether` as a
canonical prereq token, a requester could refuse to dispatch to a node
whose toolchain is too old, instead of discovering it as a compile error.
This is the open half of
`two-aethers-pinned-toolchain-vs-declared-dep.md`.

### 4. No aeo→aeb handoff is written down

aeo plants an agent and self-installs substrate; aeb needs a toolchain
tier. The composition — *use aeo to create the node, then set it up for
aeb duties* — is described from aeb's side in
`docs/guides/aeb-host-vm-or-container-setup.md`, but there is no worked
end-to-end example. Concretely missing: a script/doc that takes an
aeo-created node and, in one pass, plants `aeb-cli` + a pinned SHA and
leaves a node that answers `aeb --list`.

**This is deliberately a doc/example, not a feature.** aeb must not grow a
dependency on aeo; the handoff is a composition the operator (or aeci)
performs.

## Order to do them in

1. ~~**`release.yml` publishing the source tarball + SHA.**~~ **DONE**
   (this commit). Cuts on the existing `v0.*` tags, stages a ~440 KB
   payload, and — importantly — **verifies in CI that the payload actually
   bootstraps** (unpack on a clean runner, fetch the pinned Aether, probe
   it by compiling, build a fixture to green) before publishing. A release
   that looks official and fails on the user's node is worse than none.
   aeci can consume this immediately with verify-then-`curl | tar`.
2. **Port the fetch logic into `aeb-cli`.** The substantive change; turns
   `aeb-cli` into a genuine single-file bootstrap.
3. **Add `aeb-cli` binaries to the release.** Falls out of (2) once
   `aeb-cli` is worth shipping alone.
4. **Wire `/ping`'s versions to prereq comparison.** Independent of
   1–3; do it when a mixed-version fleet actually exists.
5. **Write the aeo→aeb worked example.** Last, because it is the
   documentation *of* 1–3.

## What would make this wrong

Worth stating so the plan can be falsified rather than merely followed:

- **If aeci prefers containers to hosts**, gaps 1–3 matter far less — a
  toolchain image (Tier 3 in the setup doc) skips bootstrapping entirely,
  and the release only needs to be a base-image layer. Check aeci's
  intended substrate before building the single-file bootstrap.
- **If nodes are long-lived**, a 30 s cold start is irrelevant and even
  the source-only path is fine; the release is then purely about
  *integrity* (SHA-pinning), not speed.
- **aeb has no downstream user community yet**, so none of this is urgent
  — which is also why it is the right time to fix the shape, before
  anyone depends on the accidental source-tarball path.

## Related

- `docs/guides/aeb-host-vm-or-container-setup.md` — the three tiers, what mutates.
- `asks/two-aethers-pinned-toolchain-vs-declared-dep.md` — the pin split.
- `TODO.md` § "Full Aether CLI entrypoint" — `aeb-cli`'s remaining work.
- aeo's `docs/operations/agent-host-setup.md` + `docs/releasing-aeo.md` — the
  release + plant discipline being copied.
- aeci's `LLM.md` / `DESIGN.md` — the shells-out-to-aeb seam.
