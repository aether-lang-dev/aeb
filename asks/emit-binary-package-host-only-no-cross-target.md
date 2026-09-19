# `aether.emit_binary_package` is host-triple-only — no cross-target emit for one-host publishers

**Filed by**: servirtium-vcr Claude, 2026-09-19, after adopting the `ae add`
producer side (aeb v0.316/v0.317, ae 0.695). Works great for the host triple;
this is about the cross-build case. Design note + a heads-up that we're
synthesizing, not a demand to implement.

## What we did (and it works)

Wired `aether.emit_binary_package() { stem("servirtium_vcr");
output("libservirtium_vcr.so") }` into `core/.build.ae` beside the `shared_lib`.
`aeb core/.build.ae` stages the trio under `target/build/core/ae-add/`
(`aether.toml` + `servirtium_vcr-<tag>-linux-x86_64.so` + `.sha256`), verified
against `ae_try_binary_package`'s contract — checksum OK, `.so` byte-identical to
the shared_lib output. `ae add github.com/servirtium/servirtium-vcr@<tag>` then
imports it. Thank you — the consume side is clean.

## The gap

`emit_binary_package` names its asset from **`bldr._host_os_arch()`** — the
RUNNING host's triple. So one `aeb` run emits exactly one triple. The commit
message's model is "one emit per platform for the full per-triple set" — i.e. run
the emit on each platform's own runner.

But servirtium-vcr's `release/` (and selenium's) deliberately **cross-build the
whole matrix from ONE Linux host** via `ae build --emit=lib --target=<triple>`
(zig cc) — no per-OS runners, by design (a slow/absent macOS/Windows runner never
blocks a release; every artifact is deterministic bytes). That path doesn't go
through the `aeb` builder at all, and even if it did, `emit_binary_package` would
stamp every artifact `linux-x86_64`.

So a one-host cross-build publisher can't get the full per-triple `ae add`
package from the builder.

## What we did about it (the heads-up)

We **synthesized** the per-triple `ae add` set in `release/build.sh`: for each
cross-built `libservirtium_vcr-<tag>-<os>-<arch>.<ext>` we stage a
`servirtium_vcr-<tag>-<os>-<arch>.<ext>` (the STEM name, no `lib` prefix — the
triple spelling is exactly your `_host_os_arch`), write its `.sha256`, and emit
one shared `aether.toml` (`[package] binary = "servirtium_vcr"`, `modules = "."`).
Uploaded flat to the GitHub release; `ae add` fetches the one matching the
caller's host. This reproduces your asset format exactly — but it's us
hand-rolling your contract, which drifts if the contract changes.

## The ask (a forward direction, pick either)

1. **A cross/target mode for `emit_binary_package`** — e.g. a `target(triple)`
   setter (or reading `--target` the way `shared_lib` cross-builds do) so the
   asset is named for the *built* triple, not the host. Then a one-host loop over
   the matrix produces the full set through the builder, no synthesis.
2. **Or bless a documented "assemble the set yourself" contract** — a short spec
   of the trio (asset name = `<stem>-<tag>-<os>-<arch><ext>`, the `.sha256`
   shape, the `aether.toml` keys) that publishers can target deliberately, so
   cross-build publishers aren't reverse-engineering the builder's output.

Either closes the gap for the build-here/attest-on-hardware release model. selenium
(`libselenium_core`) has the identical cross-build shape, so it lands there too.

## Cross-ref

Consume-side dep fetching is `asks/ae-add-implicating-an-aeb-target.md` (distinct
— that's fetch-a-dep; this is emit-a-package-for-all-triples-from-one-host).
