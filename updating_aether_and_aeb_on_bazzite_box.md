# Updating Aether + Aeb on the bazzite box

A note-to-self for refreshing the Aether and Aeb toolchains on
`bazzite@192.168.0.57` to HEAD of main. Last run: **2026-07-01**, took ae
0.322→**0.339.0**, aeb `c6d8479`→**`d98027e`** (origin/main HEAD). Also
converted `ae` from a podman-per-call wrapper to a **native** host binary
(7.00s → 0.00s per `ae` invocation).

> **Re-running this:** it's a hand-runbook, and it's re-runnable — but do the
> whole thing in ONE ssh shell so the `REF` / `PFX` / `BIN` variables set below
> persist across the parts. The version numbers in comments (`# -> 0.339.0`)
> are just *this run's* expected output — after you pick a newer `REF` they'll
> read higher; that's fine. The backup and glibc steps are written to be
> safe on a repeat (guarded), so don't skip them "because they already ran".

Set these once at the top of your ssh session; everything below uses them:

```sh
# on the box (ssh bazzite@192.168.0.57)
REF=$(git ls-remote --tags https://github.com/aether-lang-org/aether.git \
        | grep -oE 'v0\.[0-9]+\.[0-9]+$' | sort -V | tail -1)   # or hardcode e.g. v0.339.0
PFX=$HOME/.local/share/aether-native
BIN=$HOME/.local/bin
echo "will install Aether $REF"
```

## How the box is wired (read this first — it's non-obvious)

- **There is (was) no native `ae` on the host.** `~/.local/bin/ae` was a thin
  **podman wrapper** that ran `ae` inside the `localhost/aether-builder:latest`
  image — so *every* `ae` call (even `ae --version`) spun up a container
  (~7s cold-start). "Host aether" = that image.
- **`aeb` IS a native host install** (`~/.local/share/aeb/`, wrapper at
  `~/.local/bin/aeb`). But its Makefile drives everything through `ae build`
  (`AETHER ?= ae` in the Makefile) — so building aeb used the container `ae`.
- **Aether source** lives at `~/aether-build/aether/` — but it's a **release
  tarball extraction, NOT a git checkout** (`git` commands fail there). It has
  `get.sh`, `Makefile`, `VERSION`.
- **aeb source** is a real git checkout at `~/aeb` (origin =
  `github.com/aether-lang-org/aeb.git`).
- The `ae version install/use` self-updater **does not work on this box** — its
  download-URL construction fails ("Version vX not found for linux-x86_64")
  even though the release asset exists. Don't rely on it; build the image.

## Part 1 — Update Aether (rebuild the aether-builder image)

`$REF` is already set (top of file). Write the Containerfile (heredoc, so
`$REF` is passed as the build-arg — no hardcoded version to forget):

```sh
cat > /tmp/Containerfile.aether-builder <<'EOF'
# NB: fully-qualified base name — the box enforces short-name resolution
# and can't prompt without a TTY (bare `gcc:13-bookworm` errors).
FROM docker.io/library/gcc:13-bookworm
RUN apt-get update && apt-get install -y make git python3 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG AETHER_REF
RUN curl -sSL https://raw.githubusercontent.com/aether-lang-org/aether/main/get.sh \
      | AETHER_REF=${AETHER_REF} PREFIX=/usr/local sh
RUN /usr/local/bin/ae --version && /usr/local/bin/aetherc --version
WORKDIR /work
CMD ["/usr/local/bin/ae", "--version"]
EOF
```

Build and retag `:latest` (the `~/.local/bin/ae` podman wrapper runs `:latest`):

```sh
podman build --build-arg AETHER_REF=$REF \
  -t localhost/aether-builder:$REF \
  -f /tmp/Containerfile.aether-builder /tmp
podman tag localhost/aether-builder:$REF localhost/aether-builder:latest
```

> `get.sh`'s `AETHER_REF` accepts a tag, branch, or commit SHA — so `REF=main`
> gives HEAD-of-main instead of the latest tag, if that's what you want.

## Part 2 — Go native (drop podman from `ae <params>`)

The 7s/call container overhead is brutal (aeb's `make install` makes ~30
`ae build` calls). Extract the x86_64 toolchain out of the image and run it
directly. This works only because the image's glibc is **≤** the host's (an
older binary on a newer host is the backward-compatible direction), and the
host has `cc`/`gcc`/`make` + the runtime `.so`s. **Assert it — don't assume**
(a future gcc base could bump the image past the host and this silently breaks):

```sh
imgl=$(podman run --rm --entrypoint /bin/sh localhost/aether-builder:latest \
         -c 'ldd --version | head -1 | grep -oE "[0-9]+\.[0-9]+$"')
hogl=$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$')
printf 'image glibc=%s  host glibc=%s\n' "$imgl" "$hogl"
[ "$(printf '%s\n%s\n' "$imgl" "$hogl" | sort -V | tail -1)" = "$hogl" ] \
  && echo "OK: host >= image, native extract is safe" \
  || echo "STOP: image glibc newer than host — keep podman, do NOT go native"
for t in cc gcc make; do command -v $t >/dev/null || echo "MISSING host tool: $t"; done
```

Extract `/usr/local`'s aether tree into the writable host prefix (`$PFX` set at
top of file):

```sh
rm -rf "$PFX"; mkdir -p "$PFX/bin" "$PFX/lib" "$PFX/include" "$PFX/share"
cid=$(podman create localhost/aether-builder:latest true)
podman cp "$cid:/usr/local/bin/ae"        "$PFX/bin/ae"
podman cp "$cid:/usr/local/bin/aetherc"   "$PFX/bin/aetherc"
podman cp "$cid:/usr/local/lib/aether"    "$PFX/lib/aether"
podman cp "$cid:/usr/local/include/aether" "$PFX/include/aether"
podman cp "$cid:/usr/local/share/aether"  "$PFX/share/aether"
podman rm "$cid"
```

**The one gotcha — a missing linker dev-symlink.** `ae build` links
`-lpcre2-8`, which needs the *unversioned* `libpcre2-8.so`. Immutable Bazzite
ships only `libpcre2-8.so.0` (runtime), not the `.so` dev-symlink — and
`/lib64` is read-only, so we can't add it there. (ssl/crypto/z/m already have
their dev-symlinks; only pcre2 is missing.) Fix in the writable prefix and
point the linker at it via `LIBRARY_PATH` (the compile-time search path gcc/ld
honor — distinct from `LD_LIBRARY_PATH`):

```sh
mkdir -p "$PFX/linklibs"
ln -sf /lib64/libpcre2-8.so.0 "$PFX/linklibs/libpcre2-8.so"
```

Replace the podman wrappers with native shims. **Guarded backup** — only save
the current `ae` if it's still the podman wrapper, so a native→native re-run
does NOT overwrite your good revert copy with a copy of the shim:

```sh
if grep -q 'podman' "$BIN/ae" 2>/dev/null; then
  cp -a "$BIN/ae" "$BIN/ae.podman-wrapper.bak"
  [ -f "$BIN/aetherc" ] && cp -a "$BIN/aetherc" "$BIN/aetherc.pre-native.bak"
  echo "backed up podman wrappers"
else
  echo "ae is already native — keeping existing .bak (not re-backing-up)"
fi
```

Write the shims. `ae` finds its home via `AETHER_HOME` OR
`<binary>/../lib/aether` — our layout satisfies the relative path, but we set
`AETHER_HOME` explicitly anyway:

```sh
cat > "$BIN/ae" <<'EOF'
#!/bin/sh
# Native ae shim — runs the extracted aether toolchain on the host (NO podman).
# Old podman wrapper backed up as ae.podman-wrapper.bak.
PFX="$HOME/.local/share/aether-native"
export AETHER_HOME="$PFX"
export LIBRARY_PATH="$PFX/linklibs${LIBRARY_PATH:+:$LIBRARY_PATH}"
exec "$PFX/bin/ae" "$@"
EOF
chmod +x "$BIN/ae"
sed 's#/bin/ae#/bin/aetherc#' "$BIN/ae" > "$BIN/aetherc"   # twin for aetherc
chmod +x "$BIN/aetherc"
```

Verify (should be instant, no podman):

```sh
ae --version         # ae 0.339.0
aetherc --version    # Aether Compiler v0.339.0
```

**To revert to podman:** `cp -a ~/.local/bin/ae.podman-wrapper.bak ~/.local/bin/ae`.

## Part 3 — Update Aeb

Pull the source and rebuild the tools (compiles them against the new `ae`):

```sh
export PATH=$HOME/.local/bin:$PATH
cd ~/aeb
git stash -u 2>/dev/null           # stash any stray untracked files
git pull --rebase origin main
make install PREFIX=$HOME/.local
```

`make install` runs ~30 `ae build` invocations — **fast now that `ae` is
native** (~9s total vs minutes under podman). It rebuilds every `tools/*.ae`
and copies the runtime tree into `~/.local/share/aeb/`. (The remote-agent +
lease-minter are deliberately NOT installed by `make install` — opt in with
`aeb tools/remote-agent/.install.ae`.)

## Part 4 — Verify the pair composes

```sh
export PATH=$HOME/.local/bin:$PATH
ae --version                       # ae 0.339.0
aetherc --version                  # Aether Compiler v0.339.0
aeb --version                      # git v0.203-19-gd98027e; tools built ae 0.339.0

# functional smoke: compile+run a known-good, contrib-free example.
# (Don't hand-write hello.ae — the language moves and your syntax will be
#  stale. Pick ANY example from the aether source tree that doesn't
#  `import contrib`, so this survives the example set changing.)
cd /tmp && rm -rf smoke && mkdir smoke && cd smoke
ex=$(grep -L 'import contrib' ~/aether-build/aether/examples/*.ae 2>/dev/null | head -1)
echo "smoke example: $ex"
cp "$ex" t.ae
ae build t.ae -o t && ./t         # -> "Built: t", then runs
# (a "cannot find libaether_sandbox.so" or similar optional-preload warning is
#  fine — as long as `Built: t` printed, the compile+link path works.)
cd / && rm -rf /tmp/smoke
```

## Gotchas seen (so we don't relearn them)

- **short-name resolution**: base image must be `docker.io/library/gcc:...`,
  not `gcc:...` (no-TTY podman can't prompt).
- **`ae version install` is broken here** — build the image instead.
- **stale standalone `aetherc`**: before going native there was a real
  `~/.local/bin/aetherc` ELF at 0.257 (unused — aeb builds via `ae build`, not
  `aetherc` directly). The native shim overwrites it, so `aetherc` finally
  reports the right version.
- **glibc direction matters**: extract works only while the image glibc ≤ the
  host's (last run: image 2.36, host 2.43). The Part 2 assert step checks this
  — if it ever says STOP, keep podman rather than going native, or rebuild the
  image on a base whose glibc floor is ≤ the host's.
- **only pcre2 needs the dev-symlink shim** today; if a future `ae` links a new
  lib whose `-devel` isn't on the box, the Part 4 smoke test will fail at link
  with `cannot find -l<name>` — add another symlink under `$PFX/linklibs/` the
  same way as pcre2.
