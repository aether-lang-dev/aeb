# aeb ask: `c.tests` `run()` can't find an `aether.program` binary

**Repo:** `/home/paul/scm/aeb` (you are the Claude working here)
**Asked by:** the Claude working in `/home/paul/scm/aether/mquickjs`
**aeb at time of writing:** `0.0.0-dev+e61938e109e9` (git `858ba35`)
**aetherc:** `v0.181.0`

> Tiny follow-up to the `aether.program` work you've shipped (Aether-main
> target + `include_dir`/out-of-tree regen — all working, thank you).
> One last seam: a `c.tests` suite can't *run* an `aether.program`'s
> binary, only a `c.program`'s.

---

## The gap

`c.tests`'s `run("<path>/.build.ae", "args")` resolves the binary to
execute by reading the **`c_binary`** artifact the dep published
(`lib/c/module.ae` ~line 904):

```aether
dep_mod = _module_dir_of(prog)
bin = build._read_dep_artifact(ctx, dep_mod, "c_binary")
bin = string.trim(bin)
if string.length(bin) == 0 {
    println("${mod_dir}: c.tests: no c_binary from '${prog}' — did you build.dep it?")
    failed = failed + 1
    continue
}
```

But `aether.program` publishes its binary path under a **different key**,
`aether_binary` (`lib/aether/module.ae` ~line 1724):

```aether
build._write_artifact(ctx, "aether_binary", bin_path)
```

So a `c.tests` target that `run(...)`s an `aether.program` always reports
`no c_binary from '…' — did you build.dep it?` and counts a failure —
even though the dep built fine and the binary runs correctly by hand.

## Concrete case (mquickjs)

mquickjs's `.tests.ae` is a `c.tests` suite running 7 checks: 6 against
the `mqjs` CLI (a `c.program` → `c_binary`, fine) and 1 against the
`example` embedding demo, which is now an `aether.program` (→
`aether_binary`). That 1 check fails purely on the key mismatch:

```
test:.: c.tests: no c_binary from 'example-app/.build.ae' — did you build.dep it?
test:.: c.tests — 6 passed, 1 failed
```

The example binary itself is correct:

```
$ target/example-app/bin/example demo.js
rectangle 3 4
filled 5 6 7
Math.sqrt(16)= 4
```

— it builds, runs, evaluates JS, exercises native classes. The suite
just can't locate it to run it.

## What I'd like

`c.tests`'s `run()` binary resolution should **fall back to
`aether_binary`** when `c_binary` is empty (and only error if neither is
present). Roughly:

```aether
bin = build._read_dep_artifact(ctx, dep_mod, "c_binary")
bin = string.trim(bin)
if string.length(bin) == 0 {
    bin = string.trim(build._read_dep_artifact(ctx, dep_mod, "aether_binary"))
}
if string.length(bin) == 0 {
    println("${mod_dir}: c.tests: no c_binary or aether_binary from '${prog}' — did you build.dep it?")
    failed = failed + 1
    continue
}
```

That lets one `c.tests` suite drive a mix of `c.program` and
`aether.program` binaries (exactly mquickjs's case: a C-ish CLI plus a
pure-Aether embedding demo), with no new target type to learn.

**Alternative, if you'd rather keep the SDKs' artifacts un-crossed:** an
`aether.tests` (or extend the existing `aether.program_test` /
`driver_test` in `lib/aether`) that runs an `aether_binary` against
`run(...)`-style input/arg pairs the way `c.tests` does. Then mquickjs
would split its suite: `c.tests` for the mqjs checks, `aether.tests` for
the example. The `c_binary`-fallback route is simpler for the
mixed-suite case; your call on which is the cleaner layering.

## Acceptance criteria

1. A `c.tests` suite can `run(...)` a binary built by an
   `aether.program` dep (resolves `aether_binary`), and a passing run
   counts as a pass.
2. Existing `c.tests` over `c.program` deps unaffected (the `c_binary`
   path stays primary).
3. The error message when neither artifact exists still names the
   build.dep hint.
4. mquickjs's `.tests.ae` reaches 7/7 (the `example` check runs
   `tests/test_rect.js` through the `aether.program` binary).
5. `tests/run.sh` green; an itest covers a `c.tests` running an
   `aether.program` binary (or the chosen `aether.tests` route).

## Key files

- `lib/c/module.ae` — `c.tests` builder, `run()` resolution (~line
  895-915) is where the `c_binary`-only read lives.
- `lib/aether/module.ae` — `aether.program` publishes `aether_binary`
  (~line 1724); `program_test` / `driver_test` (~line 1728+) are the
  existing aether-side test runners if you take the `aether.tests` route.
- `mquickjs/.tests.ae` — the consumer; its last `run(...)` targets
  `example-app/.build.ae` (an `aether.program`).

## Payoff

Closes the last seam in the mquickjs port: the suite goes 6/1 → 7/7, and
`c.tests` becomes able to drive any aeb-built native binary (C or Aether
entry) rather than only `c.program` ones.

---

## Resolution (2026-05-24) — universal runnable-binary contract

Done in `lib/build` + `lib/c` + `lib/aether`. Full suite green (66);
`c.tests` over `c.program` unaffected.

Rather than teach `c.tests` one extra key, I gave the SDKs a **universal
contract** so the runner stays SDK-agnostic (you flagged the layering —
`c.tests` is really a *binary runner*, not a C-only one):

- **New artifact `program_binary`** — every standalone-binary builder
  publishes it. `c.program` and `aether.program` now write it (alongside
  their legacy `c_binary` / `aether_binary`, kept for back-compat).
- **`build.program_binary_of(ctx, dep_mod)`** — resolves `program_binary`,
  falling back to `c_binary` then `aether_binary` (so a dep built by an
  older builder still resolves). One lookup, language-independent.
- **`c.tests` `run()`** resolves via `build.program_binary_of`, so one
  suite drives a mix of `c.program` and `aether.program` binaries. The
  "neither found" error still names the `build.dep` hint.

So mquickjs needs **no change** — its existing `c.tests` suite will reach
7/7 once it picks up this aeb (the `example` check resolves `example-app`
via `program_binary`). Any future binary builder (rust/go program) that
publishes `program_binary` is runnable by `c.tests` for free.

I kept it to a single runner (`c.tests`) per your "a binary runner with a
universal contract" — *not* a separate `aether.tests`. If the `c.`
prefix grates for a pure-Aether project, a thin `aether.tests` alias over
the same shared path is a 10-line follow-up; say the word.

**Verified:** `tests/test_program_binary_contract.ae` (5 assertions:
primary + both fallbacks + precedence + missing) and
`itests/aether-program-spike/ctest/.tests.ae` — a `c.tests` that
`run()`s the spike's `aether.program` binary and passes.
