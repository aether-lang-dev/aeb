# `get.sh`: an unversioned (source-built) aeb on PATH could never be upgraded

> **STATUS: FIXED (2026-09-15).** The `0.0.0` path honours an explicit `AEB_REF`
> (and `AEB_FORCE`) instead of returning unconditionally. Found in selaenium.

## Resolution (get.sh, `aeb_ensure`)

A source-built aeb reports version `0.0.0`, and that case returned before any
pin was considered:

    if [ "$_have" = "0.0.0" ]; then
        say "aeb (source build, unversioned) already on PATH — skipping floor check"
        say "using aeb: $(command -v aeb)"; return 0
    fi
    if [ -n "$_want" ] && [ -n "$_have" ] && [ "$_want" != "$_have" ]; then
        if version_ge "$_have" "$_want" && [ -z "${AEB_FORCE:-}" ]; then   # AEB_FORCE only here

So following the README one-liner with an explicit pin exited **0**, printed
"done. Pin this in CI with: AEB_REF=v0.307", and left the old source build in
place. `AEB_FORCE=1` could not help either: it is only consulted in the
newer-than-requested branch, which the early return made unreachable. There was
no supported way to move a source-built aeb onto a pin — the only workaround was
to `mv ~/.local/bin/aeb aside` and re-run.

The fallout was confusing, because the stale aeb then failed *every* node,
including untouched ones:

    error: unresolved import 'cache': no module of that name was found

which reads like a repo problem, not a toolchain one.

There is genuinely no floor to check for an unversioned build, but an explicit
`AEB_REF` is a REQUEST, not a floor. The branch now falls through to the install
when a pin or `AEB_FORCE` is given, and only skips when neither is:

    if [ -z "$_want" ] && [ -z "${AEB_FORCE:-}" ]; then
        say "aeb (source build, unversioned) already on PATH — skipping floor check"
        say "using aeb: $(command -v aeb)"; return 0
    fi
    say "aeb (source build, unversioned) on PATH, but ... — installing ${_want:-latest}"
    # fall through
    elif [ -n "$_want" ] && ...

(The second `if` became `elif` so the fall-through reaches the installer rather
than the "already on PATH — skipping" else-branch.)

## Verified

Branch logic driven directly over every combination:

| have | AEB_REF | AEB_FORCE | result |
|---|---|---|---|
| 0.0.0 | v0.307 | – | **INSTALL** (was SKIP — the bug) |
| 0.0.0 | – | 1 | **INSTALL** (was SKIP) |
| 0.0.0 | – | – | SKIP (unchanged — a bare source build is left alone) |
| 0.300.0 | v0.307 | – | INSTALL (unchanged) |
| 0.320.0 | v0.307 | – | KEEP-NEWER (unchanged) |
| 0.320.0 | v0.307 | 1 | INSTALL (unchanged) |
| 0.311.0 | – | – | SKIP (unchanged) |

`sh -n` and `bash -n` clean. Companion to the earlier
`asks/get-sh-skips-on-presence-ignores-explicit-aeb-ref.md`, which fixed the
same class of skip for *versioned* installs and left the `0.0.0` path behind.
