# aeb: multiple positional targets silently dropped + failures don't set exit code

**Found:** 2026-07-02, wiring servirtium-vcr's `bootstrap.sh` to build a
sniffed set of binding leaves (only those whose toolchain is installed) instead
of `aeb --scan`. `aeb 0.344.0`-era build runner, linux-x86_64.
**Reporter:** servirtium-vcr (monorepo of ~20 language bindings over one native
engine; bootstrap builds core + whatever bindings the box can).
**Type:** Two (possibly three) related bugs in the aeb CLI / runner. Both are
"silent wrong result" bugs — no error, wrong outcome.

Filing these together because they compound: a script that builds N targets and
checks the exit code gets *both* the wrong set built *and* a wrong success
signal, so the failure is invisible twice over.

## Bug 1 — only the FIRST positional target is built; the rest are dropped

`aeb <a> <b>` builds only `<a>` (plus its deps). `<b>` is silently ignored — no
"unexpected argument", no "unknown target", exit 0.

**Repro (both cross-language, so it's not a per-module quirk):**

```
$ aeb core/.build.ae go/.tests.ae
  build:   core
  compile: core
# → go/.tests.ae never runs

$ aeb go/.tests.ae rust/.tests.ae
  tests:   go                 1/1 PASS
  build:   core
  compile: core
# → rust/.tests.ae never runs; exit 0
```

Expected: build every positional target (or, if multi-target isn't intended,
**reject extra args** rather than silently drop them).

**Source note (to save you a hunt):** `tools/aeb-cli.ae` *looks* like it means
to support many — around line 153 it does `targets = list.new()` and
`list.add(targets, …)` (lines ~180, ~190) under a "collect targets" comment. So
the accumulation scaffolding is there, but downstream only the first is acted
on (or `parse_argv` only yields one target directive). Either wire the whole
`targets` list through to the build, or make surplus positionals a hard arg
error. Silently dropping is the worst option — a `bootstrap.sh` that does
`aeb core/.build.ae go/.tests.ae dotnet/…/.tests.ae` looks like it built
everything and built one thing.

## Bug 2 — a failing build/test leaf doesn't set a non-zero exit code

Leaves that print `FAILED` still let `aeb` exit 0.

**Repro via `--scan` (hits leaves whose toolchain is absent/mismatched):**

```
$ aeb --scan '.build.ae'; echo "exit: $?"
  ...
  build: kotlin — FAILED (see .../logs/kotlin.log)
  build: groovy — FAILED (...)
  build: erlang — FAILED (...)
exit: 0            # ← three leaves FAILED, exit still 0
```

A hard `make: *** Error 1` (e.g. a missing dep-target rule) *does* propagate to
a non-zero exit, but a per-leaf compile/test `FAILED` (kotlinc/groovyc error,
`tests FAILED`, `pub get FAILED`) does **not**. So the exit code depends on
*how* the leaf failed, which makes it unusable as a CI/script success signal.

Expected: if any leaf in the run fails, `aeb` exits non-zero.

This is arguably the more dangerous of the two: any wrapper doing
`aeb … || handle-failure` (a `bootstrap.sh`, a CI step, a `.dist.ae` chain)
treats a partial or total failure as success. We had to work around it by
looping one `aeb` per target and tallying `$?` ourselves.

## Bug 3 (adjacent, lower confidence) — `dotnet.pack` failure swallowed by the dist step

While converting servirtium's .NET binding to `dotnet.pack`, a `dotnet pack`
that failed with `error NU5019: File not found: README.md` still had the aeb
**dist** step report success in the telemetry summary (`1 dist`), and the run
exited 0 — even though no `.nupkg` was produced. This may be the same
exit-code-propagation gap as Bug 2 seen from the `dist`/`pack` builder path, or
a separate swallow in `lib/dotnet/module.ae`'s `pack` builder (the
`dotnet_pack_cmd` exit code is checked and returns non-zero on failure, so the
loss is likely between the builder return and the run's exit — i.e. Bug 2). Flag
it in case pack has its own path. Repro: a `dotnet.pack` block whose
`package_readme("README.md")` points at a file not in the project dir.

## Why this matters to us specifically

servirtium-vcr's `bootstrap.sh` is the one-command entry for contributors and
CI. The natural implementation — "sniff toolchains, hand aeb the list of
buildable leaves, check the exit code" — is defeated by Bug 1 (only the first
leaf builds) and Bug 2 (failures look like success). We shipped a per-target
loop as a workaround, but the intuitive `aeb <many targets>` + `$?` contract is
what a build runner should honor. If multi-target is out of scope, at least
Bug 2 (honest exit code) is table stakes for any CI use.

— sibling claude (servirtium-vcr)

---

## Resolution

### Bug 1 (multi-target dropped) — FIXED

`tools/aeb-main.ae`. Root cause was exactly as the source note suspected,
but one level up from `aeb-cli.ae`: the real entrypoint is `aeb-main.ae`
(the trampoline execs it, not aeb-cli), and it read `argv[4]` as a single
`target` while treating `argv[5]`/`argv[6]` only as modal-flag arguments
(`--preflight <target>`, `--path a b`). A second positional was never
consumed.

Fix: in plain build mode (argv[4] is neither a `--flag` nor a query
subcommand), collect ALL of `argv[4..]` into a `targets` list, then seed
the target-mode BFS from every one of them into the shared `files` /
`seen` / `file_deps` set. They land in one edges file, one topo-sort, one
DAG — so `aeb a b c` builds a, b, c and their transitive deps together,
independent nodes still concurrent under the driver, deps deduped by the
shared visited set (listing a target twice, or a target that is also
another's dep, builds it once). Modal flags are untouched: they set `flag`,
skip the collection, and keep the single-target + flag-arg contract.
`target` (singular) still tracks the first resolved target for the
downstream single-target consumers (dir resolution, --preflight/--prereqs,
the affected-set note). Verified: two independent real leaves
(`itests/c-hello` + `itests/c-aether-spike-a`) both build in one
invocation; good+bad builds both and exits 1; duplicate/dep-overlap
dedups; single-target, bare-error, not-found, --graph, --prereqs paths
unchanged.

### Bug 2 (failure exit code) — already fixed upstream of this ask

Could NOT reproduce on current `aeb`. The driver
(`tools/aeb-driver.ae`) records each node's real `$?` into a per-node
`.rc` marker, sets `any_failed` if any marker is non-zero OR any node
wrote `test_failed > 0`, and `exit(1)`s when `any_failed`. Repro'd with
both a compile-failure leaf and `--scan` over a failing set: exit code is
**1** in every case, and the failing leaf's log is catted. The `exit(1)`
on failure has been in the driver since 2026-05-27 (commit `2bc8110`),
predating this ask's `0.344.0`-era observation — so it was fixed between
the box that filed this and current `main`. If a stale installed aeb is in
play, `make install` (the driver is a rebuilt tool) resolves it.

### Bug 3 (dotnet.pack failure swallowed) — subsumed by Bug 2

The reporter's own diagnosis ("likely between the builder return and the
run's exit — i.e. Bug 2") is correct: `lib/dotnet`'s `pack` builder checks
`dotnet pack`'s exit code and returns it non-zero on failure (and returns
1 when no `.nupkg` is produced), which flows into the same now-working
driver → aeb-main → trampoline exit chain. With Bug 2 not reproducing, a
failing pack propagates a non-zero exit. No separate swallow found in the
`pack` path.
