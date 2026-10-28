# aeb's std-regen uses a too-old aetherc for Aether 0.855

**From:** servirtium-vcr (sv) session, 2026-10-28
**Blocks:** bumping sv (and any aeb-driven repo) to Aether 0.855.0

## Symptom

`aeb core/.build.ae` on a repo targeting Aether 0.855.0 fails repo-wide with:

```
error[E0100]: unknown extern-param attribute
  (expected @aether, @retain, @noescape, @into, @keep or @holds)
  --> ~/.aether/share/aether/std/io/module.ae:41:33
41 | extern io_file_info_free(info: @frees ptr)
```

…repeated for std/string, std/fs, map, zip, zstd, alloc, arena, collections,
msgpack, floatarr, strarr, etc.

## Root cause

- Aether 0.854/0.855 introduced new extern-param ownership attributes **@frees**
  and **@moves** (the #1300 use-after-free / ownership work), and 0.855's std
  library now USES them.
- aeb v0.337 (and current HEAD) both pin `AETHER_PIN=AETHER_FETCH=0.840.0`, and
  aeb shells its cached 0.840 aetherc (`~/.cache/aeb/toolchain/aether-0.840.0/
  bin/aetherc`) to (a) compile its orchestrator and (b) **regenerate imported
  std modules via `--emit=lib`**. That 0.840 aetherc predates @frees and rejects
  it.
- 0.855's own aetherc parses @frees fine — a direct `ae run` importing std.io
  works on 0.855. The break is purely aeb's internal pinned aetherc being older
  than the std it regenerates.

Bisected: @frees is ABSENT from std in v0.853.0 and PRESENT in v0.855.0 (landed
in 0.854 or 0.855).

## Ask

Cut an aeb release with `AETHER_PIN`/`AETHER_FETCH` raised to 0.855.0 (or
whichever ≥0.854 you verify), so aeb's std-regen path parses @frees/@moves.

## Notes

- sv needs no changes for this — it builds clean on 0.849 via aeb v0.337 today.
- A general observation (not a demand): whenever Aether adds a token the parser
  accepts (a new extern attribute here), aeb's regen-of-std path needs an
  aetherc at least as new as the std it is handed, or every consumer repo breaks
  at once on the std-version bump. The AETHER_PIN floor is doing double duty —
  "oldest ae that compiles aeb's own sources" vs "newest std aeb may be asked to
  regen". The second is the one that bit here.

## Resolution

RESOLVED in aeb v0.338 (2026-10-28): `AETHER_PIN` and `AETHER_FETCH` raised to
0.855.0. Verified: a node importing `std.io` builds and runs with either a 0.849
or a 0.855 `ae` on PATH (the older one makes aeb fetch 0.855.0 into its cache).
The floor-vs-std-version point stands: the floor has to move whenever Aether's
std adopts syntax older compilers reject.
