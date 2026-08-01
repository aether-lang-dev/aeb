# Structuring an aeb build that go-gets the Aether zsync sources and emits the `.so`s (no tests)

**Filed by**: aeb Claude, 2026-06-15. Follow-on to
`zsync-delta-transport-for-dispatch.md`: Paul's intent is to **pull zsync's
client + server `.so` into aeb** and link them as the delta transport. This note
answers "how do we structure the aeb build to fetch the zsync pieces and make
the `.so`s, skipping tests" — given there is **no package landscape yet**.

## What already exists (more than expected)

- **Aether package fetch:** `ae add github.com/u/repo[@version]` (go-get style)
  + `aether.toml [dependencies]`, resolved into the `lib` search path
  (`~/.aether`). This is for importing an Aether module as a dep.
- **aeb `lib/fetch`** (the Bazel `http_archive`/`http_file` analogue):
  `fetch.archive` / `fetch.file` — pull a tarball/file by URL, sha256-verify,
  extract. GitHub serves any repo@ref as a source tarball.
- **`aetherc --emit=<exe|lib|both>`** — "lib produces .so/.dylib" — plus
  `--emit-header` (C embedding header) and `--emit-main` (thin shim).
  `lib/aether` ALREADY drives `--emit=lib` internally for its regen pass.
- **A near-exact precedent:** the **tinygo sidecar** in `lib/aether` — a
  sibling-language module compiled to a c-shared `.so` that the Aether program
  `tinygo.load()`s at runtime. The zsync case is the *Aether-native* version of
  that pattern.

## The recommended structure: fetch (http_archive) + emit=lib, arms-length

Use `lib/fetch` (NOT `ae add`) to pull zsync's SOURCE tarball into a build dir,
then `--emit=lib` over the named client/server modules. Why fetch-tarball over
`ae add`:

- **License boundary stays clean.** We pull zsync SOURCE into `target/_vendor/`,
  build a `.so`, link it — we never `import` zsync `.ae` into aeb's module graph.
  zsync (Artistic-2.0) is consumed as a built artifact, aeb stays MIT (Artistic
  §7/§8 permit linking the `.so`). `ae add` would put it in aeb's import path.
- **Pinned + reproducible.** `fetch.archive` with a `sha256` pins the exact ref.

Sketch (`.build.ae`):

```
import build
import fetch
import aether

aeb(cap) {
    b = build.start()

    // 1. go-get the zsync sources by pinned ref (github serves any ref as a tarball)
    fetch.archive(b) {
        url("https://github.com/aether-lang-dev/zsync-port/archive/<sha>.tar.gz")
        sha256("<digest>")
        extract_to("target/_vendor/zsync")
        strip_components(1)
    }

    // 2. emit the two .so — list ONLY client/server modules; test_*.ae are simply
    //    never named, so tests are skipped BY CONSTRUCTION (not run-then-ignore).
    aether.shared_lib(b) {                       // <-- the missing verb (below)
        source("target/_vendor/zsync/zsync/control.ae")
        source("target/_vendor/zsync/zsync/download.ae")
        extra_source("target/_vendor/zsync/rcksum/fileio.c")   // the C shim
        emit_header("target/zsync/zsync_client.h")
        output("libzsync_client.so")
    }
    aether.shared_lib(b) {
        source("target/_vendor/zsync/cmd/fileserver.ae")
        output("libzsync_server.so")
    }
}
```

**"Skipping tests" is free**: aeb only compiles the targets it's told to. You
name `control.ae`/`download.ae`/`fileserver.ae`; you don't name `*_test.ae`.
There is no test phase to skip — zsync's own `make test` is a different target
aeb never invokes.

## The one missing piece: an `aether.shared_lib(b)` verb

`lib/aether` exposes `program` (→ exe) and the regen helpers, and it already
shells `aetherc --emit=lib` internally — but there is **no public verb that
builds a standalone `.so` + header from named sources**. That verb is the gap:

```
aether.shared_lib(b) { source(...) extra_source(<c shim>) emit_header(...) output("lib*.so") }
  → aetherc --emit=lib <sources> <c-objs> -o <output>  (+ --emit-header)
  → publishes a `shared_library_deps_including_transitive` artifact (the same
    one tinygo/_collect_shared_libs already consume) so a downstream program
    that deps this lib gets it on its link line + LD path automatically.
```

It mirrors `aether.program` but with `--emit=lib` instead of exe, reusing the
existing `extra_source` / `link_flag` / `include_dir` setters for the C shim.
Modest, self-contained, and it generalises beyond zsync (any "Aether module →
linkable `.so`" need).

## How aeb then consumes the `.so`

The agent (or a `lib/zsync_transport` wrapper) deps the `.so` target; aeb's
existing `_collect_shared_libs` / `shared_library_deps_including_transitive`
machinery (already used for tinygo sidecars) puts it on the link line + LD path.
The transport wrapper calls the exported C-ABI entry points (client: seed +
`.zsync` URL → fetch changed blocks; server: serve file + `.zsync`).

## Work items, in order

1. **In `../zsync`** (keep it aeb-free / Artistic): nothing strictly required if
   aeb fetches source — but a clean **exported C-ABI surface** helps (a thin
   `extern`-exported wrapper `.ae` for the two entry points), since the current
   functions are shaped for executables, not a library ABI.
2. **In aeb `lib/aether`:** add the `shared_lib` verb (`--emit=lib` + header +
   the shared-lib dep artifact).
3. **In aeb:** the `.build.ae` above (fetch + two `shared_lib`s), then a
   transport wrapper that links + calls them.

## Cross-ref

- `zsync-delta-transport-for-dispatch.md` (why — the delta transport)
- `lib/fetch/module.ae` (http_archive), `lib/aether/module.ae`
  (`--emit=lib` internals + the tinygo c-shared `.so` precedent)
- `../zsync` (the port; `make test` = 94/94 green on Aether 0.257)
