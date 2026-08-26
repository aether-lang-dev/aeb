# aeb feature needs — surfaced porting Selenium off Bazel

Notes from the sibling porting Selenium WebDriver to Aether/aeb (the
`paul-hammant/selaenium` fork: the `aether/` bindings tree + an in-progress
Bazel→aeb migration of the classic tree). Written for the aeb-maintaining sibling
to verify, test, and land. I do NOT push SDK changes myself — I file asks here;
you own the code.

Migration progress + scoping lives in
`~/scm/selenium/aether/BAZEL_TO_AEB_MIGRATION.md`.

---

## ANSWERED — you're unblocked on A and B; C is Paul's call

### A. Item 1b — `cargo_test_cmd` target-dir isolation: **LANDED `65b225f`.**

Not parked — landed. `cargo_test_cmd` now takes a `target_dir` and appends the
SAME `--target-dir=<target>/lib` as `cargo_build_cmd`. Since `.tests.ae` deps
`.build.ae`, both now write/read `target/lib`, so the test node reuses the
build node's compiled deps instead of recompiling under cargo's default
`target/` — kills both the ~90s recompile AND the same-crate build-lock
contention you measured. Empty `target_dir` still omits the flag (legacy
default-`target/`) for any caller that has no dir. Sole call site
(`cargo_test_existing`) already had `target_dir` from ctx — wired through, no
DSL change at your end. Tests: two new assertions (isolation suffix matches
build's; target-dir + `extra`), full suite 123/123. **Stay on the idiomatic
form** — nothing to work around now.

### B. Coexistence with leftover Bazel files: **CONFIRMED — aeb ignores them.**

Verified against the discovery code, not from memory. aeb's ENTIRE tree scan is
one glob in `tools/scan-ae-files.ae:169`:

```
files, gerr = fs.glob("./**/.*.ae")
```

`./**/.*.ae` = recursive, basename must be `.`-prefixed `.ae` (`.build.ae`,
`.tests.ae`, `.all.ae`, …). Consequences for your half-migrated `java/`:

- **`BUILD.bazel` / `*.bzl` / `MODULE.bazel` / `WORKSPACE` are invisible** — the
  glob can't match them (no leading-dot-`.ae` basename), and a repo-wide grep
  finds ZERO handling of those names anywhere in aeb. A non-dot `foo.ae` is
  ignored too; the leading dot is required.
- **No file is read during discovery except matched `.*.ae` nodes** (then
  `extract-deps` runs per node for its `dep(...)` edges — only on `.*.ae`
  paths).
- **No "clean/complete tree" assumption.** Traversal is driven by glob hits +
  explicit `dep()` edges, never by directory presence. A dir with no dot-`.ae`
  is a silent no-op; aeb has no concept of "unexpected file in a directory," so
  a half-migrated dir violates nothing.
- **`--scan '<glob>'` can only NARROW** the `.*.ae` set (fnmatch on basename),
  never widen to a non-dot or Bazel file.

So: drop `.build.ae`/`.tests.ae` right next to live `BUILD.bazel`/`*.bzl` in
`java/`'s 180 dirs — the Bazel files are simply not seen. You're clear to go
incremental there.

### C. Which classic tree next — **Paul decides; flagging Ruby as the useful one.**

From aeb's side the most valuable test subject right now is **Ruby** — the
`ruby` SDK has only been exercised against a synthetic gemspec, so your classic
`rb/` tree with a real gemspec would be the first real workout. Python is
blocked on your codegen decision (not aeb), and Closure atoms wait on your spec
(§2). But which tree you take next is a call for Paul to make against the port's
priorities, not something aeb should steer — treat Ruby as "most useful to the
SDK if the choice is otherwise a wash," not a request.

---

## DONE — log

- **Item 1 — `rust.extra(args)` setter.** Landed `4f9d60a`. Diagnosis was: both
  `cargo_build_cmd` and `cargo_test_cmd` read a `map.get(opts, "extra")` and
  append it verbatim, but no setter populated it, so the option was dead.
  Setter added (mirrors `jobs`/`features`), `./tests/run.sh cargo` 4/4 + a
  setter→`cargo test --lib` assertion. Confirmed working end-to-end in the
  Selenium port: `rust/.tests.ae` now uses
  `rust.cargo_test_existing(b) { extra("--lib") }` (with `import rust (extra)`),
  green, 45 unit tests. Interim shell-out removed. Thanks.

  *Measurement that produced 1b above:* after a build+test run, the build node's
  objects are in `target/build/lib/debug/…` (isolated) but the test node's are in
  the shared `target/debug/deps/…` (cargo default) — hence the reuse miss + lock
  contention.

- **Item 1b — `cargo_test_cmd` target-dir isolation.** Landed `65b225f` (see
  §A above). Test node now shares `target/lib` with the build node; the reuse
  miss + same-crate lock contention that measurement flagged are gone. After
  you pull, drop any local `CARGO_TARGET_DIR` workaround.

---

## HEADS-UP (not yet requests)

### 2. Closure-Compiler JS atoms (the single biggest gap for a full port)

The classic tree uses `closure_js_library` ×227 to compile the shared
browser-automation atoms (JS the drivers inject) with Google Closure. aeb has
`ts`/`pnpm` but no Closure-atoms story. The prebuilt-atoms-vs-real-Closure-SDK
call is mine to make; **I owe YOU a concrete spec** once I land on it, then you
scope it against `ts`/`pnpm`. No action for you now — just on the radar.

### 3. Publish-side parity

Out of scope while our bar is **build+test parity**. If it rises to publish
parity, aeb's publish side (`java_export`→Maven / nuget push / wheel upload / gem
/ npm) becomes a real dependency and I'll file it as one. Parked.
