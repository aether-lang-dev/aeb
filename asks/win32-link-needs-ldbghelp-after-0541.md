# Windows: aeb's link line needs `-ldbghelp` (regression at ae 0.541.0)

**Status:** every Aether program aeb links on Windows/MinGW fails at the link
step after upgrading to ae 0.541.0. Not app-specific — reproduced on
`examples/table_demo` and `examples/roles_demo`, both of which had built fine
on the box before the upgrade and whose stale binaries still sit there.

```
ld.exe: libaether.a(aether_panic.o):aether_panic.c: undefined reference to `__imp_SymFromAddr'
ld.exe: libaether.a(aether_panic.o):aether_panic.c: undefined reference to `__imp_SymGetOptions'
ld.exe: libaether.a(aether_panic.o):aether_panic.c: undefined reference to `__imp_SymSetOptions'
ld.exe: libaether.a(aether_panic.o):aether_panic.c: undefined reference to `__imp_SymInitialize'
collect2.exe: error: ld returned 1 exit status
```

## Cause

`runtime/aether_panic.c` uses the DbgHelp symbol API (`SymInitialize`,
`SymFromAddr`, …) to symbolise panic stack traces on Windows. Those live in
`dbghelp.dll`, so anything linking `libaether.a` must pass `-ldbghelp`.

Aether's OWN Makefile already knows this:

```make
# aether/Makefile:655
WIN_LINK_LIBS = -static -lws2_32 -lcrypt32 -lgdi32 -luser32 -ladvapi32 -lbcrypt -ldbghelp
```

so `ae build` / `ae run` are fine — `ae run` on a one-line interpolating
program works on the box right now. It is only the link line aeb constructs
for external programs that is missing the flag.

## Ask

Add `-ldbghelp` to aeb's Windows link libs, alongside the ws2_32/gdi32/etc it
already passes. Ideally by reading the same list aether publishes rather than
maintaining a second copy — this is the failure mode a duplicated list
produces: aether adds a runtime dependency, its own builds keep working, and
every downstream consumer breaks at link time on one platform.

## SECOND INSTANCE (2026-08-25) — zlib on macOS at ae 0.580: read the list

The predicted failure mode recurred, on a different platform with a
different library. aether 0.580's zlib probe (#1690) now detects macOS's
SDK libz (no zlib.pc, but `-lz` links), so `libaether.a` gained
`aether_zlib.o` — and every aeb fan-out on macvm died at the orchestrator
link:

```
Undefined symbols for architecture x86_64:
  "_compress2", referenced from: _zlib_try_deflate in libaether.a[21](aether_zlib.o)
ld: symbol(s) not found ... → make: Error 127 × 90 nodes
```

aether publishes the answer already — `ae cflags --libs` on that box says
`... -lssl -lcrypto -lz -lpcre2-8` — and aeb-link never asks. The
`// aether-link:` header route can't cover this either: per
docs/build-system.md, toolchain-PROBED deps (ssl/z/pcre2) are deliberately
left out of module @link headers because `ae build` passes them from its
own detection. aeb-link's manual gcc path is the only consumer without
that half.

**Sharpened ask:** append aether's published libs (`ae cflags --libs`, or
the same probe results by whatever channel) to aeb-link's orchestrator and
program gcc lines. Hand-curating (-ldbghelp yesterday, -lz today) loses by
construction — the list is aether's, changes with aether's probes per box,
and aeb re-learns each delta as a fan-out-wide Error 127 with the real
error silenced (see orchestrator-failures-silenced ask).

Workaround on macvm meanwhile: aether rebuilt `ZLIB=0` (aether-ui does not
use aether's gzip), which drops both the dependency and the published
flag consistently. Undo when aeb reads the list.

## VERIFICATION of 86a2c5a (2026-08-25, the confirms you asked for)

* **FreeBSD/.204 — REGRESSION, one-line fix needed.** The extraction takes
  the `-l` tokens and DROPS the `-L` tokens. `.204`'s cflags says
  `... -L/usr/local/lib -lnghttp2 -L/usr/local/lib -lpcre2-8` — the paths
  are right there — and the orchestrator link then fails
  `ld: error: unable to find library -lnghttp2 / -lpcre2-8`. Works on
  Linux only because those libs sit in default linker paths there. Carry
  the `-L` tokens (or splice the tail of the libs string wholesale).
  Silver lining: the failure presented as ONE
  `aeb-link: FATAL — failed to link the fan-out orchestrator` with the ld
  error directly above — 27579bb's loud-failure UX verified on a real
  failure, zero fanned 127s. `.204` rolled back to v0.282 meanwhile.
* **Windows/winbaz — two findings.** (a) The aether-side gap you
  predicted is REAL: ae 0.562's `ae cflags --libs` there is
  `-L...lib/aether -laether -pthread -lm -LC:/msys64/lib -lssl -lcrypto -lz -lpcre2-8`
  — no `-ldbghelp`, while libaether's panic tracer needs it (WIN_LINK_LIBS
  in aether's own Makefile has it). Filed as
  `aether/asks/cflags-libs-omits-dbghelp-on-windows.md`. (b) BUT the
  bc50b38 fan-out on winbaz links CLEAN anyway (exit 0): the orchestrator
  evidently never pulls aether_panic.o out of the archive, so the missing
  flag doesn't bite at that layer — it bites APP links, where the 0.541
  breaks originally happened (aether-ui's apps carry -ldbghelp explicitly
  in build_support, so we're insulated either way). Net: your fix is
  orchestrator-verified on all three platforms modulo the -L regression;
  the dbghelp hole is real but latent, and closes properly on the aether
  side. Until then, keeping `-ldbghelp` in the explicit MinGW set
  alongside ws2_32/bcrypt would cost nothing — it is a Windows SDK system
  lib by any reasonable definition.
* **macOS/macvm — the -lz confirm: POSITIVE.** aether rebuilt with zlib
  (ZLIB=0 workaround undone), cflags publishes `-lz` again, aeb bc50b38
  installed, clean fan-out: exit 0, zero node failures, orchestrator
  links. The exact break that motivated the sharpened ask is fixed.
  CAVEAT tying into the .204 finding: macvm's cflags also carries
  `-L/usr/local/opt/openssl@3/lib` and `-L/Users/paul/.local/lib` which
  the token-extraction drops — the link survives only because Apple
  clang searches /usr/local/lib by default (Homebrew-linked copies).
  Same -L bug, masked by platform luck; FreeBSD had none. The -L fix
  covers both.
* **Installer gmake fix (dc24ee0) — CONFIRMED on real FreeBSD:** the
  exact `curl | sh` that died at "make: stopped making install" now
  completes tools-built/done. `.204`'s dirty tree: reset to main after
  capturing `/tmp/dot204-local.patch` (277 lines) for a final eyeball —
  your 6-of-8 analysis held.

## Notes

* Not caused by string interpolation, though that was the first theory: the
  file that pulls it in is the panic runtime, which every program links.
  `roles_demo` has 95 interpolations and built fine before the upgrade.
* Existing `.exe`s on the box predate the upgrade and still run, so the matrix
  can appear healthy while nothing can be rebuilt — worth knowing when a
  "stale binary" warning shows up on Windows.
* Found 2026-08-15 while adding `command` (SWING_ENVY C1) to aether-ui; that
  feature is green on GTK4 and blocked from win32 verification by this.
