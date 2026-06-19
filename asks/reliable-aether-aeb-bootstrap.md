# Super-reliable one-go bootstrap of Aether + Aeb (from source)

> **STATUS: DESIGN (2026-06-19).** Sketch first; pick what to build after.

**Filed by**: aeb Claude, 2026-06-19, after refreshing the bazzite toolchain
images for ladder Rung 4 — chaining ae-install then aeb-build by hand, and
hitting the version-floor failure (the `aeb-tc:jdk-21` image's stale `ae 0.209`
couldn't compile current aeb: `failed to build tools/aeb-cli.ae`, cryptically).
That's the unreliability this targets.

## What already exists (and works, mostly)

- **`aether/get.sh`** — fetch a pinned Aether source tarball + `make install`.
  No clone. Knobs: `AETHER_REF`, `PREFIX` (default `~/.local`, no sudo), `CC`.
  Aether → C → only needs cc+make; no chicken-and-egg.
- **`aeb/install.sh`** — the parallel aeb installer (fetch tarball + `make
  install`). Knobs: `AEB_REF`, `PREFIX`, `AETHER`. **Assumes `ae` already
  present** ("install it first if absent").
- **`aether-ui/bootstrap.sh`** — a CONSUMER that chains them: ensure `ae` (via
  get.sh) → ensure `aeb` (via install.sh) → run `aeb`. Idempotent, `*_REF` pins.

So a combined path EXISTS. Three things keep it from being *super* reliable.

## Why it's not super-reliable today (root causes, priority order)

1. **The Aether version floor aeb needs is NOT authoritative.** aeb's required
   `ae` version lives only in PROSE (`README.md`: "`--sandbox` needs aether ≥
   0.230.0") and as a HAND-MAINTAINED `MIN_AE=0.196.0` in *aether-ui's*
   bootstrap.sh — a consumer, already STALE (current aeb HEAD hard-requires
   `os.run_supervised`, used in `tools/aeb-cli.ae`; ae 0.209 fails, 0.257 works —
   floor is ~0.23x, well above the hardcoded 0.196). So "latest ae + latest aeb"
   works only by timing luck; a pinned/stale ae breaks with a DEEP compile error,
   not a clear "too old" message. **This is the #1 unreliability.**

2. **No compatibility resolution for a pinned aeb.** If you pin `AEB_REF=v0.042`,
   nothing records what `ae` *that* aeb was built/tested against. You get "latest
   ae" against an old aeb — may or may not compose.

3. **No "did it actually work" gate.** The installers `make install` and stop.
   aether-ui's bootstrap then builds something, but a GENERIC bootstrap doesn't
   verify the pair composes (compile a trivial `.build.ae`). "Installed" ≠ "works".

## The design — three layers, smallest-first

### Layer 1 — aeb declares + ENFORCES its Aether floor (the load-bearing fix)

Add an authoritative floor to the aeb repo and check it at `make install`:

- `AETHER_MIN := 0.231` (or wherever the true floor is) in aeb's `Makefile`
  (or a `.aether-min` file the Makefile reads — single source of truth).
- At the top of `make install` (before building any `.ae`): read `ae --version`,
  compare to `AETHER_MIN`, and **fail fast with an actionable message** —
  `"aeb HEAD needs ae >= 0.231; you have 0.209. Update: curl …/aether/get.sh | sh"`
  — instead of letting `aetherc` die deep inside `aeb-cli.ae`.
- Pick the floor empirically: it's the lowest `ae` that compiles current aeb
  (the `os.run_supervised`-bearing tools). A CI matrix job could assert it.

**Why first:** converts the #1 unreliability (cryptic deep failure) into a
one-line actionable error, AND gives every consumer + every toolchain-image build
an authoritative number to read instead of a stale hardcoded `MIN_AE`. Highest
value / smallest change. *(Floor exists today only as `aeb --version`'s "tools
built ae X.Y.Z" line — that's the version aeb WAS built with, not the MIN; the
ask is to publish the MIN.)*

### Layer 2 — one combined `bootstrap.sh` in the AEB repo

Promote + generalize aether-ui's bootstrap into the aeb repo so there's ONE
tested one-go path (consumers, CI, and the toolchain images all use it):

```
curl -sSL https://raw.githubusercontent.com/aether-lang-org/aeb/main/bootstrap.sh | sh
```

1. **ensure `ae`**: if `ae` absent OR `< AETHER_MIN` (read from Layer 1, fetched
   from the aeb ref being installed) → install via `aether/get.sh`
   (`AETHER_REF` pin honored).
2. **install `aeb`**: via `aeb/install.sh` (`AEB_REF` pin honored), built with
   the just-ensured `ae`.
3. **VERIFY**: build a trivial in-tmp `.build.ae` (`aether.program` hello) and
   run it — fail loud if the pair doesn't compose. "Installed AND works."

Idempotent (no-op when both are present + recent), `~/.local` default (no sudo),
`AETHER_REF`/`AEB_REF`/`PREFIX` knobs, `curl` the only hard dep.

### Layer 3 — pinned compatibility record (the reliability ceiling)

Make a pinned aeb install a pinned PAIR. aeb already knows the ae it was built
with (`aeb --version` → "tools built ae 0.260.0"); record it per-release:

- `autotag.yml` (which already writes the pinnable `v0.NNN` tag) ALSO writes the
  ae version aeb built/tested against into the tag/release (e.g. a `AETHER_PIN`
  in a committed `TOOLCHAIN.lock`, or the release body).
- `bootstrap.sh`, when `AEB_REF=v0.042` is pinned, reads that record and installs
  the EXACT `ae` aeb shipped with (`AETHER_REF=<pin>`) — reproducible, not
  latest-and-pray. The go.sum-style guarantee, scoped to the toolchain itself.
- Ties to `versioned-bom-and-self-validating-lock.md` (same "pin the resolved
  thing, verify on use" principle, one level up — the toolchain BOM).

## Recommendation

Ship **Layer 1 + Layer 2** as the 80/20 (authoritative floor + one verified
one-go script) — that alone would have turned the jdk-image failure into a clear
"ae too old, run get.sh" and given a single tested bootstrap. Add **Layer 3**
when reproducible pinned pairs matter (CI pinning aeb to a tag, rebuilding old
toolchain images) — it reuses autotag + the `aeb --version` "tools built ae" line
that already exists.

## Acceptance (per layer)

- L1: `make install` against `ae 0.209` fails with "needs ae >= <floor>", not an
  `aeb-cli.ae` compile error. The floor is one authoritative value in the repo.
- L2: `curl …/bootstrap.sh | sh` on a box with NO ae and NO aeb yields a working
  pair (verified by a trivial build), idempotent on re-run, pins honored.
- L3: `AEB_REF=v0.NNN bootstrap.sh` installs the exact ae that aeb ref was tested
  against, reproducibly.

## Cross-ref

- `aether/get.sh`, `aeb/install.sh` (the two halves), `aether-ui/bootstrap.sh`
  (the consumer chain to promote), `.github/workflows/autotag.yml` (L3 pin-write)
- `tools/aeb-cli.ae` `os.run_supervised` (the concrete floor-bearing feature)
- `Makefile` (L1 floor home + the make-install check)
- `asks/toolchain-image-aether-version-floor.md` (the image-side of the SAME
  floor problem — the toolchain images need the floor asserted at build too)
- `asks/versioned-bom-and-self-validating-lock.md` (L3's pinning principle)
