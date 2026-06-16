# `aether.program` needs a per-node `lib()` setter (extra aetherc `--lib` search dir)

> **STATUS: PROPOSED (2026-06-16).** Not yet implemented.

**Filed by**: the aether-ui GUI-toolkit project (sibling claude session), while
migrating the repo to per-app `.build.ae` nodes. The 11 toolkit examples moved
cleanly into `examples/<app>/` (their only cross-import, `import aether_ui`,
resolves because the repo root is already on `AEB_COMPILE_LIB`). The 20 `aevg/`
apps are blocked: they `import vg`, `import vg_live`, `import loader`,
`import aevg_gtk_backend` — sibling modules living in `aevg/`. Move an aevg app
source into `aevg/apps/<app>/<app>.ae` and aetherc fails `E0301: Undefined
function 'vg'`, because the imported modules are neither in the source dir nor
on any `--lib` path the node controls.

**Severity**: blocks moving the aevg app *sources* into per-app dirs (the clean
layout). Workarounds exist but each is worse than the feature: keep aevg sources
flat in `aevg/` (descriptors-only — uneven layout vs. examples/), or symlink the
4 shared modules into each of 20 app dirs (clutter + symlink fragility on the
Windows/macOS checkouts). The toolkit-examples half of the migration shipped
without this; the aevg half is parked on it.

## The gap

`aether.program`'s aetherc invocation gets its module search path solely from
`AEB_COMPILE_LIB` (env, set by the orchestrator as `<aeb_lib>:<repo_root>` —
see `lib/aether/module.ae` `_shell_out_ae_build` / `_ae_build_lib_flags`). There
is **no `.build.ae`-level setter** to add a directory to that `--lib` set. Setting
`AEB_COMPILE_LIB` in the invoking environment doesn't take (aeb derives it
itself, overriding the inherited value). So a node whose source imports modules
from a repo subdir other than the source dir / root cannot be expressed.

There's a setter for the C side already (`include_dir(dir)` → gcc `-I`); this is
its missing Aether-side twin (`lib(dir)` → aetherc `--lib`).

## Proposal

A repeatable `lib(_ctx, dir)` setter on the `aether.program` (and
`aether.program_test`/`driver_test`) builders, mirroring `include_dir`:

```
// in a .build.ae
aether.program(b) {
    source("rubiks_cube.ae")
    output("rubiks_cube")
    lib("${root}/aevg")          // ← aetherc --lib for the shared vg/* modules
    no_closure_regen()
    ui_backend(root)
}
```

Storage: same shape as `include_dir`/`link_flag` — append to a `"lib"` list on
the builder map; the drain that builds the aetherc cmd appends each as
`--lib <dir>` *after* the env-derived `AEB_COMPILE_LIB` flags (so a node can add
to, never lose, the orchestrator's path). Relative dirs resolve against
`source_dir`, absolute pass through — the same rule `include_dir` uses.

Cache-key: fold the `lib` entries into the existing
`_cache_key_for_aether_link` inputs (a changed lib path should invalidate, like
`include_dir` does).

## Acceptance

`aeb aevg/apps/rubiks_cube/.build.ae` (source moved into the app dir, importing
`vg`/`vg_live` from `aevg/` via `lib("${root}/aevg")`) compiles and produces a
running binary — no symlinks, no flat-layout exception. Then all 20 aevg apps
fan out the same way the 11 examples already do.
