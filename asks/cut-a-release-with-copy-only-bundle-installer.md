# Please cut an aeb release including 87a30b8 (copy-only bundle installer)

**Status:** OPEN — needs a maintainer action (tag/release). 2026-09-07, from the
servirtium-vcr + aeo side.

## The ask

Cut a new aeb release (a `v0.298` tag → `release.yml` fires on `push: tags: v*`)
so the **published** aeb bundle picks up **`87a30b8`** ("release: prebuilt bundle
install.sh is copy-only (no make, no rebuild)"). That commit is on `main` and in
HEAD, but the latest release tag is still **v0.297**, which predates it — so
everyone installing aeb from a release still gets the old bundle installer that
runs `make -C share/aeb install`.

Two unreleased commits would ship together, both install-UX wins:
- `87a30b8` — bundle `install.sh` is copy-only (no `make`, no ae, no rebuild).
- `5365ed0` — `get.sh` executes on `curl … | sh` (bare-shell `$0`) + adds
  `AEBGET_SOURCE_ONLY`.

## Why it matters (verified end-to-end)

On a **virginal `debian:13-slim` podman container** (a clean CI box), installing
aeb from the current release fails:

```
aeb-get: ae 0.645.0 ready (binary)
aeb-get: trying aeb binary: aeb-linux-amd64.tar.gz @ v0.297 (with .sha256 verify)
aeb-get:   sha256 OK
aeb-get:   GNU make absent (the aeb bundle's installer needs it) — will build from source
aeb-install: GNU make is required …
aeb-get: aeb install failed (install.sh).
```

The bundle ships a *prebuilt* tree (its own `install.sh` even says "No compiler
needed"), yet the v0.297 installer `make install`s anyway — which needs GNU make
+ ae on the target box, and would also *rebuild* (undo) the shipped cross-built
tool binaries. `87a30b8` fixes exactly this: copy the tree, write the wrapper,
stamp the version — no make. **Proven against the real v0.297 bundle with `make`
absent from PATH:** the copy-only `install.sh` installs a working `aeb v0.297`,
exit 0, and `tools/aeb-main` stays an ELF binary (copied, not rebuilt).

## Downstream impact (why two repos are waiting on this tag)

- **servirtium-vcr**: its README's one-line aeb install currently needs a pile of
  `-dev` libs (`libssl-dev zlib1g-dev libpcre2-dev libbrotli-dev libzstd-dev`)
  purely because the v0.297 bundle falls back to a source build. A release with
  `87a30b8` lets the binary bundle install with no compiler at all → the `-dev`
  libs drop away.
- **aeo v0.2.0**: its own CLI bundle is already copy-only, BUT `aeo/get.sh` also
  ensures `aeb`, pulling aeb's **published** bundle (v0.297) — so `curl
  …/aeo/main/get.sh | sh` on a bare box installs `ae`, then dies at the aeb step.
  aeo's whole bare-box CI install story is blocked on this aeb tag. (Cross-ref:
  `aeo/asks/container-entrypoint-and-asymmetric-publish.md`, closing section.)

Nothing to change in aeb code — the fix is already committed. This is purely
"please tag a release so it reaches users."
