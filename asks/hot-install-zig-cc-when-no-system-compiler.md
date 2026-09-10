# Hot-install a pinned `zig cc` when no system C compiler is found — instead of a dead-end error

> **STATUS: IMPLEMENTED (2026-09-10), aeb-side.** Fallback, not override;
> opt-out via `AEB_NO_ZIG=1`. Shipped as the design below describes.

## Resolution (aeb-side, no aether change)

Key finding: the dead-end is emitted by **aether's** driver (`ae.c:2941`), not
aeb — aeb never sees aether's probe failure. But aether honors `$AE_CC` then
`$CC` over PATH (`ae.c:2098`/`2910`), so aeb can resolve the compiler *before*
the build reaches that dead-end and point aether at zig via `AE_CC`. Two changes:

1. **`aeb` trampoline** — before a normal build, probe `$AE_CC`/`$CC`/`gcc`/`cc`
   (aether's own order). If NONE resolves and `AEB_NO_ZIG` is unset, fetch the
   pinned zig (`ZIG_REF`, default 0.16.0) from ziglang.org as a per-platform
   tarball into `${XDG_CACHE_HOME:-~/.cache}/aeb/zig/<ref>/` (no sudo, cached so
   one-time), export `AE_CC="<zig> cc"`, and print ONE visible line. A present
   compiler short-circuits it (nothing fetched, no notice); `AEB_NO_ZIG=1`
   preserves aether's hard error for strict-hermetic CI.
2. **`tools/aeb-link.ae`** — the orchestrator LINK step hardcoded `gcc`; now
   honors `$AE_CC` then `$CC`, else `gcc`, so the zig fallback reaches the link
   too (a compiler-less box died at the link otherwise).

Opt-out is `AEB_NO_ZIG=1` (env). A `--no-zig` flag was considered but the
trampoline passes all argv to aeb-main, which would reject an unknown flag; the
env form covers the CI-hermetic case the ask targets. The pin is a single
`ZIG_REF` in the trampoline (overridable) rather than a new file — a dedicated
versions file can follow if the maintainer prefers.

Verified on a gcc/cc-hidden PATH: fetches zig 0.16.0, `zig cc` compiles a C
program, a real `aeb <node>.build.ae` builds green through compile AND link, the
binary runs. gcc-present box: unchanged, no fetch, no notice. `AEB_NO_ZIG=1`:
`AE_CC` stays unset (aether's error preserved). Full aeb suite still green.

Original design follows.

---

> **STATUS: DESIGN (2026-09-10).** Fallback, not default. Sketch first.

**Filed by:** libphonenumber-ae Claude, 2026-09-10, while bootstrapping the
Aether libphonenumber monorepo (one engine, ~20 thin FFI bindings) on a fresh
box. `bootstrap.sh` installs `ae`+`aeb` binary-first, no compiler, no make — a
genuinely lovely zero-to-toolchain step. Then the *first real build* of the
engine (`aeb core/.build.ae`) needs a system C compiler, and on a box without
`gcc`/`cc` the flow dead-ends with:

```
Error: no C compiler found (looked for gcc, then cc).
Set $CC to your compiler, or install one:
  Debian/Ubuntu: sudo apt install gcc
  Fedora:        sudo dnf install gcc
  FreeBSD:       cc ships with the base system
```

## Why this is the rough edge worth smoothing

The whole appeal of `get.sh` / `bootstrap.sh` is **one command, no sudo, no
system deps, self-contained, binary-first**. That promise holds right up until
the first build, where it hands the newcomer a *second, platform-specific,
usually-sudo* step — at exactly the moment they expect "installed" to mean "can
build". It's the single most common first-run wall, because every user hits the
engine build before any language-binding toolchain.

And the capability is **already present**: `ae`/`aeb` drive `zig cc` today for
every `--target` cross-compile (`--target=wasm32-wasi`, `aarch64-macos`, …). So
`zig cc` is a known-good compiler in this toolchain — it's just unreachable for
the native path. `CC="zig cc"` already works if you install zig yourself; the
gap is purely "nobody fetched zig for you."

## Why zig specifically fits the existing machinery

- `zig cc` is a genuine drop-in C compiler (clang underneath), already exercised
  by the cross-compile path — low risk, not a new dependency class.
- zig ships as a **single self-contained per-platform tarball, no system deps** —
  the exact shape `get.sh` already fetches for `ae`/`aeb`. It slots into the
  binary-first installer rather than fighting it.
- It makes the engine build **hermetic**: same compiler everywhere, so
  "works on my machine" compiler divergence drops. Real value beyond convenience.

## The design — a graceful FALLBACK, never a silent override

The thing to avoid is a newcomer *silently* ending up on a bundled zig when they
had a perfectly good system gcc, then being confused about which compiler built
their artifacts. So:

1. **Prefer what's already there.** Honor an explicit `$CC`, then `gcc`, then
   `cc` — never override a present system compiler. (Today's behaviour, kept.)

2. **Only when NONE is found**, instead of erroring, hot-install a **pinned**
   zig the same way `get.sh` fetches `ae`/`aeb` (per-platform tarball → `$PREFIX`,
   no sudo), and set `CC="zig cc"` for the build. The zig version is pinned in a
   `ci/versions.env`-style single source of truth (e.g. `ZIG_REF=0.16.0` beside
   `AETHER_REF`/`AEB_REF`), so it's reproducible, not "whatever's latest".

3. **Say so, ONCE, visibly** in the output — the specific line this ask is for:

   ```
   no system C compiler found — installed zig 0.16.x to $PREFIX and using `zig cc`
   ```

   Visible (not hidden), reproducible (the pin), and it names the exact compiler
   choice so nobody has to guess what built their `.so`. One line, at the moment
   of the fallback, not on every build.

4. **Keep it opt-outable.** An already-set `$CC` short-circuits it; a
   `--no-zig` flag / `AEB_NO_ZIG=1` env lets the strict-hermetic-CI crowd keep the
   hard error instead. Default fallback ON is the DX win; the escape hatch keeps
   control for those who want it.

## Scope / non-goals (stated so it doesn't over-reach)

- **Fallback only.** If any of `$CC` / `gcc` / `cc` resolves, zig is never
  fetched and this path is invisible. No behaviour change for boxes that already
  build.
- **Engine C-compiler only.** This does NOT install language-binding toolchains
  (`ghc`, `dotnet`, `ruby`, …) — those bindings still skip loudly when absent.
  It fixes the one compiler every user needs first, which is the high-leverage
  spot.
- **Right home is the `get.sh` / `ae` driver**, not any downstream consumer.
  Downstreams (like this repo's `bootstrap.sh`) should inherit it, not
  re-implement it.
- Wants aeb-maintainer buy-in on the pin location and the default-on choice; the
  one-line message and the prefer-then-fallback shape are the load-bearing asks.

## Acceptance sketch

On a box with no `gcc`/`cc`/`$CC`:
- `bootstrap.sh` (or a bare `aeb <node>.build.ae`) fetches the pinned zig,
  prints the one-line notice above exactly once, and the build succeeds via
  `zig cc` — no sudo, no second manual step.
- On a box that HAS gcc: nothing changes, no zig fetched, no notice.
- `AEB_NO_ZIG=1` (or `--no-zig`) on a compiler-less box: the current hard error,
  unchanged.
