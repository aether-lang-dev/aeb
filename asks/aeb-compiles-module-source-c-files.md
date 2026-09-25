# aeb compiles a module's `@source` C files (aether #2125)

**Status:** shipped. **Related:** `asks/wip-aether-0716-compat-handoff.md`
listed this under "Related, not on this branch"; this is that follow-on.

## The gap

Aether 0.705+ lets a module ship its own C: `@source("foo.c")` at the top of
`module.ae`, resolved by the compiler against the module's directory. Codegen
emits one `// aether-source: <path>` line in the generated C's header, right
after the `// aether-link: <tokens>` line. `ae run`/`ae build` read those lines
and compile each file into the program (the reader is `get_aether_source_files`
+ `same_source_file` in aether `tools/ae.c`).

aeb read only `// aether-link:`. So a program importing a module that ships C
linked with `undefined symbols` on aeb's own-link paths, unless the program
restated the file with `extra_source(...)`. OpenDisk-ae did that for its
`od_stat`/`od_text` modules (`extra_source("od_stat.c")` / `("od_text.c")`).

## Two paths, because aeb links two ways

aeb only hits this when it bypasses `ae build` (which handles `@source` itself):

1. **Manual `aether.program`** (`lib/aether/module.ae`) — the aetherc + gcc path
   taken when `extra_source`/`link_flag`/`ui_backend`/`regen` is present. It
   already read `// aether-link:` via `bldr._aether_link_libs`; the fix adds the
   sibling read.
2. **Fan-out orchestrator** (`tools/aeb-link.ae`, the `_ae_build_all` single
   binary) — one gcc links every TU. It already had a `// aether-link:` twin
   (`_aether_link_libs_link`); aeb-link is a separate binary and cannot import
   `lib/bldr`, so the source reader is a twin there too.

A plain `aether.program() { source() output() }` with no opt-in goes through the
`ae build` shell-out and was never affected.

## Design decisions

- **Read every TU, not just the entry.** The shipped C is named by whichever
  module in the closure declared `@source` — often an imported module, not the
  program's `main.ae`. So both paths scan the main TU *and* each regen'd
  `_generated.c` (manual path) / every `c_file` (orchestrator).
- **Dedup by canonical path, not by spelling.** The same source routinely
  appears in two TUs spelled two ways — relative (`shim.c`, from a TU compiled
  with the source dir as cwd) and absolute (`/abs/shim.c`, from aeb's relocated
  regen compile). ae.c dedups by dev+inode; Aether has no inode primitive, so
  aeb keys on `fs.realpath` (which dereferences to one canonical string),
  falling back to the path as written when it does not resolve — the same
  fallback ae.c uses for a spelling that does not `stat`.
- **Resolve relative paths against the module's dir.** The manual path anchors a
  relative `@source` to the program's `source_dir` (the base `extra_source`
  already uses); the orchestrator anchors to the discovered `repo_root`. In
  practice aeb's relocated compiles emit absolute paths, so the relative branch
  mostly bites the entry TU only — but it is honoured either way, matching `ae`.
- **`.m` files pass straight through.** Objective-C sources compile as ObjC by
  extension under clang; the fix does not force `-x c`. (macae's 13 `@source`
  modules use `.m` + `@link "-Wl,-framework,X"`; the framework flags already
  ride the `// aether-link:` path.)
- **Quoted tokens.** Each resolved path is emitted quoted so a path with spaces
  survives, as ae.c does.

## Where it lives

- `lib/bldr/module.ae`: `_aether_source_line_file` (pure line parse),
  `_aether_source_files_in` (read one TU's header block),
  `_canonical_source_path` (realpath dedup key), `_accumulate_aether_sources`
  (resolve + dedup into a list), `_aether_sources_link_str` (the gcc-ready run).
  `aether_link_cmd` gains a `source_str` opts key, spliced after `extras_str`.
- `tools/aeb-link.ae`: `_aether_source_files_link` (twin reader returning a
  `{files, seen}` map so dedup threads across TUs), `_is_abs_path_link`,
  `_canonical_path_link`. Spliced into the orchestrator `cc` after the
  `// aether-link:` loop.

## Verified

- `tests/test_aether_source_files.ae` — the pure reader, and resolve/dedup
  (relative→base_dir, and a source spelled two ways collapsing to one token).
- `itests/module-source-c-smoke.sh` — a real `@source` module built by aeb with
  **no** `extra_source`, on both the manual and orchestrator paths, cold + warm.
  Proven load-bearing: disabling the orchestrator source loop reproduces
  `undefined reference` + `aeb-link: FATAL`.
- `tests/run.sh`: 151 → 152 (new unit test), green.
- Removing OpenDisk-ae's two `extra_source` lines and building with aeb: the
  intended downstream confirmation (run on the macOS box that has that repo).
