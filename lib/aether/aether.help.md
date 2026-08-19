# aether SDK — authoring notes

Surfaced by `ae help <script>.build.ae --lib .aeb/lib` when a name
below appears. See docs/cic-help.md for the mechanism.

## `extra_source` / `link_flag` / `regen` flip the build path

`aether.program(b)` shells out to `ae build` by default — the simple,
recommended path. Declaring ANY of `extra_source(...)`, `link_flag(...)`
or `regen(...)` opts the target into the manual `aetherc + gcc` path
instead, which compiles each file itself and links explicitly. That is
intentional, but surprising if you added one `extra_source` line not
realising it changes how the whole target builds.

Pattern: literal-name `extra_source`

## Bare setters need the second import line

Setters inside an `aether.program(b) { ... }` block (`source`,
`output`, `extra_source`, `link_flag`, `regen`, `target`) resolve as
plain top-level calls, not against the `aether` namespace. The block
needs BOTH `import aether` and a selective `import aether (source,
output)`. A missing second import surfaces as `undefined function
'source'`.

Pattern: literal-name `source`

## `regen` runs before the build, gated on mtime

`regen(...)` declares an `.ae` → generated-`.c` step that runs before
the program build, skipped when the output is newer than the input.
It does not run unconditionally and is not a post-build hook.

Pattern: literal-name `regen`

## `no_closure_regen` is for extern-backed (thin-over-C) imports

`no_closure_regen()` suppresses the transitive import-closure regen
pass — the auto-`--emit=lib` of every project-local imported `.ae`.
Reach for it ONLY when the entry imports modules whose Aether bodies
are `extern` declarations of a C ABI (the implementations live in C,
linked via `extra_source`). Those modules can't be `--emit=lib`'d
standalone — that fails with `E0301 Undefined function`. With this set
the entry is plain-compiled and your `extra_source` C + `link_flag`s
do the linking. A pure-Aether project does NOT want this — it would
have to enumerate every sibling import by hand. Explicit `regen(...)`
entries still run; the import closure still feeds the cache key.

Pattern: literal-name `no_closure_regen`

## `target` cross-compiles via `ae build` (host-only manual path excluded)

`target("wasm32-wasi")` (or `aarch64-linux`, `x86_64-macos`,
`x86_64-windows`, `…-freebsd`, `wasm` for the Emscripten `.js`+`.wasm`
pair) cross-compiles the program through `ae build --target=<triple>`,
aether's bundled zig-cc / emcc backend. The output is named for the
TARGET: any wasm triple → `<output>.wasm`, a cross `*-windows` triple →
`.exe`, others extensionless.

It always uses the `ae build` shell-out — the only path that can target
a foreign triple. So `target()` cannot be combined with the manual-path
setters (`extra_source` / `link_flag` / `include_dir` / `regen`), which
link for the host with local gcc; declaring both fails the build with an
explanatory error rather than silently producing a host binary. A cross program
that needs hand-linked C wants `aether.csrc` + a downstream `c.program`
cross build instead. Staleness is `ae build`'s own incremental cache, so
aeb reports `[n/a]` for a cross target.

Pattern: literal-name `target`
