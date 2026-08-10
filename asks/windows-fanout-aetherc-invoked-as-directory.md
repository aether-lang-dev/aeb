# Windows: after the OpenSSL fix, the fan-out fails with the repo root run as a command

**From:** the aether-ui line (2026-08-10) · **Where it bit:** winbaz
(Windows 11 / MSYS2 MINGW64), `aeb apps/tumbling_cube/.build.ae`

## The OpenSSL fix worked — this is the next layer

`d55f064` (per-module pkg-config) fixed the orchestrator link. Confirmed on
the box: `target/_ae_build_all.exe` is now produced (664,486 bytes), where
before it never existed. The build gets meaningfully further — 0.06s
straight to failure, now 0.88s with real work done.

A second, distinct bug is now reachable.

## Symptom

```
$ aeb apps/tumbling_cube/.build.ae
  build:   apps/tumbling_cube               0.88s [miss] FAILED
```

The per-target log contains, in order:

```
Aether Compiler v0.514.0
Usage:
  C:\msys64\usr\local\bin\aetherc.exe <input.ae> <output.c>   Compile Aether to C
  ... (full usage text) ...
C:/msys64/tmp/_aeb_sh_2412_2053300613.sh: line 1: C:/msys64/home/paul/aether-ui: Is a directory
apps/tumbling_cube: compiling Aether program
apps/tumbling_cube: aetherc failed
```

Two things in one line-1 command:

1. **`aetherc` printed its usage text** — it was invoked with no usable
   arguments (this is the "aetherc invoked with no arguments" that
   aether-ui's `spec_matrix.sh` comment has described for months, now with
   a trace behind it rather than a guess);
2. **the repo ROOT was executed as a command** —
   `C:/msys64/home/paul/aether-ui: Is a directory`.

Both come from the same generated script,
`/tmp/_aeb_sh_<pid>_<n>.sh`, at **line 1**. That points at one malformed
command line where the root path lands in command position and the real
arguments do not reach `aetherc`.

The script is deleted on exit, so I could not capture its contents. If
there is an env switch to preserve it (or a trace flag that echoes the
composed line the way `AEB_LINK_TRACE` does for the link step), that would
settle this in one look — same shape as the trace request that resolved the
last one.

## STATUS on aeb 0.281 — does not currently reproduce; blocked behind the link bug

Retested today against aeb **0.281** (rebuilt on the box from `d55f064`),
aether 0.511.0. The signature above — usage text, and
`C:/msys64/home/paul/aether-ui: Is a directory` — **does not appear**:

```console
$ aeb apps/tumbling_cube/.build.ae 2>&1 | grep -i "is a directory|Usage:|aetherc failed"
(no matches)
```

What happens instead is that the build now fails earlier, at the **link**
step, with the undefined `deflate`/`inflateEnd` symbols and the
`sh: -c: line 1: unexpected EOF` described in
`windows-pkg-config-substitution-runs-in-cmd.md`.

So this ask is **not confirmed against the current build**. Two readings,
and I cannot yet distinguish them:

- the compile-argument bug was fixed between the version reported here and
  0.281; or
- it is still there but unreachable, because the link bug now fails the
  target before the orchestrator gets to that compile step.

Suggest fixing the pkg-config substitution first, then re-running this
target: if the usage text reappears, this ask is live; if the target builds,
it can be closed. Filing it rather than deleting it because the original
trace was real and is worth keeping either way.

Worth stating so this is not merged with `d55f064`: that was a *link* flag
being silently voided, in `aeb-link`. This is *after* a successful link, in
the orchestrator's own compile step, and involves argument composition
rather than library flags.

## Environment

aeb `0.0.0-dev+95f905c01978` (git `v0.280-22-gd55f064`, i.e. WITH the
OpenSSL fix), aether 0.514.0, MSYS2 MINGW64 on Windows 11.

**CORRECTION (2026-08-10, later the same day).** This section previously
claimed `pkg-config --libs zlib openssl` "DOES resolve" on this box. That
was measured in a shell that happened to have `PKG_CONFIG_PATH` set. In a
clean shell it does **not**:

```console
$ pkg-config --libs zlib
Package 'zlib' not found            # /usr/bin/pkg-config searches /usr/lib/pkgconfig
$ PKG_CONFIG_PATH=/mingw64/lib/pkgconfig pkg-config --libs zlib openssl
-L/mingw64/lib -lz -L/lib -lssl -lcrypto
```

The `.pc` files live in `/mingw64/lib/pkgconfig` (183 of them); the
pkg-config on PATH is the MSYS one, which never looks there. So winbaz
**can** reproduce a missing-`.pc` case after all — no second box needed.

See `windows-pkg-config-substitution-runs-in-cmd.md`, filed after this one:
the substitution `$(pkg-config ...)` is emitted into the gcc string and
reaches cmd.exe, which cannot perform it, so the flags are absent rather
than wrong. That is a *different* bug from the one below, but the two share
this box and this toolchain, and the search-path gap affects both.

## Impact

Unchanged from before: aether-ui's Windows matrix falls back to `build.sh`
per app, so a full `--rebuild` run takes ~40 minutes there versus the
cached fan-out on the other three platforms. Everything is green — 273/0 on
all four — just slow on this one.
