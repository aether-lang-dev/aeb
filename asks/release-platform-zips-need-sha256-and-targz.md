# Release: platform binaries want a `.sha256` each, and a `.tar.gz` alongside `.zip`

**From:** the Selenium-on-Aether port's CI (`paul-hammant/selaenium`,
`ci/toolchain.sh`), 2026-08-29 · consuming the aeb release binaries to install
the toolchain without a source build.

## Context

`ci/toolchain.sh` now installs aeb from the prebuilt platform asset
(`aeb-{os}-{arch}.zip`) — download, unzip, `make -C share/aeb install` (no
compiler needed, `bin/aeb` is a script), verify it runs, else fall back to the
source build. This works today against v0.286. Three gaps make it less robust
than it should be; the first is the one that matters.

## Ask 1 (the important one): a `.sha256` for every platform asset

The v0.286 release ships `aeb-bootstrap.tar.gz.sha256` but **no checksum for the
platform zips** (`aeb-linux-amd64.zip`, `aeb-macos-arm64.zip`, `aeb-freebsd-…`,
`…-musl`, `aeb-windows-…`). So a consumer that fetches a platform binary — the
fast, compiler-free path — cannot verify the download. For a build tool that
then executes on a CI node, an unverified fetch is a real supply-chain gap.

`release.yml`'s own header already states the intent — *"a companion `.sha256`
per asset"*, *"one tag → one immutable asset set → SHA256s retained forever"* —
and the bootstrap path already does `sha256sum … | tee ….sha256` (line ~151).
The platform-zip generation just needs the same treatment: emit
`aeb-{os}-{arch}.zip.sha256` beside each zip. `toolchain.sh` has a TODO to verify
against it the moment it exists.

## Ask 2 (nice to have): a `.tar.gz` per platform, not only `.zip`

The platform assets are `.zip`, which needs `unzip` — not present on every
minimal CI image, whereas `tar` (a prerequisite already) is near-universal. A
per-platform `.tar.gz` alongside the `.zip` would let consumers drop the `unzip`
dependency. Not blocking (our script gates the binary path on `unzip` and
source-builds otherwise), just one fewer prerequisite for the common Linux case.

## Ask 3 (docs): name the intended prebuilt-install path

The extracted tree runs from `bin/aeb`, but a bare run warns it is an
"un-installed tree" (no `AEB_STAMP`); the stamped install is `make -C share/aeb
install PREFIX=…`. That is discoverable but not documented — the release notes
foreground `aeb-bootstrap.tar.gz` (source, self-building) and don't say how the
platform zips are meant to be installed. A line in the release body or a tiny
`install.sh` inside the zip would save the next consumer the reverse-engineering
(we read the bundled Makefile to find it).

## Not asking for

- Changing the recommended path — `aeb-bootstrap.tar.gz` staying primary is
  fine; we just also want the platform binaries to be first-class (checksum +
  install story) for the compiler-free case.
- Any change to the asset *naming* — `aeb-{os}-{arch}` (amd64/arm64, macos,
  musl) is clear and we match it; only the `.sha256`/`.tar.gz`/docs gaps above.
