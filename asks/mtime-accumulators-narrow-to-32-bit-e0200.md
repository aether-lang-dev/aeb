# python/dart/gleam/moonbit nodes cannot COLD-build — mtime accumulators narrow to 32-bit

> **STATUS: FIXED (2026-09-15).** The staleness accumulators are `long` now.
> Found live-verifying selaenium's bindings.

## Resolution (lib/{python,dart,gleam,moonbit}/module.ae)

`_codegen_can_skip` / `_dir_newest_mtime` folded `file.mtime()` — which returns
`long` (aether `std/fs/module.ae:118`) — into accumulators initialised from a
bare `0`, so they inferred **32-bit int**:

    newest_in = 0
    ...
    t = file.mtime(abs_p)
    if t > newest_in { newest_in = t }      // E0200: 64-bit into 32-bit

E0200 (narrowing assignment) became an error in ae 0.667+, and aeb v0.311 pins
ae 0.675.0, so these four SDK modules stopped type-checking against the very ae
they require.

Fixed by pinning the width on all three accumulators in each module
(`newest_in`, `oldest_out`, `newest`) and on the recursive helper's return:

    long newest_in = 0
    long oldest_out = 0
    long newest = 0
    _dir_newest_mtime(dir_abs: string) -> long {

## Why it went unnoticed

A **warm** tree never re-runs the step — the generated node objects are already
cached — so this only appears on a clean checkout. That is exactly the CI /
new-contributor path:

    $ aeb python/.tests.ae          # fresh git worktree, no target/
    error[E0200]: narrowing assignment to 'newest': its type was inferred as
    32-bit int from its initializer, but a 64-bit value is assigned here and
    would truncate.
      --> target/_aeb/python__D_tests_D_ae.ae:1134:37
    Type checking failed with 1 error(s)
    cc1: fatal error: target/_aeb/python__D_tests_D_ae.c: No such file or directory
    aeb-link: FATAL — failed to link the fan-out orchestrator

Same for `dart/.tests.ae` and `gleam/.tests.ae`. `moonbit` has the identical
helper and is fixed alongside, though no moonbit node was available to test.

Verified: all three cold-build in a fresh worktree after the fix, and 20
selaenium nodes stay green.
