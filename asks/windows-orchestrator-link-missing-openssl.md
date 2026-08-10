# Windows: the orchestrator link fails on missing OpenSSL symbols

**From:** the aether-ui line (2026-08-10) · **Where it bit:** winbaz
(Windows 11 / MSYS2 MINGW64) — `aeb` cannot build ANY aether-ui target
there, so the whole Windows spec matrix falls back to `build.sh` per app.

## CORRECTION — the first version of this ask was wrong

I originally reported a path-joining bug: the orchestrator "written to
`target/target/` but invoked from `target/`". **That inference was wrong**,
and the aeb sibling was right to refuse to code against it. Their argument
was decisive: `build_dir` and `out_bin` are composed from the same `root`
two lines apart, so a bad root would nest *both* — it cannot produce a
correct Makefile path and a deep binary. Recorded here because the wrong
diagnosis is instructive: I saw a `target/target/` directory and a
"file not found", and connected them without checking the timestamp.

`target/target/_ae_build_all.exe` is dated **Aug 4** — a stale artefact
from an older aeb, unrelated to today's failure. Deleting it changes
nothing.

Traces requested by the sibling, gathered on the box:

```
pwd     = /home/paul/aether-ui              <- POSIX, as expected
pwd -W  = C:/msys64/home/paul/aether-ui
MSYSTEM = MINGW64
```

and the two paths they wanted side by side:

```
[aeb-link trace] gcc ... -o C:/msys64/home/paul/aether-ui/target/_ae_build_all.exe
[aeb-link trace] 'aeb-driver.exe' 'C:/msys64/home/paul/aether-ui' \
                 'C:/msys64/home/paul/aether-ui/target/_ae_build_all.exe' ...
```

**They agree.** There is no doubled join and no path-flavour mismatch in
this chain. The path handling is fine.

## The actual cause

The orchestrator link **fails**, so the binary is never created and the
subsequent "No such file or directory" is a consequence, not the bug:

```
ld.exe: C:/msys64/usr/local/bin/../lib/aether/libaether.a(aether_cryptography.o):
        undefined reference to `EVP_MD_CTX_new'
        undefined reference to `EVP_DigestInit_ex'
        undefined reference to `EVP_DigestUpdate'
        undefined reference to `EVP_MD_CTX_free'
        undefined reference to `EVP_DigestFinal_ex'
```

`libaether.a` contains `aether_cryptography.o`, which references OpenSSL's
EVP API, but the orchestrator link line carries no `-lcrypto`:

```
gcc -O2 -pipe -w <orchestrator.c> <target.c> $(find ... -I...) \
    -LC:/msys64/usr/local/bin/../lib/aether -laether -o <out>
```

OpenSSL **is** installed on the box (`pkg-config --modversion openssl` →
3.6.3; `/mingw64/lib/libcrypto.a` present), so this is a missing link flag
rather than a provisioning gap.

## Why Windows and not Linux

On Linux the same link succeeds because the toolchain resolves `-lcrypto`
transitively — glibc/gcc pull it in via the shared `libaether` link and the
system's default library set. MinGW's `ld` does not: static archives get no
transitive dependency resolution, so every symbol `libaether.a` needs must
be named explicitly on the command line.

That also explains why nobody noticed: the orchestrator is the *only* place
aeb links `libaether` itself. Every app target links through `aetherc`,
which emits its own flag set (aether-ui's `build.sh` adds `-lcrypto` among
others), so app builds work on the same box while the orchestrator does not.

## Ask

Add OpenSSL to the orchestrator's link line on Windows — `-lcrypto` at
minimum, likely `-lcrypto -lssl`, ideally sourced from
`pkg-config --libs openssl` so it tracks the installed version.

Worth considering more generally: the orchestrator link hardcodes
`-laether` and assumes everything else resolves. If `libaether.a` gains
another external dependency, this breaks again in exactly the same way,
with an equally indirect symptom. Deriving the flags from the same source
`aetherc` uses would close the class.

## Environment

aeb `0.0.0-dev+71a19d62288a` (git `v0.280-21-g63bcb14`), aether 0.514.0,
OpenSSL 3.6.3, MSYS2 MINGW64 on Windows 11. Reproduced on
`apps/tumbling_cube`; every target behaves identically.
