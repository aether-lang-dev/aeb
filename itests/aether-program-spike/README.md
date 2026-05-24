# aether-program-spike

A self-contained spike proving aeb can build an **Aether `main()` as the
program entry** — no committed C `main` shim — and that such a program
can link **both** a sibling Aether library and a C library.

This is the answer to
[`the_cobblers_children_have_no_shoes.md`](../../the_cobblers_children_have_no_shoes.md):
the capability already exists as `aether.program` (in `lib/aether`), not
`c.program`. The split is deliberate —

- **`aether.program`** — Aether `main()` is the entry; may link Aether
  libs (`import` / `extra_source`) *and* C libs (`extra_source` /
  `link_flag`). ← this spike.
- **`c.program`** — C `main()` is the entry; links C libs, and Aether
  libs only to satisfy C `extern`s into Aether symbols
  (`aether_source`). See `itests/c-aether-spike-a`.

It also pins the two mquickjs follow-up gaps:

- **Gap 1 — include dirs.** `cbits.c` `#include`s `inc/rom.h`, which
  resolves only because `.build.ae` declares `include_dir("../inc")`.
  (`aether.program` also auto-collects a dependency's published
  `c_header_dirs`, the same artifact `c.generated_header` writes.)
- **Gap 2 — out-of-tree regen.** The sibling Aether lib's generated C
  lands under `target/app/regen/`, never beside `greet/module.ae`; the
  test fails if any `*_generated.c` appears in the source tree.

## Layout

```
app/.build.ae    aether.program { source extra_source include_dir output }
app/app.ae       entry: main() reads argv, calls greet.greeting + extern c_triple
app/cbits.c      a committed C *library* (not a main shim); #includes rom.h
inc/rom.h        a header in a non-source include dir (resolved via include_dir)
app/.tests.ae    build.dep app, then bash.test (runs test_argv.sh)
app/test_argv.sh argv + link-direction + clean-source-tree assertions
greet/module.ae  a pure-Aether library (no .build.ae) pulled in via `import greet`
```

## Run

```
cd itests/aether-program-spike
aeb            # builds app (Aether main(), no C main)
aeb --tests    # runs the argv assertion
./target/app/bin/app script.js
#   argv1=script.js
#   greet=hi-script.js
#   triple=21
```

The `app` binary's entry is `app/app.ae`'s `main()`; there is no
committed C `main`. `cbits.c` is a C *library* the program FFIs into,
which an Aether program is allowed to link.
