# Re: "catchyos's installed aeb has a broken lua SDK (lib/lua/module.ae:255)"

**Verdict: not a live bug in the current lua SDK — catchyos (.160) is a stale
checkout + stale toolchain. Update the box and reinstall; the break is gone in
current aeb.**

## What was reported

> catchyos's installed aeb has a broken lua SDK
> (lib/lua/module.ae:255 — string_concat incompatible pointer type)

Line 255 is:

```aether
run_cmd = string.concat(bldr._env_export_prefix(_builder), run_cmd)
```

## What I found on .160

- `~/scm/aeb` is at **`v0.286-2-g0488fde-dirty`** — the **pre-Shape-A grammar**
  (`bldr.build(b) { … }`, 2 args). `main` is now at **v0.289**
  (`bldr.build() { … }`, no `b`). The tree is months behind.
- The **installed** aeb (`~/.local/share/aeb/AEB_STAMP`) says:
  ```
  commit    v0.286-2-g0488fde-dirty
  installed 2026-08-30 14:54:00
  toolchain ae 0.591.0
  ```
  i.e. it was built from that dirty checkout with **ae 0.591.0**.
- `lib/lua/module.ae:255` on .160's HEAD is **byte-identical** to current `main`.
  The *source* was never the problem.

## Root cause

The `string_concat incompatible pointer type` at a `map.get`-derived string
(`_env_export_prefix` reads `proc_env` out of the builder map) is the
**ae-0.591 codegen bug** — the same class as **handoff #1's map.get /
string-as-pointer bug**, which a later ae fixed. `main` is pinned to validated
**ae 0.609.0** (v0.289 shipped 133/133 against it); 0.609 does not miscompile
that path.

## Fix (box-owner action on .160 — needs your push/pull)

```sh
# 1. bring the tree current (new grammar + pinned-ae contract)
git -C ~/scm/aeb fetch origin && git -C ~/scm/aeb checkout main && git -C ~/scm/aeb pull
#    should land on v0.289 (b2ecd57 region)

# 2. update the ae toolchain to the pinned/validated 0.609.0
#    (whatever your ae-update path is on .160)

# 3. rebuild + reinstall aeb
cd ~/scm/aeb && make
aeb tools/agent/.install.ae
aeb tools/lease/.install.ae
# (tools/keygen/.install.ae is a SEPARATE known break: keygen/.dist.ae uses
#  cryptography.base64_encode which an Aether stdlib change removed — unrelated
#  to lua; skip or expect it to fail until that .dist.ae is fixed.)
```

After that, `AEB_STAMP` should read `v0.289` / `ae 0.609.0`, and the lua node
compiles clean (verified on this box: a real `lua.conformance()` node builds
green under 0.609).

## Confirmation I ran

- Current `main` lib/lua compiles green via a real Shape-A `lua.conformance()`
  node under ae 0.609.
- On .160 under its own ae 0.591, a bare `import lua` compiled — the break only
  bites when the full `_env_export_prefix` string path is exercised, matching
  the 0.591 codegen-bug fingerprint.
