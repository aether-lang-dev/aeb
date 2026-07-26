# Two Aethers: the one aeb is built against, and the one a target asks for

**Filed by**: Paul + LLM session, 2026-07-26, after `aeb-driver` failed to
compile on winbaz with `E0301: Undefined function 'os.spawn_proc'`.
**Status**: **PROPOSED — design agreed, not implemented.**
**Shape**: Paul's framing. aeb's own compilation of `.foo.ae` should use an
Aether **coupled to the aeb release**. A target that itself builds *Aether
code* declares its own Aether like any other dependency, and that one
compiles the target's sources.

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

aeb should know its own floor and say so:

```
aeb: this build needs aether >= 0.442 (found 0.413.0 at /c/.../ae.exe)
     aeb uses os.spawn_proc/wait_any for the native scheduler.
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

- **An installer.** `docs/build-prerequisites-and-provisioning.md` is
  explicit that resolving a token to an install is unbounded (every
  toolchain × distro × version × arch) and deliberately out of scope. This
  stays **state and observe**. The winbaz rebuild would still be a human
  running `make` — just with aeb having said *why* first, instead of after
  ten minutes of link errors.
- **Vendoring Aether into aeb.** The pin is a *version assertion*, not a
  bundled compiler.
- **Auto-selecting between installed Aethers.** If a target declares
  `aether:0.410` and it is not present, fail closed and say so. Choosing
  is the operator's job; aeb's job is to be precise about the need.

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
Without that, this ask makes the failure message nicer and the accuracy
worse over time — which is not obviously a win.

## Acceptance

- Running aeb against an Aether below its floor produces ONE clear line
  naming both versions, not `E0301` from a generated file.
- `prereq(b, "aether:X")` flows through `--prereqs` / `--preflight` like
  any other token, and `ae` is rejected as a misname for `aether`.
- A target declaring an Aether **different** from aeb's own pin builds
  with the declared one, verified by a fixture with two Aethers installed.
- The floor is derived from, or checked against, the primitives aeb
  actually calls — not a hand-maintained constant.
- Linux green (`tests/run.sh`) and a winbaz run, since the motivating
  failure was Windows-only.

## Related

- `docs/build-prerequisites-and-provisioning.md` — the states-needs /
  observes-presence / never-installs posture this must not break.
- `docs/toolchain-selection-and-locks.md` — selection vs provisioning.
- `docs/windows-cross-platform-notes.md` § 5 — the winbaz failure, plus
  the `MSYSTEM=MINGW64` trap found while fixing it.
- `LLM.md` § "Recent upstream Aether features aeb could lean on" — where
  the version floors currently live as prose.
