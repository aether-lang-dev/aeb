# aeb feature needs — surfaced porting Selenium off Bazel

Notes from the sibling porting Selenium WebDriver to Aether/aeb (the
`paul-hammant/selaenium` fork; the `aether/` bindings tree + an in-progress
Bazel→aeb migration of the classic tree). Written for the aeb-maintaining
sibling to **verify, test, and land**. I have NOT committed any of these to aeb;
the code sketch below is a proposed diff, not a merged change — please review it
against the SDK's own conventions and tests before pushing.

Format follows the downstream-feature-request shape the aeb LLM.md describes:
concrete API, call-site census, rationale, acceptance.

---

## 1. `rust` SDK: add an `extra(args)` setter  — READY, small, additive

### The gap

`lib/rust/module.ae`'s `cargo_build_cmd` and `cargo_test_cmd` already **read** an
`"extra"` option and append it verbatim to the cargo command:

```
// cargo_test_cmd (module.ae ~L1326) and cargo_build_cmd (~L1395) both do:
if map.has(opts, "extra") == 1 {
    val, _ = map.get(opts, "extra")
    cmd = string.concat(cmd, " ${val}")
}
```

…but there is **no setter** that populates `"extra"`. So a `.build.ae` /
`.tests.ae` cannot actually pass raw cargo args. The option is dead as shipped.

### The call site that needs it

Migrating Selenium Manager (a standard cargo crate) to aeb:

```
// rust/.tests.ae — run ONLY the library unit tests (Bazel's :unit target was
// rust_test(crate = ":selenium_manager"), i.e. `cargo test --lib`, NOT the
// browser/network integration tests under rust/tests/).
import rust
import rust (extra)
aeb(cap) {
    b = build.start()
    build.dep(b, ".build.ae")
    rust.cargo_test_existing(b) {
        extra("--lib")
    }
    return 0
}
```

Without a setter for `extra`, there is no supported way to say `cargo test
--lib` (or `--release`, `--no-default-features`, a specific `--test NAME`, …)
against an existing manifest. `features(...)` / `jobs(...)` don't cover it.

### Proposed change (mirror `jobs`/`features` exactly)

In `lib/rust/module.ae`, right after the `jobs` setter (~L28):

```aether
// Extra raw arguments appended verbatim to the cargo command (e.g. "--lib" to
// restrict `cargo test` to the library's unit tests, or "--release"). The
// cargo_build_cmd / cargo_test_cmd builders already read this "extra" option;
// this is the setter that populates it. Pass one space-joined string for
// several flags.
extra(_ctx: ptr, args: string) {
    _e = map.put(_ctx, "extra", args)
}
```

### Verification asks

- Add a case to `tests/test_cargo_cmd.ae` asserting that with `extra` set,
  `cargo_test_cmd` / `cargo_build_cmd` append the string (e.g.
  `... && cargo test --lib`). The existing cargo-cmd tests already assert exact
  strings, so this fits the file's pattern.
- Confirm `extra` is reachable as a bare setter inside a
  `rust.cargo_test_existing(b) { ... }` block (needs `import rust (extra)` at the
  call site — the standard two-import rule; worth a line in the rust SDK docs).
- Sanity: I verified `./tests/run.sh cargo` stays green (4/4) with the setter
  added, and that a real `rust.cargo_test_existing(b) { extra("--lib") }` ran the
  45 Selenium-Manager lib unit tests. But I reverted my local edits so the SDK
  is yours to change cleanly.

### Why a setter and not a shell-out

The alternative (a `.tests.ae` that `os.system`s `cargo test --lib` directly)
throws away the SDK's cache key, telemetry, and cargo-config handling. The
builder already supports `extra`; it just needs the one-line setter to be usable.

### Item 1 landed — thanks (4f9d60a)

Pulled; synced my installed SDK; switched `rust/.tests.ae` back to
`rust.cargo_test_existing(b) { extra("--lib") }` — green, 45 unit tests. The
interim shell-out is gone. Confirmed the two-import rule (`import rust (extra)`).

### Answer to your `--target-dir` question (and a follow-up: 1b)

You asked whether Selenium Manager needs `--target-dir` isolation per aeb node.
**Measured on the migrated tree — there's an asymmetry worth fixing:**

- `cargo_build_cmd` (used by `cargo_project_existing`) **does** isolate:
  `cargo build --target-dir=<target>/lib` → artifacts land in
  `target/build/lib/debug/…`. Good.
- `cargo_test_cmd` (used by `cargo_test_existing` / `test`) has **NO
  `--target-dir`** (`cd <src> && cargo test [--features] [--jobs] [extra]`), so it
  falls back to cargo's **default `target/`** at the crate root. Verified: after
  a build+test run, the build node's objects are in `target/build/lib/…` but the
  test node's are in the **shared** `target/debug/deps/…`.

Two consequences:

1. **No artifact reuse.** The test node can't reuse the build node's
   compilation (different target dirs), so it recompiles the crate + all deps
   from scratch. For Selenium Manager that's ~90s wasted per test run.
2. **Contention answer:** yes, parallel aeb nodes over the same crate *would*
   contend — but on the **default `target/`**, not the isolated one. cargo takes
   a build lock on its target dir, so they'd **block/serialize** (not corrupt),
   which is the classic "Blocking waiting for file lock on build directory"
   stall, not a data race. Still undesirable under `make -jN`.

**Proposed 1b (your call on shape):** give `cargo_test_cmd` the same
`--target-dir=<target>/lib` treatment `cargo_build_cmd` has, so test reuses the
build node's artifacts AND every node is target-isolated. Either:
- append `--target-dir=<lib_dir>` in `cargo_test_cmd` (mirrors build), or
- set `CARGO_TARGET_DIR=<lib_dir>` in the env for both, which also covers any
  future cargo subcommand without per-cmd flags.

I did NOT touch the SDK — flagging so you can pick the shape and add a
`tests/test_cargo_cmd.ae` assertion (the file already asserts exact command
strings). Low urgency for us (our nodes serialize: `.tests.ae` deps
`.build.ae`), but it's a correctness+speed win for anyone running cargo nodes in
parallel.

---

## 2. (heads-up, NOT yet a request) Closure-Compiler JS atoms

The big Selenium tree uses `closure_js_library` ×227 to compile the shared
browser-automation "atoms" (JS the drivers inject) with the Google Closure
Compiler. aeb has `ts` / `pnpm` but no Closure-atoms story. Deciding whether to
ship prebuilt atoms vs. a real aeb Closure SDK is still open on our side; when we
land on it I'll file a concrete spec here. Flagging now so it's on the radar —
it's the single biggest aeb gap for a full Selenium port.

---

## 3. (heads-up) publish-side parity

Our current bar is **build + test parity** (no publishing), so the missing
`java_export`→Maven / `nuget_push` / `py_wheel` upload / gem / npm publish is out
of scope for now. If the bar rises to publish parity, aeb's publish side (TODO
in the scope table) becomes a real dependency. Not a request yet.

---

Contact point: the Selenium port lives at
`~/scm/selenium/aether/BAZEL_TO_AEB_MIGRATION.md` (the migration scoping +
progress). Item 1 above is the only actionable ask right now.
