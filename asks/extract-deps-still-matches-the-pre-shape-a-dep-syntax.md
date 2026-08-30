# BUG: `extract-deps` still matches `dep(b, "` — Shape A nodes get a SILENTLY EMPTY dep graph

**From:** html-sanitizer (2026-08-27). **Severity: silent-green.** Every
`dep()` edge in a converted node is dropped, so aggregate targets report
success having run almost nothing.

## Symptom

After converting to Shape A, our `.presubmit.ae` — 29 declared `dep()` edges —
ran **one** node and exited 0:

```
$ aeb .presubmit.ae
aeb: 1 presubmit
total: 0.03s wall
```

Before conversion, the same file enumerated the whole graph:

```
aeb: 23 tests + 1 abi + 1 xss + 1 ganss + 1 normalize + 1 baselines + 1 presubmit
```

Nothing warned. The build was green because it had nothing to run.

## Cause

`tools/extract-deps.ae:351`:

```aether
// Pass 1: dep(b, "...") — explicit single-target deps.
needle = "dep(b, \""
```

Shape A nodes write `dep("core/.build.ae")`. The needle still requires the
`b, ` that Shape A removed, so `string.index_of` never matches and every edge
is dropped.

Note the comment four lines above it at :346 was already updated to the new
syntax — *"a same-dir `dep(".build.ae")`"* — so the intent was there; only the
needle was missed.

## Fix

```aether
needle = "dep(\""
```

Verified locally: with that one change our presubmit goes from 1 node to 32,
and the full suite runs.

```
aeb: 23 tests + 3 build + 1 abi + 1 xss + 1 ganss + 1 normalize + 1 baselines + 1 presubmit
```

Worth grepping for other pre-Shape-A literals in the tooling — anything
matching `(b, ` or `(b)` as a *string* rather than as code. `dep_artifact(b, `
is the obvious next candidate.

## Why this one is worth prioritising

It fails in the direction that does not get noticed. A crash gets fixed; a
green build that ran nothing gets trusted and shipped. In our case it hid a
`java_main` segfault (`asks/java-main-segfaults-when-node-has-no-maven-deps.md`)
plus stale assertions in **eight** language bindings — all of which surfaced
the moment the scanner was fixed.

A regression test worth having: a fixture node with N `dep()` edges, asserting
the scanner reports N. That would have caught this at the codemod commit.

---

## RESOLVED (verified 2026-08-30)

Already fixed in the tree: `tools/extract-deps.ae:355` is `needle = "dep(\""`
(the Shape-A spelling). `tests/test_extract_deps_scan.ae` asserts Shape-A
`dep("...")` counting, so the regression test this ask asked for exists.
Satisfied by the DSL sweep; no further action.
