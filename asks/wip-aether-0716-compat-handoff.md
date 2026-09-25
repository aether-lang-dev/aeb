# WIP handoff: aeb on Aether 0.716 (branch `wip/aether-0716-compat`)

**From:** getting aether-ui built and tested against Aether 0.716.0 on macOS
(arm64, Homebrew), 2026-09-24/25. **For:** whoever turns this branch into a
PR. There are two independent commits.

## 1. `file.mtime` → `fs.file_mtime` (build fix)

Aether 0.713 (#2172, commit 043d580b) made std `exports(...)` lists binding.
`std.file` never exported `mtime`; `file.mtime(p)` resolved only because an
unexported call fell through to the C symbol `file_mtime`. On 0.713+:

```
error[E0303]: 'mtime' is not exported from module 'file'
  --> tools/aeb-link.ae:719:18
```

`make` then produced no `tools/aeb-link`, and every aeb build failed with
`sh: .../tools/aeb-link: No such file or directory`. Seven SDKs had the same
call. All now use `fs.file_mtime`, which is the same C function
(`file_mtime`, exported from `std.fs`) with the same result, 0 when the
path is missing. That value matters for the staleness checks, which compare
a source's mtime against a binary's. `fs.mtime` would have been the
idiomatic choice, but it returns a `(value, err)` tuple, and swapping it in
would change the comparison code at every call site.

**Consider also:** bumping `AETHER_PIN` / `AETHER_FETCH` past 0.713 in the
same PR, since the old code cannot build on anything newer. The new code
builds on older Aether too: `fs.file_mtime` has been exported for a long
time.

## 2. Keep `-L` dirs from `ae cflags --libs` (macOS link fix)

`tools/aeb-link.ae`, `_aether_published_libs`, kept only the `-l` tokens and
dropped every `-L<dir>`. On Linux the libraries are on the default search path
so nobody noticed. On macOS with Homebrew, openssl, nghttp2 and pcre2 are
keg-only, and `ae cflags --libs` names their directories:

```
-L/opt/homebrew/opt/openssl@3/lib -lssl -lcrypto -lz -L/opt/homebrew/opt/libnghttp2/lib -lnghttp2 -L/opt/homebrew/opt/pcre2/lib -lpcre2-8
```

Without the `-L` dirs, the orchestrator link failed with `ld: library 'ssl'
not found`, which took down all of aether-ui's fan-out. The fix keeps `-L`
tokens. aeb's own `-L<libaether dir>` appearing twice is harmless.

**Not changed, worth a look:** the pkg-config fallback
(`_resolve_sysdeps_link`, used when `cflags --libs` yields nothing) keeps
whatever pkg-config prints, `-L` included, so it was never affected.

## How it was verified

- `make` builds all tools on Aether 0.716.0 plus aether's
  `wip/opendisk-port-fixes` branch (macOS arm64).
- aether-ui's full `ci.sh` fan-out (about 140 nodes) builds and links with
  both fixes. Without fix 1 nothing builds; without fix 2 the orchestrator
  link fails as shown above.
- `tests/run.sh`: 151/151 on the branch tip, with both commits (macOS
  arm64, Aether built from `wip/opendisk-port-fixes`). On the first run,
  before fix 1 reached `tests/test_aether_regen.ae`, that test failed to
  build with the same E0303, so the suite does catch this breakage.
- Not yet run: Linux, the FreeBSD and Windows legs, or the itests.

## What the finished PR needs

- [ ] Rebase on `main`, then run `make`, `tests/run.sh` and the itests on
      Linux and macOS.
- [ ] Decide on the `AETHER_PIN` bump (see 1).
- [ ] Optionally, a small itest for fix 2: a fake `ae` whose
      `cflags --libs` emits `-L/some/dir -lfoo`, asserting that the link
      line keeps `-L/some/dir`.

## Related, not on this branch

aeb doesn't compile a module's `@source` C files. `ae run` and `ae build`
read the generated C's `// aether-source:` lines. aeb reads only
`// aether-link:`, so a module that ships its own C (Aether 0.705+) links
with undefined symbols under aeb unless the program lists the file with
`extra_source(...)`. OpenDisk-ae does that for now. aeb should read
`// aether-source:` next to `// aether-link:` (`_link_managed_link` and
friends in `tools/aeb-link.ae`).
