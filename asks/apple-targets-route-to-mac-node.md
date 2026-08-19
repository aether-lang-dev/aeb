# Apple targets (macOS / iOS) must build on a Mac node — route via `run_on(vm)`, fail-closed when none is configured

**From:** the aeb line (2026-08-19), scoping `aether.program` cross-compile
(`target(...)`) after the wasm32 work landed. **Where it matters:** any
`aether.program(b) { target("aarch64-macos" | "aarch64-ios" | …) }` dispatched
from a non-Mac orchestrator node. **Status:** design note — no `lib/` change yet;
build when the Apple line is picked up for real.

## The correct model: routing, not a wall

An Apple target on a non-Mac node is a **dispatch decision** — "this node can't
build this; send it to one that can" — **not an error to reject**. In a
well-designed build supersystem you do NOT want every node to be a Mac: you want
a *few* Mac builders and the ability to route Apple work to them, exactly as
`run_on(vm)` already routes Windows work to winbaz. A Mac running `aeb-agent` is
a perfectly legal, first-class builder node.

The hard-fail is only the **degenerate case of the routing rule**: fail *when
there is no Mac node to route to*.

## Why a Mac is genuinely required (not a policy affectation)

macOS cross-compiling from Linux works **only for the thin libc tier**: `zig cc`
bundles a clean-room Darwin `libSystem` (verified — `ae build
--target=aarch64-macos hello.ae` on Linux produces a `Mach-O 64-bit arm64
executable`). But **any real macOS program uses proprietary Apple frameworks** —
Foundation, AppKit, CoreFoundation, Security, Metal, the whole Objective-C graph
— and those frameworks' headers and `.tbd` link stubs are **license-gated SDK
material `zig` does not and will not bundle**, identical to iOS. So:

- `main(){ println() }` (libc only) → cross-links from Linux. The trivial case.
- Anything reaching a framework → needs the Apple SDK → **needs a Mac.**

aeb cannot tell from `target("aarch64-macos")` whether the program stays inside
libc or imports Foundation, so the safe, honest default is **all Apple targets →
Mac builder.** The thin-libc exception isn't worth a special case — it would
produce binaries that link today and break silently the moment someone adds a
framework dependency.

**iOS is already gated upstream.** aether itself errors clearly:
`--target=aarch64-ios requires a macOS host with Xcode installed (the iOS SDK is
not redistributable, so it cannot be bundled)` — the `xcrun clang` Tier-C path
(#1385). This note is about aeb routing *around* that, and about extending the
same treatment to `*-macos` (which aether does NOT gate, because zig can link the
libc-only slice).

## What aeb should do

Classify the resolved triple: **Apple** = contains `-macos`/`-ios` (incl.
`arm64-`/`amd64-`/`x86_64-` aliases and `*-ios-simulator`). For an Apple target:

1. **Host is a Mac** (`build._is_macos()` — already exists, no shell-out): build
   locally as normal.
2. **Host is not a Mac, a Mac agent IS configured**: dispatch the compile to it
   via the existing `run_on(vm)` seam — `tools/aeb-agent.ae`'s `_run_on_vm`
   already does *rsync tree → `ssh` the VM/host → run `aeb` on its toolchain →
   rsync artifacts back*, keyed on `--vm-host` / `AEB_AGENT_VM_HOST` (an
   ssh-config alias that can carry a `ProxyJump`). A Mac is just another
   `run_on(vm)` node. (See also the aether SDK's `AEB_COMPILE_CONTAINER`
   delegation seam in `lib/aether/module.ae` — same shape, one indirection in.)
3. **Host is not a Mac, no Mac agent configured**: **fail-closed early**, from
   aeb's grammar rather than mid-shell-out, with a message that names the fix:

   ```
   aether.program: target "aarch64-macos" needs a macOS builder.
     Apple frameworks are proprietary ABIs that can't be cross-linked from
     Linux (zig bundles only the libc slice). Route this node to a Mac agent:
       run_on(vm) with --vm-host <mac-ssh-alias>
   ```

   This mirrors how `_run_on_vm` already fails closed without `--vm-host`
   (run_on(vm) is fail-closed by design — see the run_on(vm) work), and how the
   agent is fail-closed on auth/veto throughout `aeb-agent.ae`.

## Build tiers (do them in this order when picked up)

- **Tier 1 — fail-closed guard (small).** Classify Apple triples; on a non-Mac
  host with no Mac agent, reject early with the routing-aware message above. No
  silent wrong-arch or half-linked output. This is the honest minimum and closes
  the current gap where `target("aarch64-macos")` on Linux either half-works
  (libc only) or fails deep in the shell-out.
- **Tier 2 — auto-route (larger).** aeb detects an Apple target and
  automatically dispatches that node's compile to the designated Mac agent
  through the `run_on(vm)` / `AEB_COMPILE_CONTAINER` path, artifacts rsync back.
  Touches the dispatch path, path rewriting (`_rewrite_under_root`), and agent
  config; **needs a real Mac to prove end-to-end** (can't be fully verified on a
  Linux/Bazzite box).

## Acceptance

- `target("aarch64-macos"|"aarch64-ios"|…)` on a Mac host builds locally.
- The same on a non-Mac host with a Mac agent configured builds ON the Mac agent
  and returns artifacts (Tier 2).
- The same on a non-Mac host with NO Mac agent fails early from aeb with a
  message naming `run_on(vm)`/`--vm-host` as the resolution — never a silent
  libc-only binary, never a deep shell-out failure.
- Non-Apple targets (linux/windows/freebsd/wasm) remain host-agnostic and
  unaffected.

## Related

- `target(...)` cross-compile grammar on `aether.program` (this session's work):
  routes to the `ae build` shell-out; the Apple gate slots into `_build_binary`
  next to the existing manual-override rejection.
- `run_on(vm)` agent dispatch (`tools/aeb-agent.ae` `_run_on_vm`, `--vm-host`):
  the transport this reuses; a Mac node is a new `run_on(vm)` target, no new
  subsystem.
- aether #1385 (iOS via `xcrun`, Tier C) — the upstream reason iOS needs a Mac;
  aeb routes to satisfy it rather than duplicating the SDK logic.
