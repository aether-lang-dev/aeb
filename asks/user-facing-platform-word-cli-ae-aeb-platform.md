# A user-facing `platform` command (`ae platform` / `aeb platform`) — one normalized `<os>-<arch>` word, so scripts stop hand-rolling `uname`

## The ask

Expose the normalized platform word — `linux-x86_64`, `macos-arm64`, … — as a
tiny user-facing CLI, so a shell script that needs to name/select a per-platform
release asset can ask the toolchain instead of re-deriving it from `uname`.

```sh
ae platform                     # -> linux-x86_64
ae platform --os                # -> linux
ae platform --arch              # -> x86_64
ae platform --asset 'libfoo-{v}-{platform}.{ext}' V=1.2.3   # -> libfoo-1.2.3-linux-x86_64.so
```

`aeb platform` would do as well — whichever is the natural home. Pure, offline,
no network. The `--asset` template (with `{platform}`/`{os}`/`{arch}` and an
`{ext}` that follows the OS: `.so`/`.dylib`/`.dll`) is the sugar that removes the
last bit of per-script logic; even just the bare word would be a big win.

## Why: the SAME normalization is hand-rolled in 5+ places

The `uname -s`/`uname -m` → `{linux,macos,windows,freebsd} × {x86_64,arm64}`
mapping already exists, copied, in:

1. `aeb/get.sh` — `aebget_platform()` (installs aeb's own release asset
   `aeb-<os>-<arch>.tar.gz`).
2. `aeb/lib/bldr/module.ae` — `_host_os()` / `_host_arch()` / `_host_os_arch()`
   (for `.ae` build nodes that name a per-platform artifact).
3. `aether/install.sh` — three `uname -s` sites.
4. `libphonenumber-ae/get-engine.sh` — a fresh copy, to download the engine
   `libphonenumber_ae-<tag>-<os>-<arch>.{so,dylib,dll}` from a GitHub release.
5. `libphonenumber-ae/release/build.sh` / selenium's `release/build.sh` — the
   triple→`<os>-<arch>-<ext>` naming on the *producing* side.

Every one of these is the identical table. A consumer who wants "download the
right `.so` for my machine from a release" (the whole point of publishing engine
libs to gh-releases) has to reimplement it a sixth time. A `ae platform` /
`ae platform --asset` turns each of those into one call, and — more importantly —
gives *downstream* repos (the FFI-binding consumers) a supported way to select
their asset without vendoring a `uname` block.

## Scope note (what NOT to build)

Just the **platform word / asset-name** primitive — pure and offline. A generic
release-*fetcher* (curl + GitHub-release-URL conventions + sha256 verify) is
tempting since `get.sh` already does it, but that couples the toolchain to a
hosting provider and a URL scheme; better left to a thin per-repo script (like
`get-engine.sh`) that *calls* `ae platform` and owns its own URL convention. The
line: the toolchain owns `uname` normalization (universal); the repo owns "fetch
from a release named like *this*" (a convention).

## Filed from

libphonenumber-ae (branch reboot), which just added `release/` (cross-build the
engine matrix → gh-releases) + `get-engine.sh` (download the engine for the host
platform). `get-engine.sh` currently carries its own `uname` block; it would drop
that for `ae platform` the moment it lands.
