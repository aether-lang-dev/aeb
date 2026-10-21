# FIXED — aeb SDK compilation on Aether 0.838.0 needs typed string reads

Resolved on 2026-10-21: SDKs and tools now use typed getters for string values
before interpolation, printing, and returning string options. Container and
handle reads retain raw getters. The remote agent uses the exported `std.json`
constructors and encoder. All 20 SDK consumer compile/link probes and all 27
tool cold builds pass on the released 0.838.0 toolchain.

`AETHER_FETCH` now selects 0.838.0 for bootstrap and release builds;
`AETHER_PIN` retains the compatible 0.835.0 minimum. `make install` preserves
both files, with a release gate checking the installed copies. The original
findings below describe the state before this fix.

Found while verifying aeb #17 against the released Aether #3073 consumer fix.
The package-identity change itself needs no new compiler primitive: aeb's pinned
0.835.0 can emit all four distinct glibc/musl packages, and 0.838.0's `ae add`
successfully fetches and verifies each one. These are separate producer and
consumer toolchains, as described in AGENTS.md's two-Aethers section.

Using 0.838.0 to compile aeb's SDK instead fails on existing raw-container
string reads. This also happens without the #17 change. For example:

```text
error[E0200]: cannot interpolate a `ptr`: it has no string rendering.
  lib/bldr/module.ae:184
  println("${label}: FAILED — ${reason}")
```

`label` comes from `map.get(ctx, "module_dir")`. A temporary typed read exposes
the next error in `lib/aether/module.ae`'s `aether_link_cmd()` (string options
read with `map.get`); typing those exposes raw `list.get` reads of regen paths
around `_do_regen()` line 2340. This is a wider SDK compatibility audit, not just
one diagnostic site. No temporary compatibility changes are retained in #17.

Suggested fix: use `map.get_string` / `list.get_string` for actual string data
throughout the affected SDKs, retaining raw getters for containers and handles.
Run the full unit suite, installed-runtime checks, and native/cross-target
smokes with 0.838.0. Do not relax Aether's pointer interpolation checks or add
compatibility fallbacks. Until this audit is complete, compile aeb's own
machinery with its verified 0.835.0 pin and use 0.838.0 for the ae-add consumer.
