# `.presubmit.ae` — named target sets

Status: **BEST PRACTICE (2026-07-25).** No engine change was required or
made. This document names a convention that the existing rules already
permit; it is a naming agreement, not a feature.

## The gap this fills

From a comment thread on "What makes a good build system?"
([r/programming](https://www.reddit.com/r/programming/comments/1v5ip78/what_makes_a_good_build_system/), 2026-07-24), u/lookmeat naming the constituencies a build
config has to serve:

> there's the people who want to manage the resources and nitty gritty
> details, there's the people who just want to document how to do
> something (e.g. run a specific test) and there's people who are looking
> at the system level (e.g. define all test targets that must be run
> pre-submit)

aeb served the first two well and had **nothing** for the third:

- the person managing the nitty-gritty — served by the per-module
  `.build.ae`, and served well;
- the person who just wants to run one thing — served by
  `aeb path/to/.tests.ae`, about as directly as possible;
- **the person looking at the system level** — "these are the pre-submit
  targets", "this is the merge-queue set" — served by nothing.

That third role had no vocabulary. The nearest thing was
`aeb --scan '<glob>'`, which selects by filename pattern — an accident of
naming, not a declared intent. A glob cannot express "these seven
targets, chosen deliberately, and not the eighth."

The gap was invisible until those three roles were named side by side,
which is the whole value of the framing: the first two are what a build
system's authors use daily, so their needs get met by attrition. The
third is the one nobody is holding, because it is the only one that
belongs to no single module.

What follows costs nothing to adopt — the rules that make it work were
already in force (see [Why this needs no machinery](#why-this-needs-no-machinery)).

## The rule, in one line

A dot-prefixed `.ae` file whose body is nothing but `build.dep(...)` lines
is a **named set of targets**. Building it builds the set.

```aether
// .presubmit.ae — what must be green before you push
import build (start, dep)

aeb(cap) {
    b = build.start()
    build.dep(b, "libs/core/.tests.ae")
    build.dep(b, "apps/api/.tests.ae")
    build.dep(b, "apps/web/.tests.ae")
}
```

```bash
aeb .presubmit.ae
```

That is the whole convention. There is no `--presubmit` flag, no registry,
no special-casing anywhere in the runner.

## Say what the set is for — `meta.desc`

A bare list of dep edges says *what* is in the set but not *why* it
exists. `lib/meta` is already the distribution-metadata SDK and is
explicitly orthogonal to building, so it works unchanged on a dep-only
node:

```aether
import build (start, dep)
import meta (desc)

aeb(cap) {
    b = build.start()
    meta.desc(b, "Must be green before push")

    build.dep(b, "libs/core/.tests.ae")
    build.dep(b, "apps/api/.tests.ae")
}
```

This is the highest-value line in the file for the person reading it six
months later, and it costs nothing — no new SDK, no new setter. A set is
a reviewable artifact; `desc` is what makes it self-describing. Use it.

The same reasoning extends to the edges themselves: a comment on a
`build.dep(...)` line explaining *why* that target is in the set is worth
more than the line itself, because the line is already self-evident.

## Why this needs no machinery

Three rules already in force compose to give it for free:

1. **Any dot-prefixed `.ae` file under cwd is a node in the DAG.** There
   are no special target source-file names (see the top of `LLM.md`).
   `.presubmit.ae` is a node because it is a dot-prefixed `.ae` file, for
   exactly the same reason `.build.ae` is.
2. **`build.dep()` is the only edge-declaration mechanism, and it is a
   runtime no-op.** Deps are extracted textually before any `.ae` runs, so
   a file whose entire content is dep edges is a perfectly well-formed
   node — it contributes edges and no work.
3. **The filename IS the route** (`docs/filename-is-the-route.md`). The
   whole `.<name>.ae` segment is the type, verbatim. `.presubmit.ae`
   self-classifies as type `presubmit` and routes to `target/presubmit/`
   with no entry in any classification table.

A node with no builder does no work of its own. Its entire contribution to
the build is its edges — which is precisely what a target set is.

## Verified behaviour

Against a three-node fixture (`.presubmit.ae` → `alpha/.build.ae` +
`beta/.tests.ae`):

- **Members run.** Both dep bodies execute; their stdout lands in
  `target/.aeb/logs/<node>.log` as with any other node.
- **Topo-sort puts the aggregator last.** `_sorted.txt` is
  `alpha/.build.ae`, `beta/.tests.ae`, `.presubmit.ae`. Members with no
  edge between them are independent and run concurrently under `make -jN`,
  same as any other sibling nodes.
- **It self-classifies.** The summary reads
  `aeb: 1 build + 1 tests + 1 presubmit`, and the `[telemetry]` block gets
  a `presubmit: .` row. No display code was taught the word "presubmit".
- **Failure propagates.** With one member failing, `aeb .presubmit.ae`
  exits **1**; the failing member's `.rc` marker is `1`, the passing
  sibling's is `0`, and both the member and the aggregator are reported
  FAILED with log paths. A red member cannot yield a green set.

### One caveat worth stating plainly

Failure propagation is the property the whole convention rests on, and it
depends on members reporting failure honestly. SDK builders
(`bash.test`, etc.) do this correctly. A hand-rolled node that calls
`os.system` and discards the result —

```aether
_ = os.system("some-command-that-fails")   // exit code thrown away
```

— reports success no matter what the command did. That is the documented
behaviour of the raw-`os.system` escape hatch (`os.system` returns the
POSIX exit code directly; `_ =` discards it), not a defect in target sets.
But inside a presubmit set it is a booby trap: it produces a green
presubmit that proves nothing. **Prefer an SDK builder for anything a
target set depends on.** If you must shell out raw, propagate the code.

## Inline guards — possible, and mostly not what you want

A set is normally *only* dep edges. But a `.presubmit.ae` is an Aether
program like any other build file, so where a gate genuinely belongs to
the set rather than to any one member, you can write it inline
(`docs/inline-build-steps.md`) and fail with `build.fail`.

The example below is the one people ask for first — "fail if the working
tree is dirty" — and it is the **wrong thing to reach for**. It is shown
here because it is what gets asked for, and because working through why
it fails is more useful than a bare prohibition. A guard shape that *is*
safe follows it.

```aether
import build (start, dep)
import meta (desc)
import std.os
import std.string

aeb(cap) {
    b = build.start()
    meta.desc(b, "Must be green before push")

    build.dep(b, "libs/core/.tests.ae")

    // Guard: refuse to certify a tree with uncommitted or untracked
    // changes — otherwise "presubmit passed" describes a tree that
    // is not the one being pushed.
    dirty, err = os.exec("git status --porcelain")
    if string.length(dirty) > 0 {
        build.fail(b, "working tree not clean:\n${dirty}")
    }
}
```

Verified: a clean tree exits 0; a single stray file exits 1 with
`presubmit:. FAILED — working tree not clean:` and the offending paths
rendered. No new grammar was needed — `os.exec` and `build.fail` are both
existing public API.

### Why this particular guard is a bad default

**It is wrong on first contact, and it fails toward red.** The very first
run of the example above failed on `?? target/` — aeb's own output
directory made the tree dirty. That is not a footnote about tidiness. The
check was incorrect against the first repo it ever ran in, and its
failure mode was to report red on a tree that was, for every purpose the
set cares about, clean. Adding `.gitignore` entries fixes *that* repo and
says nothing about the next one. A check whose correctness depends on
every consumer having already ignored exactly the right paths is not a
guard with a caveat; it is a check that is wrong by default and right
only by ongoing maintenance.

**It is red most often when it is least informative.** Dep edges make a
set behave identically in CI, on a colleague's laptop, and in a
container. A working-tree check does not: it passes in clean CI and fails
for anyone holding a scratch file. So the developer mid-debug with a
stray log gets a red presubmit that has nothing to do with their change.
The rational response to that is to stop reading presubmit failures —
which destroys the value of every *other* member in the set. A gate that
trains people to ignore gates has negative worth, not merely limited
worth.

**And it is git-only.** Root discovery already honours `.avn`, `.hg`,
`.svn`, `.bzr`, Fossil and Pijul. Hardcoding `git status` in a shared set
silently narrows it to one VCS.

Those three together are not caveats on a recommendation. They are the
reason the recommendation is: **don't put a working-tree check in a
presubmit set.** If you want one, it belongs in a pre-push hook, where a
dirty tree is the actual subject and the developer expects the coupling.

### The guard shape that is safe

The objection above is specific, not general. A guard is fine when what
it asserts is **stable and repo-independent** — a property of the
environment the whole set needs, which is either true or false for
reasons unrelated to what the developer happens to have lying around:

```aether
    // Fine: the whole set needs this tool, and its absence is a real,
    // reproducible failure — same answer in CI, on a laptop, in a
    // container. No .gitignore maintenance can change it.
    if os.system("command -v protoc >/dev/null 2>&1") != 0 {
        build.fail(b, "presubmit needs protoc on PATH")
    }
```

Note the probe uses `os.system` (which returns the POSIX exit code
directly), **not** `os.exec`. `os.exec`'s second return is an execution
error, not a non-zero exit status — a command that runs fine and exits 1
yields an empty error string, so `if string.length(err) > 0` silently
never fires. Verified: the `os.system` form above fails the set when the
tool is absent and passes when present; the `os.exec` form passed in both
cases.

The distinction: does the guard's answer depend on the developer's
incidental workspace state? If yes, it does not belong in a set. If it
depends only on the environment the set legitimately requires, it does.
(`--prereqs` / `--preflight` already covers much of this ground; reach
for a guard when they don't.)

### And no, aeb should not ship `git() { no_untracked_files() }`

Asked and declined. The primitives already compose (`os.exec` +
`build.fail`, both existing public API), so a builder adds no capability
— it would only lend an official-looking name to the anti-pattern
dissected above, which is worse than the anti-pattern itself. It would
also be the first place aeb hardcodes one VCS. If a repo wants this shape
repeatedly it belongs in that repo's own `.aeb/lib/<name>/module.ae`, not
in core.

A gate on a *policy* rather than the working tree — an approval, an
attestation, an external status — already has a home in `lib/approval`.

## What the third audience gets

`.presubmit.ae` gives that role a file to own, in the same grammar as
everything else: greppable, diffable, reviewable, and addressable by the
same path form as any other target.

The payoff is that **the set becomes a reviewable artifact**. Adding a
target to CI stops being a change to a YAML file in some other system, or
a glob that silently widens as files get renamed, and becomes a diff — one
line, with an author, a date, and a reason in the commit message. Removing
one is equally visible. "What must be green before merge?" is answered by
reading a file in the repo, at the version of the repo you are asking
about, rather than by reading CI config that may have drifted from it.

That last property is the one worth protecting: the set travels with the
code. A branch that adds a module can add it to the set in the same
commit, and a bisect lands on a tree whose definition of "green" is the
one that was true at the time.

## The family

`presubmit` is not privileged. The convention is "a dep-only node is a
named set," and the name is yours:

```
.presubmit.ae      # must be green before you push
.merge-queue.ae    # the heavier set the merge queue runs
.smoke.ae          # the 30-second subset
.release.ae        # everything that gates a release
.nightly.ae        # the slow set nobody runs locally
```

Each routes to `target/<name>/` by the filename rule, each self-classifies
in the summary, each is addressable as `aeb .<name>.ae`.

**Sets may depend on sets.** A heavier set can build on a lighter one
rather than restating it:

```aether
// .merge-queue.ae — everything presubmit checks, plus the slow suite
import build (start, dep)

aeb(cap) {
    b = build.start()
    build.dep(b, ".presubmit.ae")   // <- a set as a member
    build.dep(b, "b/.tests.ae")
}
```

Verified: `aeb .merge-queue.ae` summarises as
`aeb: 2 tests + 1 presubmit + 1 merge-queue` — both set types
self-classify — and a member reachable through *both* paths runs exactly
once, because the visited-set dedup is what deduplicates it.

Scoping still applies: a set built from a subdirectory sees that subtree.
A repo-root `.presubmit.ae` is the natural home for a whole-repo set.

## Composing with `--since`

The two mechanisms answer different questions and compose cleanly:

```bash
# Everything that must be green, always.
aeb .presubmit.ae

# Only the part of it your PR could have broken.
aeb --since origin/main
```

`--since` narrows by *what changed*; a target set declares *what matters*.
Note these are separate invocations — `--since` is a modal flag that
consumes one target directive, so it does not currently take a target set
as its universe. Intersecting the two ("the impacted subset of
`.presubmit.ae`") is a plausible future ask, not today's behaviour.

## What NOT to do

- **Don't put build logic in a set.** A set is dep edges, a `meta.desc`,
  and — where genuinely warranted — a guard that fails via `build.fail`.
  The moment it grows a *builder* (it compiles something, it produces an
  artifact) it is a build target that happens to have deps, and the "what
  does this name mean?" clarity is gone. The test: a set's own body should
  only ever say no. If it makes something, it is not a set.
- **Don't reach for an inline guard first.** A check that belongs to one
  member belongs in that member, where it gets per-test PASS/FAIL
  accounting for free. Inline guards are for conditions that are genuinely
  properties of the *set* — and they cost reproducibility (see
  [Why this particular guard is a bad default](#why-this-particular-guard-is-a-bad-default)).
- **Don't special-case the name in the runner.** `presubmit` earns no
  privileges. If a future change makes `.presubmit.ae` behave differently
  from `.nightly.ae`, the convention has been broken.
- **Don't depend on a raw-`os.system` node that discards its exit code.**
  See the caveat above. A set is only as honest as its members.
