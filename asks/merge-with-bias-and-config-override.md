# Merge-with-bias: should aeb grow a config override/merge operation?

**Filed by**: Paul + LLM session, 2026-07-25, from the same
r/programming thread ("What makes a good build system?", 2026-07-24)
that produced `.presubmit.ae` and
`asks/halting-guarantees-and-build-termination.md`.
**Status**: **NO ACTION** — no feature proposed, no feature declined.
Recorded as a **boundary marker**: if someone later asks for value
override in a `.build.ae`, this is the argument that should shape the
answer, so it isn't rediscovered from scratch.

## The idea, as argued upstream

u/lookmeat's case, compressed. A config language collapses to a plain
old data structure (scalars, lists, maps). Two primitives make templating
work:

1. **An `expected` / `required` bottom type** — a value a template
   declares but does not define. Unlike `null` it is not a legal final
   state: you *have* to fill it in, so "template with holes" is checkable
   rather than merely conventional.
2. **Merge-with-bias** — combine two structures into one (lists extend,
   maps merge key-wise, and where two scalars collide, a consistent rule
   picks a winner). The exact bias rule matters less than that it is
   consistent; there is no best answer, only a defensible one.

The subtle part is *when* the merge happens relative to evaluating derived
values (`fizz = foo + bar`):

- **Merge before evaluation ("lazy")** — override the inputs, and
  everything computed from them recomputes. Powerful: one `mem =
  required` can feed both a JDK flag and a container memory hint, and
  overriding it fixes both.
- **Merge after evaluation ("eager")** — override the output, leaving the
  computation untouched.

His own verdict on the lazy form is the interesting part:

> there's an insanity in the above: it's dynamic binding. […] I can load
> some side dependency […] that then breaks code in another unrelated
> dependency, only because they both got loaded in the same space. Trust
> me you do not want to have to debug these issues, it's a PITA.

And crucially, that build systems **do not need it**:

> Now the reason why you need dynamic merge in a IaC language, but build
> system can get away with straightfoward merge is when you have
> dependency loops. […] In a build system though all those circular
> relationships exist *after* the build system.

IaC has to model a live system whose entities reference each other
circularly (a VM needs its security group; the security group needs the
VMs' IPs). A build describes a process that starts and ends, and its
graph is a DAG by construction — so a shared value can always be hoisted
into its own node upstream of both consumers, and the lazy merge's reason
to exist evaporates.

## Why this is a boundary marker and not a feature request

**aeb already has merge-with-bias. It just isn't spelled `merge`.**

Setters accumulate into the builder map with a fixed, consistent rule:

- **scalars: last write wins** — the setter does `map.put`, which
  overwrites, and the builder reads one key back with `map.get`;
- **lists: append** — repeated `script(...)` / `pre_command(...)` /
  `extra_source(...)` calls extend a list (`list.add`).

Both halves verified observably rather than by reading the source. Four
`sleep 1` scripts in one `bash.test`, varying only the order of two
`jobs(...)` calls:

| Declaration order | Wall time | Effective value |
|---|---|---|
| `jobs(4)` then `jobs(1)` | **5s** | `1` — sequential |
| `jobs(1)` then `jobs(4)` | **2s** | `4` — parallel |

The last call wins. And in both runs all four scripts ran, so repeated
`script(...)` appended rather than overwriting.

That is exactly lookmeat's bias rule ("lists get extended, dictionaries
merge when they share the key"), applied *per setter call* instead of
per structure. And because a `.build.ae` is an ordinary Aether program,
composition is ordinary code: call a helper that sets defaults, then set
your overrides after it. The later call wins on scalars and extends on
lists — a merge-with-bias, expressed as sequential statements.

So the honest answer to "should aeb add merge?" is: **the useful 90% is
already there**, and it costs no new grammar because it rides on
evaluation order, which readers already understand.

**And it is the eager form** — the one lookmeat endorses. Setters run
top-to-bottom, each `map.put` lands on the map, and nothing recomputes
behind you. There is no dynamic binding to debug, because there is no
late-bound name resolution anywhere in the model.

## What aeb does *not* have, and shouldn't rush to add

Two pieces of the sketch are genuinely absent:

**The `required` bottom type.** Today a template-shaped helper that
forgets to set a mandatory value fails late — at `os.system` time with a
toolchain error, or silently with a wrong default. A first-class "declared
but undefined, and it is an error to finish this way" marker would catch
that at build-script evaluation instead. This is the more defensible half
of the ask; `build.fail(ctx, reason)` already exists as the reporting
mechanism, so a helper could assert-and-fail without new machinery. Worth
considering **if a concrete case appears** — not on spec.

**Whole-structure merge as an operation** (`merge(a, b) -> c` over
builder maps). This is the part to be sceptical of. It would mean
handing users a second way to configure a target — one whose result is
not readable by scanning the file top-to-bottom, because the effective
value would depend on a merge performed elsewhere. That directly attacks
what the DSL is for.

## The tension with design principle #2, stated honestly

LLM.md's principle #2 says: closure-DSL grammar over external config;
aeb stays out of config-format machinery. Merge-with-bias *is*
config-language machinery, so a naive reading rejects it on sight.

That reading is too quick, and worth correcting for the record: the
principle targets **parsing external formats** (TOML/YAML/JSON manifests)
rather than expressiveness inside the closure DSL. A merge operation
would be native Aether, not a parser, so principle #2 does not
automatically kill it.

The stronger objection is the **load-bearing principle** instead:

> The dot-prefixed `.ae` file is the single source of truth for what aeb
> does for its target. […] what keeps the build-graph extraction
> text-only and the configuration typeable / IDE-friendly /
> introspectable from `grep`.

A merge whose operands live in another file makes the effective
configuration of a target no longer readable *from that target's file*.
That is the same property `build.dep()`'s greppability protects on the
graph side. Sequential setters keep it; a merge operation is where it
starts to erode.

So: not "principle #2 forbids it", but "the file-as-truth principle sets
the bar, and a merge operation has to clear it."

## The boundary marker

When someone asks for value override in a `.build.ae`:

1. **First ask whether sequential setters already do it.** They usually
   do — scalars last-write-wins, lists append. A helper function called
   before the overrides is the composition mechanism, and it needs no
   feature.
2. **If a real gap remains, ship the eager (after-evaluation) form.** The
   override lands on the value; nothing recomputes.
3. **Refuse the lazy (before-evaluation / dynamic-binding) form.** Its
   justification is circular references between live entities, which a
   build DAG does not have — a shared value can always be hoisted to an
   upstream node. What it buys is not worth what it costs: an override in
   one place silently changing a derived value somewhere unrelated, which
   is the failure mode lookmeat warns is a PITA to debug and which no
   amount of convention reliably contains.
4. **`required`/`expected` is the piece most likely to be worth it** —
   fail at script-evaluation time rather than at toolchain time — but
   wait for a concrete case.

## Decision

No action. aeb's setter semantics already implement the eager
merge-with-bias this argument concludes a build system needs; the lazy
form is pre-emptively refused with the reasoning above; `required` is
noted as the one piece that might earn its place later, on evidence.

## Related

- `asks/halting-guarantees-and-build-termination.md` — the other
  declined idea from the same thread, same shape of argument (the
  proposal targets a layer where aeb's problem isn't).
- `docs/presubmit-target-sets.md` — the one idea from the thread that was
  adopted.
- LLM.md § "Design principles when extending aeb" (#2) and § "The
  load-bearing principle" — the two rules this ask is measured against.
