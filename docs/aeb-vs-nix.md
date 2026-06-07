# aeb vs. Nix (flakes, derivations, the store)

aeb and Nix both describe build inputs and outputs, but they optimize
for different boundaries — and the *interesting* part of the comparison
is no longer "aeb can't do what Nix does." It's that aeb has, since this
doc's first cut, grown a **deliberate, articulated position** on the
exact axes where it diverges from Nix: toolchain pinning, caching
semantics, and reproducibility. The divergence is now a stance, not a
gap.

> **Update note.** The original version of this doc listed aeb's
> "uses tools from PATH / caches per-target not closures / no pinning"
> as bare *differences*. Each of those has since acquired a designed
> answer that consciously declines Nix's approach rather than lacking
> it. This rewrite reflects that. Where a capability is shipped it's
> **[have]**, designed **[design]**, deliberately-declined **[won't]**.

## The two boundaries, restated

- **Nix** owns the **whole closure**: compiler, libc, runtime, every
  transitive dependency, the build environment, and the output path, all
  content-addressed in a store. Its product is **reproducibility** —
  same inputs ⇒ same output *bytes* on any machine, by construction
  (hermetic sandbox, pinned everything).
- **aeb** owns the **repo's build graph**: dot-prefixed `.ae` targets
  beside the code, the polyglot module DAG, affected-target detection,
  per-module telemetry. Its product is **repeatability under stated
  policy** — same *declared* inputs ⇒ a *working* output (links, tests
  pass), fast, with the rare bad hit caught at the next link/test step.

That second phrase — **repeatability, not reproducibility** — is the
crux of the updated comparison, and it's a position aeb now defends in
writing (see [`distributed-cache-plan.md`](distributed-cache-plan.md)),
not an accident of immaturity.

## Repeatability vs. reproducibility — the considered choice

This is the heart of why aeb is *not* Nix-shaped, articulated rather
than apologized for:

| | Nix (reproducibility) | aeb (repeatability) |
|---|---|---|
| Promise | same source+deps+toolchain ⇒ **same bytes** anywhere | same **declared** inputs ⇒ a **working** output |
| Requires | hermetic toolchains, sandbox, pinned everything | a coarse host fingerprint + a paragraph of policy |
| Optimises for | worst-case correctness (no bad artifact *ever*) | average-case throughput (most hits good; bad hit caught fast) |
| Investment | months (toolchain parity across OS/compiler versions) | days |
| Right when | hyperscaler blast radius (a bad artifact = incident/rollback) | 5–50-person monorepo (bad hit = "delete cache, rebuild, move on") |

aeb's `distributed-cache-plan.md` is explicit that dressing a
repeatability cache up *as if* it were reproducible is "a crime" — the
alice-builds-on-libstdc++-14 / bob-pulls-on-libstdc++-13 / UB-three-weeks-later
failure. So aeb's stance isn't "we couldn't be hermetic"; it's "we chose
repeatability **and we name where it doesn't guarantee**, because for the
target user that's the load-bearing product." That's a Nix-literate
position, not a naïve one.

## Where aeb has grown toward (a slice of) what Nix gives

The 2024-era "bare difference" bullets each have a designed answer now:

- **Toolchain pinning — "uses whatever's on PATH" → discover-select-or-
  fail [design].** [`toolchain-selection-and-locks.md`](toolchain-selection-and-locks.md)
  adds `jdk("21")` / `python("3.12")`-shaped requirements: aeb
  **discovers** installed runtimes (probing `/usr/lib/jvm/*`,
  `$PYENV_ROOT/versions/*`, framework dirs…), **selects** the matching
  one and runs the compiler from *that* home (not PATH's), and **fails
  loudly** naming what was found (`need jdk 21; found 17, 24`). The
  deliberate boundary: it **selects, never provisions** — installing the
  runtime stays the user's/CI's job (sdkman, apt, setup-java). That's the
  conscious half-step toward Nix: pin *which* toolchain, without owning
  the closure that materializes it. **[have]** selection design /
  **[won't]** provisioning.
- **Lockfiles — "no lock" → self-validating lock [design].** The same
  doc specs a generated `.ae` lock node that embeds the hash of the BOM
  it came from and **hard-fails on visit** if that BOM changed — so a
  consumer can depend on the lock alone and a drifted BOM can't pass
  silently. It's a lock with a built-in tripwire, where Nix's `flake.lock`
  is an external pinned-input file. Different mechanism, same goal:
  reproducible *input selection*. **[design]**
  (ask: [`asks/versioned-bom-and-self-validating-lock.md`](../asks/versioned-bom-and-self-validating-lock.md)).
- **Content-addressed caching — "per-target artifacts" is now real and
  growing [have].** `lib/cache/` is a sha256+zlib content-addressed
  store, wired into several SDKs (maven classpath, aether link, javac
  classes-tree), with a remote/distributed phase designed in
  `distributed-cache-plan.md`. It's content-addressing at the **target**
  grain, not Nix's whole-derivation grain — by choice (the repeatability
  contract above).

So the honest 2026 read: aeb has grown a **selection-and-validation**
story (pick the right toolchain, lock the input set, content-address the
artifacts) — the parts of Nix's value that don't require owning the
store — while deliberately **not** growing the **materialization** story
(provision the toolchain, sandbox the build, guarantee bit-identity).

## Where they still genuinely differ (and aeb won't follow)

- **The store.** Nix materializes every input from `/nix/store` with
  content-addressed paths; aeb runs inside an already-cloned repo and
  uses installed toolchains. aeb **[won't]** rebuild around a store —
  that *is* the architecture choice, restated below.
- **Hermetic sandbox per build.** Nix isolates each derivation from the
  ambient system. aeb's isolation story is the **veto + container
  containment** layers (see [`veto-alternates.md`](veto-alternates.md) /
  [`containment-and-the-control-plane.md`](containment-and-the-control-plane.md))
  — policy + optional container, not a mandatory per-build sandbox.
  Different product: aeb contains for *trust/safety on a shared agent*,
  not for *bit-reproducibility*.
- **Bit-identical output.** Nix guarantees it; aeb explicitly does not
  promise it (repeatability ≠ reproducibility). A team that *needs*
  byte-identity should use Nix; aeb is the wrong tool and says so.
- **Whole-system / deployment closures.** Nix packages an entire runtime
  environment for deployment. aeb is a build graph, not a system
  packager — it exports artifacts and metadata; deployment is downstream.

## The integration shape (unchanged, still right)

The original recommendation holds and is *strengthened* by the growth
above: don't rebuild aeb around the Nix store — add an exporter. With
toolchain-selection + the self-validating lock, the `.ae` graph now
carries *more* of what a derivation needs (pinned toolchain identity,
locked BOM hashes), so the export is richer than it was:

```text
aeb graph  ─►  aeb-to-nix  ─►  derivations / flake outputs
   ▲                              (toolchain reqs + lock hashes
   └─ .build.ae targets,            now available to embed)
      toolchain_select(),
      self-validating locks
```

That keeps aeb's native model intact while letting Nix users consume the
graph in their ecosystem — and the half-step features (pin which
toolchain, lock the BOM) make the emitted derivations more faithful than
a PATH-only graph could have produced.

## Rule of thumb (updated)

The old rule — *"don't rebuild aeb around the Nix store; add an
exporter"* — still stands. The update is *why*:

> aeb has grown the **selection and validation** slice of Nix's value
> (pick the right toolchain, lock the input set, content-address the
> artifacts) and **deliberately declined the materialization slice**
> (own the store, provision toolchains, guarantee bit-identity). It
> trades reproducibility for **repeatability under stated policy** on
> purpose, for the 5–50-person polyglot monorepo where average-case
> throughput beats worst-case bit-identity. If you need the closure,
> use Nix — and consume aeb's graph through an exporter. If you need a
> fast, explicit, language-aware repo build graph that *names* what its
> cache does and doesn't guarantee, that's aeb's lane, now by design
> rather than by limitation.
