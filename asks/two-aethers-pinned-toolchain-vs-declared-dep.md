# Two Aethers: the one aeb is built against, and the one a target asks for

**Filed by**: Paul + LLM session, 2026-07-26, after `aeb-driver` failed to
compile on winbaz with `E0301: Undefined function 'os.spawn_proc'`.
**Status**: **PROPOSED — design agreed, not implemented.**
**Shape**: Paul's framing. aeb's own compilation of `.foo.ae` should use an
Aether **coupled to the aeb release** — which aeb may quietly fetch and
build **for its own private use**, never touching the user's `ae`. A target
that itself builds *Aether code* declares its own Aether like any other
dependency, and that one compiles the target's sources.

## The conflation

There is exactly one knob today, and it does two unrelated jobs:

```bash
AETHER="${AETHER:-ae}"                 # aeb (trampoline), line 16
```

```aether
ae_bin = os.getenv("AETHER")           # lib/aether/module.ae:1101
```

The first compiles **aeb's own machinery** — `transform-ae` on each
`.foo.ae`, the generated orchestrator, `aeb-link`, `aeb-driver`. The second
compiles **the user's program**, inside `aether.program(b)`.

Those are not the same requirement, and pretending they are produces the
failure this ask is named after.

## Why it bites

Concrete, from this session:

- winbaz's Aether was **0.413.0**. aeb's driver had grown a call to
  `os.spawn_proc` (**0.442**), so `aeb-driver.ae` would not compile:
  `E0301: Undefined function 'os.spawn_proc'`. The build died in aeb's own
  plumbing, for a reason that had nothing to do with the user's targets.
- The failure surfaces as a **compile error inside a generated file**, not
  as "this aeb needs ae ≥ 0.442, you have 0.413". The information existed
  at startup; nothing used it.
- LLM.md carries version floors as **prose** — "needs aether >= 0.230.0",
  "aether 0.357", "ae >= 0.442". Not machine-readable, so nothing checks
  them and they drift.

And the inverse is just as real, though it has not bitten yet: a monorepo
with an `aether.program(b)` target pinned to an **older** Aether for
compatibility reasons cannot express that today, because raising `$AETHER`
to satisfy aeb necessarily raises it for the target too.

## The proposal

**Role 1 — aeb's toolchain: PINNED, not the user's choice.**

The Aether that compiles `.foo.ae` into an orchestrator is an
implementation detail of the aeb release, exactly like the version of gcc
that built your `make` binary. A given aeb is *built against* a given
Aether; running it against an older one is not a supported configuration,
it is an accident that currently manifests as `E0301`.

**And aeb should just GO GET IT.** This is the part that makes the split
worth having rather than merely tidy: if the pinned Aether is an
implementation detail of the aeb release, then aeb should quietly fetch
and build that exact version **for its own private use**, the same way it
would vendor any other internal dependency. Not into the system prefix.
Not into `~/.local/bin`. Not on `PATH`. Just a private toolchain aeb uses
to compile `.foo.ae` files, invisible unless you go looking.

```
~/.cache/aeb/toolchain/aether-0.449.0/bin/ae      # aeb's own, private
/usr/local/bin/ae                                  # the user's, untouched
```

(Under the cache root `lib/cache` already resolves — `$AEB_CACHE_DIR` →
`$XDG_CACHE_HOME/aeb` → `~/.cache/aeb`. Version-suffixed, so two aeb
releases on one box do not fight, and `rm -rf` on the cache is always safe
— worst case is one re-fetch, which is what a cache dir is for.)

The user's `ae` — whatever version, wherever it came from, however they
manage it — is **left completely alone**. It remains what
`aether.program(b)` uses (Role 2), and what the user gets when they type
`ae` themselves. aeb never upgrades it, never shadows it, never has an
opinion about it.

First run on a machine prints one line and takes a few seconds:

```
aeb: fetching aether 0.449.0 for aeb's own use (one-time, ~/.cache/aeb/toolchain)
aeb: aether 0.449.0 ready (prebuilt linux-x86_64).
```

Every subsequent run is silent.

**As shipped (2026-08-01), two mechanisms in order.** The prebuilt release
asset first — measured under 1 s, and no C compiler needed on the node:

```
https://github.com/aether-lang-dev/aether/releases/download/v<ver>/aether-<ver>-<os>-<arch>.tar.gz
```

Falling back to upstream's `get.sh`, which takes exactly the two knobs
needed:

```bash
AETHER_REF=v0.449.0 PREFIX=~/.cache/aeb/toolchain/aether-0.449.0 sh get.sh
```

so this is wiring, not invention. `ae version install` proves the fetch
path works too.

The fallback is load-bearing, not decorative: `get.sh` is a **source**
installer (source tarball + `make install`, ~69 s), and it is the only
thing that works where no asset exists — there is no `linux-arm64` asset,
so a Pi or Graviton node takes this path today. Note the original version
of this ask assumed `get.sh` *was* the mechanism, and the trampoline was
built that way; every node therefore paid the source-build cost until the
prebuilt attempt was added in front of it.

**What this buys, concretely.** The winbaz failure disappears entirely.
Instead of `E0301: Undefined function 'os.spawn_proc'` from a generated
file — followed by a human bisecting Aether versions, discovering pcre2 is
a new dependency, and losing an hour to `MSYSTEM=MSYS` — aeb would have
fetched 0.449.0 itself and just worked. The user's 0.413.0 would have
stayed exactly where it was, still building their targets.

Failing that (no network, air-gapped CI, a policy against auto-download),
fall back to asserting the floor and saying so plainly:

```
aeb: this build needs aether >= 0.442 (found 0.413.0 at /c/.../ae.exe)
     aeb uses os.spawn_proc/wait_any for the native scheduler.
     fetch it with: aeb --fetch-toolchain     (or set AEB_AETHER=<path>)
```

One line, at startup, instead of a wall of undefined-function errors from
a generated file the user never wrote.

**Role 2 — the target's toolchain: DECLARED, like any other prereq.**

A `.build.ae` that builds Aether code already has the vocabulary:

```aether
aeb(cap) {
    b = build.start()
    prereq(b, "aether:0.410")          // <- compiles THIS target's sources
    aether.program(b) { source("main.ae") output("hello") }
}
```

`aether` becomes a canonical token alongside `jdk`, `node`, `rust`, `go`
(`lib/provision`'s `_misname_canonical` already curates that set — `ae`
should map to `aether`). Then the existing machinery covers it for free:

- `aeb --prereqs <target>` states it;
- `aeb --preflight <target>` probes it and fails closed with
  `unmet-prereqs:` (exit 3);
- `aeb-agent`'s `/ping` already reports its Aether version, so a requester
  can compare *needed* against *reported* **before** dispatching — today
  that version is advisory and nothing consumes it;
- `agent.prereq_to_image` already maps a token to a toolchain image, so
  per-node container routing gets the right Aether without new machinery.

**Two Aethers coexist.** That is the point, and it is not exotic: it is the
same shape as aeb building a Java 8 target while itself running on a
Java 21 JVM. `lib/aether`'s `_shell_out_ae_build` resolves the *declared*
one; the trampoline resolves the *pinned* one; they are allowed to differ.

## Explicitly NOT asking for

- **A general installer for TARGET prereqs.**
  `docs/design/build-prerequisites-and-provisioning.md` is explicit that
  resolving a token to an install is unbounded (every toolchain × distro ×
  version × arch) and deliberately out of scope. Role 2 stays **state and
  observe**: if a target declares `jdk:21` or `aether:0.410` and it is
  absent, aeb says so and stops.

  Note this does NOT contradict aeb fetching its OWN Aether above. The
  distinction is ownership, and it is the whole point of the split:
  - **Role 1 is aeb's own dependency** — exactly one thing, exactly one
    version, known at release time, from one known source. Bounded, so
    aeb can own it end-to-end.
  - **Role 2 is the user's dependency** — arbitrary toolchains at
    arbitrary versions from arbitrary package managers. Unbounded, so aeb
    states the need and stops.

  "Never provisions" was always a statement about the *unbounded* case.
  A tool fetching its own pinned dependency is not the same act as a tool
  trying to install everybody else's.

- **Touching the user's `ae`.** The private toolchain lives under aeb's
  cache dir, never on `PATH`, never in a system or user prefix. `which ae`
  must give the same answer before and after aeb has run. No shadowing, no
  upgrading, no `~/.local/bin` writes.
- **Auto-selecting between installed Aethers for a TARGET.** If a target
  declares `aether:0.410` and it is not present, fail closed and say so.
  Choosing is the operator's job there.

## The objection, and the mitigation

**A declared floor drifts.** Set once and never updated, it is worse than
nothing: it asserts "0.442 is fine" while the code has quietly started
needing 0.449. This repo has met that rot before — the three-copy
`file_to_label` — and solved it by making drift structurally impossible
rather than by discipline.

Same fix available here: **derive, don't declare**. The primitives aeb
consumes are greppable (`os.spawn_proc`, `os.wait_any_timeout`,
`--emit=csrc`). A test can assert that every Aether symbol aeb calls exists
in the pinned floor, so the floor is *checkable* rather than aspirational.

**Self-fetching weakens this objection considerably**, which is the second
reason it is worth doing. A drifting floor is dangerous when it is only an
*assertion* — "0.442 is fine" while the code needs 0.449 means a confusing
failure on someone else's machine. When aeb *fetches* the pinned version,
the pin is what actually gets used, so a stale pin fails on the
maintainer's own machine at the first build after the drift — loudly,
locally, and immediately. The pin stops being a claim about the world and
becomes a fact about the build.

The residual risk is narrower: aeb's SOURCES calling a primitive newer than
the pin. That is exactly what the greppable check catches, and it is a
CI-side test rather than a runtime concern.

## Acceptance

- On a machine with no suitable Aether, aeb fetches its pinned version
  into its own cache, prints ONE line about it, and builds successfully —
  without `E0301` from a generated file, and without a human bisecting
  versions.
- `which ae` returns the same path, and `ae --version` the same version,
  before and after aeb has run. The user's toolchain is untouched.
- With fetching disabled or unavailable (offline, policy), aeb states the
  floor and the remedy in one line instead of failing in generated code.
- The fetched toolchain is reused silently on subsequent runs (no
  re-download, no per-build cost).
- `prereq(b, "aether:X")` flows through `--prereqs` / `--preflight` like
  any other token, and `ae` is rejected as a misname for `aether`.
- A target declaring an Aether **different** from aeb's own pin builds
  with the declared one, verified by a fixture with two Aethers installed.
- The floor is derived from, or checked against, the primitives aeb
  actually calls — not a hand-maintained constant.
- Linux green (`tests/run.sh`) and a winbaz run, since the motivating
  failure was Windows-only.

## Related

- `docs/design/build-prerequisites-and-provisioning.md` — the states-needs /
  observes-presence / never-installs posture this must not break.
- `docs/design/toolchain-selection-and-locks.md` — selection vs provisioning.
- `docs/guides/windows-cross-platform-notes.md` § 5 — the winbaz failure, plus
  the `MSYSTEM=MINGW64` trap found while fixing it.
- `LLM.md` § "Recent upstream Aether features aeb could lean on" — where
  the version floors currently live as prose.
