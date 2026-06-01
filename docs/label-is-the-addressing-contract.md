# The label is the addressing contract — why output routing isn't a body setter

Status: **design / position.** Captures a foundational finding about *why*
test-vs-prod artifact routing lives where it does, and the decision that
author-declared routing — if added — belongs in a **scan-time structured
comment folded into the label**, not a runtime body setter. Written after a
long inquiry that started as "make `is_colocated_test` a declared var" and
ended at "the label is how every node addresses every other node's output."

## The question that started it

`.tests.ae` files route their artifacts to `target/tests/...` *automatically*,
inferred from the filename suffix (`.tests.ae` → `test:` label →
`is_colocated_test` → `/tests` prepend). That inference is the same kind of
implicit magic the project otherwise avoids. The instinct: make it
**declared** — a body setter like `output_subdir(b, "tests")` — so the build
file says where its output goes instead of aeb guessing from the filename.

That instinct is right in spirit and wrong in mechanism, for a reason that
turns out to be load-bearing far beyond test classification.

## Two facts about aeb's data flow (both verified in the code)

**Fact 1 — `b` (the build ctx) dies when a node's function returns.**
Each `.ae` file's `main()` (rewritten to `build.begin(s, "label")` by
`transform-ae`) runs as one function. `b` is a local in it. The orchestrator
calls the function, it returns nothing useful (the orchestrator deliberately
ignores the return — a trailing-block builder's implicit return is garbage,
see `gen-orchestrator.ae`). A body setter's effect lives only in `b`, which
is gone the instant the function returns.

**Fact 2 — cross-node data is mediated by DISK, keyed by the dep's LABEL.**
The orchestrator never passes one node's `ctx` to another. When `.dist.ae`
needs `.compile.ae`'s output, it calls `_read_dep_artifact(ctx, dep_label,
artifact)`, which is (verbatim shape):

```aether
_read_dep_artifact(ctx, dep_module, artifact) {
    root = _get(ctx, "root")
    p = path.join(root, "target", dep_module, artifact)   // path from the dep's LABEL
    if file.exists(p) == 1 { return io.read_file(p) }      // read from DISK
    return ""
}
```

So a dependent addresses its dependency's output as
`target/<dep-label>/<artifact>` — **derived purely from the dep's label
string.** No ctx crosses the edge. The same is true of the orchestrator's
post-build bookkeeping finder (`_label_to_target_dir`), which reconstructs a
node's `target/` dir from its label to read cache markers and test results.

## The consequence: a node's output location must be label-derivable

Put Fact 1 and Fact 2 together:

> Every consumer of a node's output — dependents (`_read_dep_artifact`), the
> cache-outcome reader, the test-result reader — finds that output by
> **deriving a path from the node's label**. None of them has the node's
> `b`. So wherever a node actually writes, that location **must be computable
> from the label alone**, or every consumer reads the wrong (empty) path.

This is exactly the bug we already hit and fixed: the deleted `is_test`
dir-heuristic made `build.start` (which has `b`) write to
`target/tests/tests/...` while `_label_to_target_dir` (label-only) looked in
`target/tests/...` — mismatch → silent cache death. That wasn't a one-off; it
was this contract being violated.

So a body setter `output_subdir(b, "custom")` that relocates output **without
the label reflecting it** breaks the contract for *every* consumer:
- dependents read `target/<label>/...` (default) — miss the relocated output;
- the cache finder reads the default path — phantom cache misses;
- the test-result finder reads the default path — test counts vanish.

**The label is not decoration on the output path — the label IS the address
of the output.** `test:` in a label isn't a classification tag that happens to
also route; routing IS its job, because the label is how the whole DAG
addresses that node's `target/` dir.

## Therefore: declared routing must reach the label, at scan time

If routing is to be author-declared (not filename-inferred), the declaration
has to end up in **the label**, because the label is the one thing every
consumer reads. A runtime body call can't — it's in `b`, post-`begin`, after
the label was already fixed at scan time and handed to every consumer.

The channel that fits: a **structured comment atop the source, read
statically at scan time** — the same mechanism `tools/extract-deps` already
uses to find `dep(b, "...")` lines by `io.read_file` + string-scan, *without
running the file*. Precedent exists and is proven.

```aether
//aeb:output_subdir tests
//aeb:classify test
import build
import java

main() {
    b = build.start()
    build.dep(b, "java/components/velar/.build.ae")   // the ONLY thing relating test→prod
    java.javac_test(b)
    java.junit(b)
}
```

At scan time, `aeblabel`/the scan pass reads `//aeb:output_subdir tests` and
folds it into the label/metadata — so `build.start`, `_label_to_target_dir`,
and every dependent's `_read_dep_artifact` all derive the **same** path. The
declaration is now author-written (not filename-inferred) *and* visible to
every consumer (because it rides the label, the universal address).

### Why not the alternatives (recorded so they aren't re-litigated)

- **Body setter `output_subdir(b, ...)`** — real Aether, compiler-checked,
  fits the setter idiom; but it's in `b`, invisible across the node boundary
  (Fact 1) and to label-based addressing (Fact 2). Would need a session
  handoff for the bookkeeping finder AND a separate fix for every
  `_read_dep_artifact` consumer. Doesn't reach the address.
- **`build()`-returns-a-spec entry point** — the orchestrator could collect
  all specs first, then resolve dep paths from returned specs instead of
  label-derivation. Genuinely solves it, but rebuilds aeb's two-pass
  (scan → run) model into three (scan → collect specs → run) and changes the
  entry contract of every `.ae` file. Large; deferred.
- **Keep filename inference (`.tests.ae`)** — the honest fallback: accept that
  output location belongs to the label (the addressing scheme), so it stays
  suffix-derived. The inference IS the addressing; it already works and caches
  correctly. The cost of "declared not inferred" purity may exceed its value.

## Honest cost of the chosen direction (structured comment)

- **It's a comment mini-language**, not Aether syntax — a departure from
  "the closure-DSL is the source of truth, no eval'd config." A `//aeb:`
  directive is out-of-band relative to the setters in `main()`.
- **Not compiler-enforced** — a typo'd `//aeb:ouput_subdir` is silently
  ignored (it's a comment), where a typo'd setter is a compile error.
- **Two config locations** — some build config in `main()` setters, some in
  header comments; an author must learn which goes where.

These are real and argue for keeping the comment surface *minimal* — only the
handful of facts that must be label-resident (routing, classification)
because they're addressing, not behaviour. Everything that is genuinely
*behaviour* (what to compile, deps, flags) stays in the body setters where it
belongs and where the compiler checks it.

## The one-line summary

A node's `target/` dir is addressed by its **label**, by every other node and
by aeb's own bookkeeping, none of which hold the node's `b`. So output
routing is **addressing, not behaviour** — it must be derivable from the label
at scan time. If it's to be author-declared rather than filename-inferred, the
declaration belongs in a **scan-time structured comment folded into the
label**, not a runtime body setter. The label is the addressing contract; keep
it the single source of where a node's output lives.

## Postscript: the filename was already the declaration

The structured-comment channel (`//aeb:output_subdir` / `//aeb:classify`) was
built per this doc, then **retired**. The realisation:
`docs/filename-is-the-route.md` showed the **build-file name itself** is the
scan-time, label-resident declaration this doc was looking for —
`.tests.ae` → `target/tests/`, `.staging.ae` → `target/staging/`. It satisfies
the addressing contract by construction (every consumer derives the path from
the same filename) and needs no comment, no inference layer, no override. The
contract's requirement ("declaration must be label-derivable at scan time")
stands exactly; the simplest thing that meets it turned out to be the name the
author already chose. Comment directives were a more elaborate answer to a
question the filename had already answered.
