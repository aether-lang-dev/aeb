# run_on=podman veto fails on a STALE toolchain image (aetherc too old for `--emit=ast`)

**Found:** 2026-06-14, integration desk-check of run_on=podman on the bazzite host.

**NOT a code bug — an image-staleness operational finding.** The agent's
container-veto runs `aetherc --emit=ast` (JSON AST → decide()), which is correct
for current aetherc. But the `localhost/aeb-toolchain:slim` image on bazzite
ships **aetherc v0.209.0**, which predates `--emit=ast` (it only has the older
`--dump-ast` text form). So the in-container veto fails → fail-closed → every
run_on=podman dispatch is `vetoed`.

```
# agent log:
Error: --emit must be one of: exe, lib, both (got 'ast')
# image aetherc: v0.209.0   (host aetherc here: v0.256.0)
# v0.209 --help has --dump-ast only; v0.256 added --emit=ast (JSON)
```

## Fix (operational, not code)

**Rebuild the aeb-toolchain images** — they're ~47 aetherc versions behind. The
agent's `/ping` now reports `aether_version`, but that's the agent HOST's
aetherc, not the container's; a stale image isn't visible until a build vetoes.

## Worth considering (follow-ups, not blocking)

1. **Image-freshness check:** run_on=podman could probe the image's
   `aetherc --version` at startup (or first dispatch) and warn if it's behind the
   agent host's — surfacing the skew the way the startup pre-clone check surfaces
   missing slot trees.
2. **/ping could report the container toolchain** (not just the host's) for
   run_on=podman agents, so an originator sees the version a podman build would
   actually use.

## Provenance

Surfaced desk-checking the per-slot-tree / provisioning-modes work — which is
independently correct: the dispatch reached the right slot tree and the right
`--ctr-image`, and the veto mechanism executed against that image (using the
correct `--emit=ast` for a current toolchain). The image just happened to be old.
