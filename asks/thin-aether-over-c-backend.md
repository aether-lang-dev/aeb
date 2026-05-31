# aeb's manual path should support "thin Aether over a C backend"

**Filed by**: a downstream GUI-toolkit project (sibling claude session),
while spiking a `bootstrap.sh` + `.build.ae` to build through `aeb`
instead of a hand-rolled `build.sh`.
**Severity**: blocking for the "Aether surface, C implementation" project
shape — `aether.program(b)`'s manual path cannot build it at all today.
**Cross-ref**: a counterpart to `asks/transitive-regen-expansion.md`. That
ask asked aeb to auto-`--emit=lib` the transitive import closure (so a
consumer needn't enumerate every `regen_with(...)`). This ask is the case
that auto-expansion *breaks*: an imported module that can't be `--emit=lib`'d
because its bodies live in C.

## The project shape

The downstream is a GUI toolkit whose **Aether modules are a thin wrapper
over a large C backend**. The `.ae` modules declare the backend functions as
`extern` and call them; the bodies live in C files (one per platform —
GTK/AppKit/Win32 — plus helpers), linked alongside. So a module like
`ui.ae` is *not* a self-contained Aether library — it's the Aether-side
declarations of a C ABI.

Its existing `build.sh` builds an app the obvious way:

```
aetherc app.ae app.c                       # plain — NOT --emit=lib
gcc app.c backend_gtk4.c backend_extras.c \
    $(pkg-config --cflags --libs gtk4) -laether $(ae cflags --libs) -o app
```

The load-bearing fact: **plain `aetherc app.ae app.c` tolerates extern-bodied
imports.** It compiles `app.ae` (and the `import ui` declarations) to C with
unresolved externs, which the gcc step resolves against the C backend. This
is exactly what `ae build` does for a plain program, and it works.

## What blocks aeb

`aether.program(b)`'s manual path (entered via `extra_source` / `link_flag`)
runs the transitive import-closure regen from `asks/transitive-regen-expansion.md`
(the BFS in `lib/aether/module.ae` around line ~1206 that feeds the regen list):
it walks the entry's `import` graph and `aetherc --emit=lib`s every
project-local imported `.ae`.

For this project that means the extern-backed modules (`ui.ae` and friends)
get `--emit=lib`'d standalone — and they **can't be**. `--emit=lib` on a
module whose functions are C externs fails with a wall of
`E0301 Undefined function 'ui.<fn>'`: the externs are only defined when
linked with the C backend, which `--emit=lib` does not do.

Concrete failure: a `.build.ae` declaring the backend C via `extra_source`
and the GTK/libaether flags via `link_flag` →
`aetherc --emit=lib failed for .../ui_live.ae`, dozens of `E0301`.

The import-closure walk is correct and valuable for its **cache-key** use
(`_cache_key_for_aether_link` — a change to an imported module should bust
the key, and that should stay). The problem is only the **regen-feeding**
use: it assumes every imported project `.ae` is a self-contained `--emit=lib`
library. That holds for the avn-style pure-Aether monorepo that motivated
`transitive-regen-expansion.md`; it does not hold for the Aether-thin-over-C
shape.

## What's wanted

A way to tell `aether.program(b)`: **compile the entry with plain
`aetherc entry.ae entry.c` and link the declared `extra_source` C +
`link_flag`s — do NOT `--emit=lib` the import closure.** The closure should
still feed the cache key (hash imported `.ae`s for staleness); it just
shouldn't get regen'd.

Sketch (one of):

1. **An explicit opt-out setter** — `no_closure_regen()` (or
   `link_only_entry()`): suppresses the regen-from-closure pass, keeps the
   plain entry compile + the cache-key hashing. Smallest and most
   predictable; matches the "the `.build.ae` declares intent" ethos.
2. Skip a closure module from regen when its symbols are provided by a
   declared `extra_source`. Harder — the symbol↔C-file mapping isn't
   declared anywhere, so aeb can't know which C file backs which module
   without guessing.
3. A target-level mode: "imports are extern-backed; build like `ae build`
   would for a plain program, but with my `extra_source` / `link_flag`."

Option 1 is the recommendation.

## What is NOT being asked

- Not asking aeb to parse `pkg-config` / detect GTK — embedding
  `$(pkg-config ...)` in a `link_flag` already works (aeb's own `lib/aether`
  does the same for zlib/openssl, expanded by the shell at gcc time).
- Not asking for cross-compilation — the project builds the host backend;
  cross-compile is your separate roadmap item.
- Not asking to remove or change the transitive-regen auto-expansion — it's
  right for pure-Aether projects. This wants an *opt-out* alongside it.

## Acceptance

A `.build.ae` whose entry imports extern-backed modules and declares the
backend C via `extra_source` + flags via `link_flag` builds a runnable
binary, with **no `--emit=lib` attempted on the extern-backed imports** —
equivalent to the project's `build.sh`, expressed in the `.build.ae`.
