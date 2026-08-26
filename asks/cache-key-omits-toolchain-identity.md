# The aether.program cache key omits the toolchain's identity — same-path upgrades serve stale binaries

**From:** the aether-ui line (2026-08-25) · **Where it bit:** a git-bisect
harness for aether#1657 whose per-step verdicts were quantized by cache
aliasing rather than by the checked-out compiler — and, in hindsight, the
macvm incident where `ae --version` said 0.562 while every app ran
0.541-compiled code.

## Reproduction (clean, today)

1. Build aether at commit A, `make install PREFIX=$SCRATCH`.
2. `AETHER=$SCRATCH/bin/ae aeb apps/rubiks_cube/.build.ae` → [miss], builds.
3. Rebuild aether at commit B (different codegen), install to the SAME
   `$SCRATCH`.
4. `rm -rf target/.aeb target/_aeb target/build/apps/rubiks_cube`, then the
   same aeb invocation → **[hit] in 0.08s** — the step-A binary is restored
   from `~/.cache/aeb`, and no `.c` is even regenerated.

`_cache_key_for_aether_link` hashes the source, the builder map, the lib
DIR PATH, dup_flag and shared-libs text — the path invalidates when it
*moves*, but the toolchain's CONTENT at that path is not in the key, so
upgrading in place is invisible.

## Why it matters beyond bisects

* Every box upgrade is a same-path upgrade (`/usr/local`, `~/.local`).
  After one, `aeb <node>` reports [hit] and hands back binaries compiled
  by the OLD toolchain — the macvm shape: version strings say new, every
  behaviour says old. We now rm -rf caches by hand around upgrades, which
  is folklore, not a contract.
* It quietly undermines any A/B experiment that varies the toolchain —
  the [hit] is silent, so the experimenter believes both legs rebuilt.

## Second omission, same day: extra_source contents

The key also omits the CONTENT of `extra_source` C files. aether-ui's
apps all compile `backend/aether_ui_<os>.c` via extra_source; editing
that file and rebuilding an app whose .ae did not change reports
`[hit] 1.00s` and restores a binary WITHOUT the backend edit. Cost a
debugging loop on winbaz (the scaled-blit fix "didn't work" — the binary
under test simply didn't contain it), and means every backend-only
commit ships boxes whose next matrix measures stale binaries unless
someone remembers to cache-bust by hand.

## Ask

Fold into the key: (a) the toolchain identity — `aetherc --version` plus
a hash of the aetherc binary (or mtime+size); (b) the content hash of
every extra_source file, same as the .ae source already is. The full
`ae cflags` output would additionally catch flag-affecting rebuilds at
the same version. An env escape hatch already exists (`AEB_CACHE_DIR`)
and is what our bisect and backend-edit verifications use per step, but
correctness shouldn't require knowing to use it.
