# Cross-compiling the Aether runtime: what `aeb` needs to absorb a hand-rolled WASM build

**Filed by**: html-sanitizer, 2026-08-18, after shipping two WebAssembly
builds of a pure-Aether engine as ~120-line `build.sh` / `build-zig.sh`
scripts, and wanting them to be `.build.ae` leaves instead.

**Concrete worked example throughout:** `html-sanitizer/wasm/`. An XSS
sanitizer whose engine is one pure-Aether module; 23 native bindings load it
as a `.so`, and the browser gets the *same* engine compiled to wasm32 rather
than a JavaScript reimplementation. Two backends, both green:
`emcc` (~62 KB + JS glue) and `zig cc -target wasm32-wasi` (~85 KB, no glue).

## The short version

`aeb` already has **every piece but one**. `aether.csrc` emits the portable C;
`lib/c` knows a dep needs the Aether runtime (`c_needs_aether_runtime`) and
links it. The missing piece is that it links a **prebuilt host `libaether.a`**:

```
adir = build._resolve_aether_dir()
ldir = build._resolve_libaether_dir(adir)
aether_link = " -L${ldir} -laether -lpthread -lm"
```

An `x86_64` archive is useless to `wasm32`. Cross-compiling needs the runtime
**recompiled from source for the target**, which nothing in `lib/c` can express.
That single fact is why both of our builds are shell.

## What the scripts actually do

Five steps. `aeb` covers 1 outright, most of 4, and none of 2/3/5.

| # | Step | `aeb` today |
|---|---|---|
| 1 | `aetherc --emit=csrc embed.ae hs.c` | ✅ `aether.csrc` |
| 2 | pick a **wasm-suitable subset** of runtime `.c` | ❌ (see below) |
| 3 | collect **43** `-I` dirs from the install tree | ❌ hand-globbed |
| 4 | compile+link for a **cross target** with per-target flags | ⚠️ `cc()` only |
| 5 | export a symbol list; no `main` | ❌ hand-written |

### 2 is the interesting one

`share/aether/MANIFEST` — the documented "which `.c` do I compile" contract —
is **not usable for wasm**. It lists 92 sources, one of which,
`runtime/scheduler/multicore_scheduler.c`, fails a `Mailbox`
8-byte-alignment `static_assert` on wasm32 (verified against ae 0.545.0:
`zig cc -target wasm32-wasi -c .../multicore_scheduler.c` →
`static assertion failed due to requirement 'sizeof(Mailbox) % 8 == 0'`).
Both of our builds therefore ignore MANIFEST and mirror the `RUNTIME_FILES`
list hardcoded in Aether's own `make ci-wasm`, plus what the module needs
(`strbuilder`/`bytes`/`mem`/`set`/`stringseq`/`alloc`) — 32 sources.

So the list that works is duplicated in three places (Aether's Makefile, our
two scripts) and version-locked to none of them. **This is really an Aether
ask** — MANIFEST should either carry per-target subsets or say plainly that
it is host-only — but `aeb` is the consumer that would benefit, and it cannot
paper over it today.

## What we'd want to write

```aether
import build
import aether
import c

aeb(cap) {
    b = build.start()

    aether.csrc(b) {
        source("../core/embed.ae")
        output("hs")
    }

    c.shared_object(b) {           // or c.wasm_module(b)
        target("wasm32-wasi")      // <-- the ask
        cc("zig cc")               // already possible
        optimize("z")
        c_source("src/regex_stub.c")
        c_source("src/wasi_longjmp_stub.c")
        define("_WASI_EMULATED_SIGNAL")
        link_flag("-lwasi-emulated-signal")
        export_symbols_matching("aether_hs_embed_*")   // <-- the ask
        no_entry()
        output("htmlsanitizer-wasi.wasm")
    }
}
```

Everything above the `target(...)` line already works.

## Ranked, if you only do one

1. **`target("<triple>")` on the C builders, and have it recompile the Aether
   runtime from source for that triple instead of linking host `libaether.a`.**
   This is the whole ask. Everything else is ergonomics. It also generalises
   well past wasm — the same gap blocks any `aeb`-driven cross build
   (aarch64 from x86, mingw as a *target* rather than just a `cc` prefix,
   embedded).
2. **A resolved include-path artifact.** Every consumer of the install tree
   currently re-globs `find $AE/{runtime,std,include} -name '*.h'` to get **43**
   `-I` flags. `build._resolve_aether_dir()` already exists; publishing the
   include set alongside it would delete that glob from every downstream
   script.
3. **`export_symbols_matching(...)` / `no_entry()`** on a shared-object
   builder. Minor, but it is the difference between a declarative leaf and
   hand-assembling 16 `-Wl,--export=` flags in shell (one per ABI symbol).

## What we are NOT asking for

- **A wasm SDK.** `lib/zig` exists but is aimed at `zig build` on a
  `build.zig` project; that is not this. We want `zig cc` as a *cross
  compiler*, which is `lib/c`'s business.
- **`aeb` to know what Emscripten is.** `emcc` is a `cc`, and
  `-sEXPORTED_FUNCTIONS=...` is a link flag. If (1) lands, the emcc build is
  expressible with today's `cc()` + `link_flag()`.

## Related

- `asks/aeb-build-fetch-and-emit-lib-for-zsync-so.md` — same family (getting a
  `.so` out of an Aether module through aeb), different axis: that one is
  fetch-and-build, this one is build-for-another-target.
- `aether/asks/wasi-panic-guard-omits-__wasi__.md` — the one-line Aether fix
  our zig build currently patches around. Unrelated to aeb, but it is the
  other thing standing between `build-zig.sh` and a clean leaf.

## Honest scoping note

Neither script is *painful* — they work, they are tested (22 conformance
checks per backend, run from `wasm/.tests.ae`), and they skip loudly when
their toolchain is absent. This is a "the build graph should own this" ask,
not a "we are blocked" one. If cross-compilation is not on aeb's roadmap,
the reasonable answer is to close this and let the scripts stand.
