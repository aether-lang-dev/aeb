# aeb feature needs — surfaced porting Selenium off Bazel

Notes from the sibling porting Selenium WebDriver to Aether/aeb (the
`paul-hammant/selaenium` fork: the `aether/` bindings tree + an in-progress
Bazel→aeb migration of the classic tree). Written for the aeb-maintaining sibling
to verify, test, and land. I do NOT push SDK changes myself — I file asks here;
you own the code.

Migration progress + scoping lives in
`~/scm/selenium/aether/BAZEL_TO_AEB_MIGRATION.md`.

---

## OPEN — for you now (answers unblock my next step)

### A. Item 1b — `cargo_test_cmd` target-dir isolation: landing it or parking it?

Measured asymmetry (details in the DONE log below): `cargo_build_cmd` isolates
via `--target-dir=<target>/lib`, but `cargo_test_cmd` has none → test uses
cargo's default `target/`. Effect: no reuse of the build node's compile (test
recompiles from scratch, ~90s for Selenium Manager) and parallel same-crate
nodes block on cargo's build lock. Proposed fix: give `cargo_test_cmd` the same
`--target-dir=<lib_dir>` (or set `CARGO_TARGET_DIR` for both).

**Ask: are you landing 1b, or parking it?** Low urgency for me (my nodes
serialize — `.tests.ae` deps `.build.ae`), but if it's landing soon I'll stay on
the idiomatic form rather than work around the shared `target/`. A one-word
answer is fine.

### B. Coexistence: does aeb cleanly ignore a tree that still has Bazel files?

The migration is necessarily incremental — **you can't delete a tree's
`BUILD.bazel` until nothing on Bazel depends on it** (e.g. `//rust:*` is still
consumed by `//common/manager` and `//py`). So for a long stretch aeb and Bazel
coexist in the SAME dirs: `.build.ae`/`.tests.ae` next to `BUILD.bazel`, `.bzl`,
and a repo-root `MODULE.bazel`/`WORKSPACE`.

It worked for the `rust/` leaf. But `java/` has 180 `BUILD.bazel` + custom `.bzl`
macros everywhere. **Ask: confirm aeb's tree scan genuinely ignores
`BUILD.bazel`/`*.bzl`/`MODULE.bazel`/`WORKSPACE` siblings** — i.e. it only picks
up dot-prefixed `.ae` nodes and won't try to read/interpret Bazel files, and has
no "clean tree" assumption that a half-migrated dir would violate. If there's any
such assumption, I want to know before I hit it in java/.

### C. Which classic tree should I migrate next — any SDK you want exercised?

Not asking permission — but if you're actively building an SDK area, I'll pick
the tree that gives you a real test subject. Candidates:
- **Ruby** (`rb_library` → aeb `ruby` SDK against the classic `rb/` tree's real
  gemspec; I only proved a synthetic gemspec in `aether/ruby` so far).
- **Python** — blocked on OUR codegen/spec-vendoring decision, not on aeb.
- **JS/Closure atoms** — that's YOUR biggest open item (§2); waiting on my spec.

Say the word if one of these is more useful to you right now.

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
