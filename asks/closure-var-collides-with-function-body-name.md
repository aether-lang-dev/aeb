# A closure local that reuses a function-body name is emitted UNDECLARED in C

> **UPDATE (2026-09-19): ae 0.697.0 carries a PARTIAL fix — the rename below
> MUST STAY.** Aether merged this as PR #2114 and shipped `055fcc7d`
> ("a closure own-local shadowing a promoted capture emits valid C") with a
> regression test, `tests/regression/test_closure_local_shadows_promoted_capture.ae`.
> `055fcc7d` IS an ancestor of the v0.697.0 tag, and the shipped binary really
> does fix the shape upstream reduced to — compiling upstream's own test:
>
>     ae 0.696.0 -> FAILS (2 'undeclared')
>     ae 0.697.0 -> Built: upstream_regr
>
> But `lib/dotnet/module.ae` STILL emits the identical 3 'undeclared' errors on
> that same 0.697.0 binary (measured by reverting the rename in the installed
> SDK and rebuilding a dotnet leaf). So the fix covers the minimal case and not
> the real one that started this.
>
> This is the dangerous state: a merged fix, a passing regression test and a cut
> release all say "done", so anyone reading `055fcc7d` will reasonably conclude
> the workaround can be dropped on 0.697. It cannot — dropping it breaks every
> ae from 0.675 through 0.697 inclusive.
>
> Bisect, restated precisely: clean 0.668; broken 0.675, 0.677, 0.681, 0.696;
> on 0.697 the MINIMAL case is fixed and the REAL case is not.
>
> Found with the servirtium-vcr session, which filed the aether-side ask and
> spotted the partial-fix distinction; both compile results above independently
> reproduced here.

> **STATUS: worked around in aeb (2026-09-19)** by renaming the closure's locals.
> The underlying codegen/transform bug is still live and worth fixing properly.
> Found running the selaenium presubmit on catchyOS.

## Observed

`aeb dotnet/SeleniumCore.Tests/.tests.ae` could not build at all — gcc rejected
the generated C:

```
lib/dotnet/module.ae: In function 'dotnet_build_project':
lib/dotnet/module.ae:764:126: error: 'idx' undeclared (first use in this function)
lib/dotnet/module.ae:764:290: error: 'entry' undeclared (first use in this function)
aeb-link: FATAL — failed to link the fan-out orchestrator
```

Because the fan-out orchestrator is ONE binary for the whole graph, this did not
just fail that node — **no node in any graph containing it could run**, so
`ci/run.sh` (the full presubmit) died before executing a single test.

## Shape that triggers it

In `dotnet.build_project`, the names `idx` and `entry` are first assigned:

1. in the **function body**, inside a nested `if` within a `while` (the
   nuget-deps normalisation, ~line 724), and
2. again inside a **`string.seq_each` closure** in the same function, also inside
   a nested `if` (the vendored-refs loop, ~line 766).

The closure's copies are the ones emitted undeclared.

## What I could NOT reduce it to

Worth knowing before someone re-walks it — plain `ae run` handles all of these
(each printed the right answer on ae 0.696.0):

- a closure whose local is first assigned inside a nested `if`;
- the same, plus tuple destructuring (`a, _ = f()`) and `${}` interpolation
  mixing a captured outer variable with an inner one;
- the same name first assigned in the function body AND in a closure.

So the fault is not the raw language construct — it appears in **aeb's
transform/inline path**, where module functions are folded into the generated
fan-out program. That is the place to look.

Not an ae-version regression either: identical failure on ae 0.681.0 and
0.696.0, and `lib/dotnet/module.ae` is byte-identical between aeb v0.315 and
v0.319, so it is long-standing rather than newly introduced.

## Workaround applied

Renamed the closure's locals to `vr_idx` / `vr_entry` so they no longer collide
with the function-body names. `aeb dotnet/SeleniumCore.Tests/.tests.ae` then
links and runs: **83/83 PASS**.

That is a rename, not a fix — any future closure that happens to reuse an
enclosing function's local name will hit this again, silently, as a confusing
gcc error pointing at a line of Aether that looks perfectly valid.

## Suggested fix

Make the transform scope closure locals independently of the enclosing
function's, or mangle them, so name reuse cannot produce an undeclared
reference. A regression test of the exact shape above (body + closure sharing a
name, each first assigned inside a nested block) would pin it.
