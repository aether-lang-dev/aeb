# ABI Maker — a binary-reading ABI recovery tool

*A Python tool that recovers linkable ABI facts — symbols, struct layouts,
selectors, calling conventions — from public binaries and the live runtime, and
generates headers locally without ever redistributing a vendor's SDK.*

- **Targets:** Windows · iOS · macOS (non-libc)
- **Language:** Python
- **Lineage:** class-dump · Wine · ReactOS · *Google v. Oracle* (2021)
- **Status:** proposal / not started

> A rendered version of this proposal exists as `python_binary_reading_ABI_maker.html`
> (published artifact: https://claude.ai/code/artifact/4d8cb374-ab63-4a02-a071-b75cbe00731d).
> This `.md` is the plain-text source of record.

---

## The one idea, before the detail

An **Application Binary Interface is a set of functional facts** — the names of
exported symbols, the byte offset of a field, the selector a method answers to,
how arguments are passed. Facts have no author. A header file is one
*expression* of those facts, and expression can be copyrighted — but the facts
underneath it cannot.

Every technique in this document turns on that single distinction. We recover
the **facts** — from binaries that already exist for their own legitimate
reasons, and from a runtime that must expose its own ABI in order to function —
and we **generate the expression locally**, on the user's own machine, from
those facts. The vendor's header is never in our possession and never
redistributed by us.

> **The load-bearing rule.** The tool ingests **only** facts an interface
> exposes for interoperability, from inputs that were never protected by a
> technical measure. It never copies a vendor's header *expression*, and it
> never circumvents encryption to read an input. Everything downstream inherits
> its legitimacy from this wall.

---

## 1. Why this is a real seam, not a stunt

Three things that already exist, shipped openly for years against litigious
platform vendors, mark out the ground this stands on:

- **class-dump** has recovered Objective-C class, method, and ivar declarations
  out of Mach-O binaries for roughly two decades — reading the runtime metadata
  Apple's own compiler emits into every binary. Distributed in the open. Never
  killed.
- **Wine** reimplements the entire Win32 ABI — thousands of exported functions,
  struct layouts, calling conventions — clean-room, from observed behavior and
  public documentation, never Microsoft's source. Thirty years old.
- **ReactOS** runs the same playbook at the kernel-ABI level with a *strict,
  auditable* clean-room wall: a contributor tainted by leaked Windows source is
  barred from the project.

The legal spine is *Google v. Oracle* (2021): reimplementing the functional
facts of an interface, for interoperability, is protected — the copied thing
there was minimal and functional, and that is precisely why it survived. **What
we propose is not a novel act of circumvention. It is class-dump's technique,
generalized across vendors and automated with machine learning.** The novelty is
the tooling, not the legality.

---

## 2. Three tiers — and only the top one is a moonshot

The single most important thing to keep straight: these tiers have wildly
different risk and difficulty. Do not let the exciting one contaminate the safe
one.

| Tier | What it is | Difficulty | Legal | ML content | Verdict |
|---|---|---|---|---|---|
| **A — safe** | **Shape recovery.** Parse binaries and the runtime for the facts a *linker* needs: exported symbols, struct sizes/offsets, method selectors, calling conventions. Emit `.tbd`-shaped stubs and declaration headers. What a cross-*link* actually consumes. | mechanical | well-trodden | near zero | build fearlessly |
| **B — caution** | **Cross-corpus consensus.** Reconcile disagreement across many binaries and OS versions ("500 apps imply this struct grew 8 bytes at OS N+1"). Cluster, disambiguate, attach confidence + a version condition to every fact. | statistical | same as A | light | where automation earns its keep |
| **C — moonshot** | **Behavior recovery.** Synthesize a *behavioral* model faithful enough to reimplement a framework — the step that puts iOS/Win32 frameworks on Linux. Wine's function-body problem. | open research | hot — needs the wall | the whole thing | don't build until forced |

> **The uncomfortable coincidence.** Machine learning helps *most* exactly where
> the legal risk is *highest* — Tier C. Recovering **shape** (safe, mechanical)
> and recovering **behavior** (hard, hot) are different universes. A cross-link
> needs only Tiers A–B. The framework-on-Linux dream needs C — and that is a
> project with a compliance apparatus, not a weekend of binary parsing.

---

## 3. What each target actually needs

The three targets are not equivalent. The first is nearly free; the last two are
where the interesting facts — and the risk — live.

| Layer | Windows | iOS | macOS (non-libc) |
|---|---|---|---|
| C libc / system C | ✅ mingw / clean | ✅ Zig `any-darwin-any` | ✅ Zig `any-darwin-any` |
| Linker stub (`.tbd` / import lib) | ⚠️ recover from DLLs | ⚠️ recover — no iOS `.tbd` | ✅ Zig ships `libSystem.tbd` |
| Framework declarations | ❌ Win32 / COM surface | ❌ UIKit, CoreTelephony… | ❌ AppKit, Foundation… |
| Framework behavior | ❌ Tier C | ❌ Tier C | ❌ Tier C |

### Windows

The most mature comparable already exists — Wine's `.spec` files and the whole
win32 reimplementation. The ABI is recoverable from public DLLs (export tables,
PE structure) and decades of documentation. COM adds vtable-layout recovery. Our
contribution is *automating* the shape-recovery half that Wine authored by hand,
and feeding it the same corpus-consensus treatment.

### iOS

iOS is Darwin. Its C libc is **already clean-room-available** through Zig's
`any-darwin-any` header set (verified: pointed at `-target aarch64-ios`, the full
openssl-style translation unit compiles to a Mach-O arm64 object). What Zig does
*not* ship is an iOS-target `.tbd` or the frameworks. The frameworks — the actual
iPhone surface, from the dialer to UIKit — are the Tier-C prize, and the only
reason a vendor fights this at all.

### macOS, above libc

The libc tier is a solved, shipping thing (Zig's `any-darwin-any` +
`libSystem.tbd`). Everything *above* it — AppKit, Foundation, the Objective-C
framework graph — is the same recovery problem as iOS, minus the
deployment-target and simulator wrinkles. Solve one and the other is mostly a
re-target.

---

## 4. The pipeline

Python is the workshop, not the product. It orchestrates deterministic binary
parsers and the ML corpus work; the *generated* stubs and headers are whatever
the target consumes. Every stage is a fact-transform with provenance attached.

```
IN  Ingest     Public binaries the user points at + live-runtime probes.
               Never a DRM-wrapped input.
01  Parse      Deterministic: lief, capstone, Mach-O / PE / Obj-C metadata.
               Facts only.
02  Reconcile  Cross-corpus consensus, version-conditioned. Confidence per fact.
03  Generate   Emit stubs + headers into a local FS. On the user's disk,
               from measured facts.
```

| Stage | Nature | ML content |
|---|---|---|
| Symbol / selector / offset extraction | Deterministic binary parsing | **none** — class-dump / otool territory |
| Cross-corpus consensus | Statistics / clustering | **light** — version-conditioned inference |
| Behavioral inference | Program synthesis from I/O | **the whole thing** — unsolved |

Reach for Python's binary-analysis stack: `lief` and `macholib` for containers,
`capstone` for disassembly, the Objective-C runtime accessors
(`class_getInstanceSize`, `class_copyMethodList`, `ivar_getOffset`) for the
live-measurement rung. It is the swiss-army knife precisely because every layer
of this — parsers, ML, codegen — already lives there.

---

## 5. The resilience ladder — surviving the vendor's counter-move

A platform vendor's realistic winning move is not a lawsuit against a clean-room
tool. It is **input attrition**: encrypt binaries at export time so future public
artifacts arrive already wrapped. This is a *flow* attack, not a *stock* attack —
everything already public stays readable forever; only new OS versions go dark
through that channel. And it carries heavy collateral cost for the vendor's own
ecosystem (crash symbolication, enterprise redistribution, re-signing CI all
depend on readable binaries).

So the architecture is a fallback ladder. Each rung survives the failure of the
one above it:

1. **Static reading of public un-encrypted binaries.** Best cost and coverage.
   Caps at whatever OS version the vendor starts encrypting exports — but the
   historical corpus is permanent.
2. **Runtime measurement** in a simulator or on device. Survives file-level
   encryption *entirely*, because it observes the live runtime, not the file. A
   vendor cannot encrypt the ABI away from a process that is allowed to dispatch
   against it — not without breaking Objective-C / COM introspection, and with it
   half its own frameworks.
3. **Cross-corpus consensus** over whatever inputs remain — stale static facts
   blended with fresh runtime facts, timestamped, so the generated ABI *degrades
   by version* rather than snapping off.

> **Why the bottom rung is load-bearing.** The vendor can push you *down* the
> ladder but cannot push you *off* it. The lowest rung — a process observing the
> runtime it is linked against — is load-bearing for the OS itself to function.
> Killing it means making the runtime non-introspectable, which breaks
> reflection, dynamic class lookup, KVO, and the frameworks built on them. That
> is not a move a platform can make.

---

## 6. Where the real risk concentrates

The copyright / purpose story is about as clean as this gets — facts, measured
across a corpus, in *Google v. Oracle* interop territory, with no vendor header
expression ever ingested. Two axes remain, and neither is a copyright question:

| Axis | The line | How it's held |
|---|---|---|
| **Anti-circumvention** (DMCA §1201) | Never decrypt a protected input to read it. | Ingest only never-encrypted binaries + live-runtime observation. Strict-liability edge — does not care how clean the copyright story is. |
| **Facts vs. expression** | Stay on the ABI-fact layer. | Names, offsets, layouts, selectors — never embedded copyrightable content (sample code, resources, creative strings) that a binary may also carry. |
| **Clean-room provenance** | Measurers separated from consumers. | ReactOS-style wall: nothing ingested may be a vendor SDK header or source. Auditable, per-artifact. |

> **Not legal advice.** This is engineering architecture, not legal counsel. A
> deliberate design around a major vendor's license perimeter should get a
> go / no-go from a lawyer who can inspect one real artifact and confirm two
> things: that no ingested input was ever DRM-wrapped, and that nothing recovered
> crosses from fact into expression. The design above is structured specifically
> so that most of the doubt never arises — but the §1201 line in particular is
> strict-liability-flavored and deserves a written blessing.

---

## 7. What to build first — and what not to

The decision-theory is unusually clean, because two very different futures
converge on the same near-term move.

There is a real chance — call it **~30%** over a multi-year horizon — that the
vendor simply **publishes the headers**. Apple already open-sources Swift,
Foundation-for-Linux, and libdispatch; the `.tbd` stub format is Apple's own
admission that the interface layer is fine to distribute separately. If that
lands, a chunk of Tier-C scope you had not yet written just evaporates.

But notice: **the 30% branch and the build-it branch need the same thing first.**

- If the vendor releases headers → you consume them. Trivial.
- If they don't → you build the ladder.
- In *both* branches, the layer you need first is the **Tier-A linker-ABI facts
  for the C/dependency tier** — which for macOS/iOS you *already have* clean-room
  through Zig's `any-darwin-any`, no recovery and no waiting required.

> **The no-regret move.** Build the C-dependency cross-link path that works
> *today*, on every branch: the sysroot tooling plus a current Zig pin. The
> header-recovery ladder is the hedge you build the day the free-header bet
> resolves against you **and** you actually need the framework tier — which the
> dependency job never does. Betting engineering effort on the 30% now is
> building on a coin-flip; the Zig-clean C tier is already proven.

So: **ABI Maker is real, buildable, and legally sane at Tiers A–B**, sitting on
thirty years of Wine/class-dump precedent. Tier C — frameworks running
off-device, the domino the vendor actually fights — is the moonshot: unsolved
ML, hot legal ground, and a clean-room institution that must exist *before* the
first line is written. Draw that line before anyone starts, and the safe half
ships without ever waiting on the hard half.
