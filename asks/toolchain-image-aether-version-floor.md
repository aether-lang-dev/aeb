# Toolchain base image must carry Aether >= the version floor current aeb requires

**Filed by**: aeb Claude, 2026-06-14, climbing the "agent drives ephemeral
toolchain containers" ladder against ../google-monorepo-sim on bazzite. The
first rung that runs REAL `aeb` (not raw cargo) inside the container exposed a
hard build break, not a soft staleness.

**Severity**: blocking for the container-driven / run_on=podman agent vision.
The toolchain images can't run a current `.build.ae`, and can't be refreshed
in place.

**UPDATE 2026-06-18 — now the explicit blocker for ladder Rung 4 (two-image
cross-language).** The per-node container mechanism (`AEB_NODE_CONTAINER=1` in
aeb-driver) is built + proven for one image: the rust node built
`libvowelbase.so` in `aeb-tc:rust-1.75`. The two-image proof (rust `.so` → jdk
node links it in `aeb-tc:jdk-21`) is gated SOLELY on this: the `aeb-tc:jdk-21`
image carries **ae 0.209**, but current aeb needs a higher floor — refreshing
that image's aeb fails at `tools/aeb-cli.ae` because its ae can't compile current
aeb. The `aeb-tc:rust-1.75` image refreshed cleanly because it already had
**ae 0.257**. So the fix is concrete: rebuild the toolchain images on an ae ≥ the
floor (and have the image build ASSERT the floor) before the cross-language
ladder can be two-image-green.

## The two stale layers, stacked

```
aether-builder:slim   → ae/aetherc 0.209   (host is 0.256)   [aether-build project]
   └─ aeb-toolchain:slim → aeb v0.056 (2026-06-03, pre-prereq) [our Containerfile]
        └─ aeb-tc:{rust,go,jdk,...}                            [per-job toolchain layers]
```

## What happens

1. **Stale aeb can't parse the current monorepo.** In-container `aeb` is git
   v0.056 (frozen when the image was built 2026-06-03). It predates `prereq()`.
   Running `aeb rust/components/vowelbase/.build.ae` →
   `error[E0301]: Undefined function 'prereq'` — the build file declares
   `prereq(b, "rust:1.75")`, which v0.056's `build` module doesn't have.

2. **Can't rebuild the image with current aeb either.** Rebuilding
   `aeb-toolchain:slim` (FROM aether-builder:slim, `git clone --branch main`,
   `make install`) FAILS to compile under the base's ae 0.209:
   ```
   tools/aeb-cli.ae:304:9  os.run_supervised(prog, argv, null, 1, 1, timeout_secs, 1)
     E0301 ... use single assignment instead, or ensure the function returns multiple values
     E0300 Undefined variable 'code'   (10 errors total)
   ```
   `os.run_supervised` is an **Aether >= 0.231** primitive (CHANGELOG 0.231; the
   native entrypoint's supervision tail). So **current aeb hard-requires Aether
   >= 0.231** — a HARD floor: below it `make install` doesn't build, it's not a
   capability degrade.

## The constraint (the real finding)

**The toolchain base image's Aether must be >= the version floor current aeb
requires (today: >= 0.231 for `os.run_supervised`).** The aether-builder base
at 0.209 is below the floor, so it can't build current aeb at all. The two
stale layers are NOT independently fixable — fixing aeb-toolchain requires
first bumping the aether-builder base.

## What's wanted

1. **Rebuild `aether-builder:slim` with a current Aether** (>= the aeb floor;
   pin to host's 0.256 to be safe). This is an aether-build-project operation
   (no `../aether-build` sibling on this box — only `../aether` @ 0.256).
2. **Then re-layer** aeb-toolchain:slim (current `main` aeb) + the aeb-tc:*
   siblings on top.
3. **Encode the floor so this fails loudly, not cryptically.** aeb should know
   its own minimum Aether (a constant / `aeb --requires-aether`), and the image
   build (and ideally the agent at run_on=podman dispatch time) should assert
   `in-image ae >= floor` and refuse with a clear message instead of a 10-error
   codegen dump or a `prereq`-undefined parse error deep in a build.
4. **Stamp the image with its aeb + ae versions** (a label) so an operator /
   the agent's /ping can see staleness before dispatching into it.

## Acceptance

A freshly built toolchain image runs `aeb <target>` on a current `.build.ae`
(with `prereq(...)`) without parse/codegen errors, and the image build asserts
the Aether floor up front. Proven against
google-monorepo-sim/rust/components/vowelbase (the rust node) and then the
4-toolchain `directed_graph_build_systems_are_cool` closure.

## Cross-ref

- memory `layered-temp-containers-on-aeb-base` (the ladder + this blocker)
- memory `per-job-agent-image` (the run_on=podman per-dispatch image vision)
- `docs/design/two-aeb-duality.md`, `tools/container/Containerfile.aeb-toolchain`
