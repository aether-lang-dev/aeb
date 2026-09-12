# SDK gaps blocking canonical (shell-out-free) binding nodes in libphonenumber-ae

libphonenumber-ae (the Aether port, branch `reboot`) is converting every
binding's `.tests.ae` / `.dist.ae` from `os.system("… <tool> …")` shell-outs to
canonical aeb SDK grammar. Most test nodes convert cleanly (ruby.bundle,
python.pytest, rust.cargo_test_existing, go.go_test — env() **inside the builder
block**, prereq() for clean skip). This ask collects the cases where the SDK
**cannot** express a node canonically, so we leave those nodes shelling out until
the grammar lands rather than working around it further.

Two things that turned out to be ALREADY solved (thank you) and are NOT asks:
- **env for the run** — `env(K,V)` inside a test builder reaches the run via
  `_env_export_prefix(_builder)` (rust/python/ruby/go verified). Must be inside
  the builder block, not top-level.
- **loud-skip when a toolchain is absent** — `prereq("python:3")` etc. skips
  cleanly. (Where a binding needs a *finer* skip than a bare tool check, see
  dotnet below.)

## Gap 1 — no dist/package builder for 14 of our 18 languages

Only ruby (`gem`), python (`package`/`wheel`), rust (`cargo package`/crate) and
dotnet (`pack`) have a package builder. These have **none**, so their `.dist.ae`
must shell out to produce the language's artifact:

| language | wanted artifact | today |
|---|---|---|
| go | module tarball (sources + vendored .so) | `tar` shell-out |
| dart | package tarball (+ vendored .so) | `tar` shell-out |
| lua | rock / module tarball | shell-out |
| nim | nimble package tarball | shell-out |
| zig | module tarball | shell-out |
| erlang | OTP app tarball (priv/ .so) | shell-out |
| elixir | hex package (`mix hex.build`) | shell-out |
| gleam | package tarball | shell-out |
| kotlin | jar (over java classes) | shell-out |
| groovy | jar | shell-out |
| clojure | jar | shell-out |
| pharo | source tarball (+ vendored .so) | shell-out |
| php | composer package tarball (+ vendored .so) | shell-out |
| haskell | `cabal sdist` tarball | shell-out |

A common shape: build/collect the package, optionally vendoring a native `.so`
into it (the way `java.package_jar`'s `native_resource` and `ruby.gem`'s gemspec
`files` glob do), and publish it on a `*_dir`/artifact edge. For the tar-only
ones a generic "package a staged tree into a tarball, with a native_resource
setter" builder would cover most.

## Gap 2 — no canonical "collect a built artifact into a monorepo dist dir"

Each package builder writes into its own module's `target/dist/`. The monorepo
wants every binding's artifact in one root `target/dist/`. There's no canonical
way to copy a node's published artifact up: a collector node can't
`dep_artifact` the node it *is*, and a separate collector node per binding is
heavy. A `copy.file`/`copy.tree` that resolves a **dep'd artifact path** as its
`from(...)` (not just a source-relative path) would do it.

## Gap 3 — dotnet: no builder for a `dotnet run` console test app; SDK-vs-runtime skip

Our dotnet conformance suite is a **console runner** (`dotnet run --project
test/PhoneNumber.Tests.csproj`), a plain-Main program that prints checks — not a
`dotnet test` (xUnit/NUnit `[Test]`) project. `dotnet.test_existing()` runs
`dotnet test`, so it can't run our runner; there's no `dotnet.run_project()`
equivalent. (Same shape as java: we deliberately use a plain `main` runner, no
JUnit — java has no jar-run builder either, we hand-roll the `java …
ConformanceTest` invocation.) A `run_project()` / `run_existing()` builder that
does `dotnet run --project <csproj> -c <cfg>` with env() would let this go
canonical.

Also: our node distinguishes **`dotnet` present as an SDK** from **runtime-only**
(`dotnet --list-sdks | grep -q .`) and skips the runtime-only case — a finer
check than `prereq("dotnet")`. A `prereq("dotnet-sdk")` (or a
"requires-buildable-SDK" prereq) would preserve that.

## Gap 4 — dart test-count parser mis-reads '-' in test names as a failed count

`_parse_dart_test_counts` (lib/dart/module.ae) reads the last `-N` marker in
`dart test`'s output as the failed count. With the default **expanded** reporter,
each passing test prints its own line — and a test *name* containing a hyphen
("15 parse trunk-prefix strip", "31 as-you-type", "type enum round-trips its
codes") carries a `-` the parser matches. Result: a suite that passes (`dart
test` exits 0, the SDK prints "tests PASSED", rc marker 0) is recorded with a
bogus failed count, and aeb's aggregate reports the node FAILED and exits 1 —
**node exit 1 while its own rc marker is 0**, a false failure.

Workaround that keeps the node canonical: `test_flag("--reporter=failures-only")`
suppresses per-test lines, so only the summary remains and the parser is clean.
But the parser should be robust to hyphens in test names on the default reporter
(anchor the `-N` match to the summary line's ` +N -N:` shape, not any `-` in the
stream) — or the builder should default to a reporter it can parse
unambiguously.

## Gap 5 — groovy: skip_below_groovy/skip_below_jdk don't catch an incapable toolchain

Our groovy binding compiles against and LOADS the Java binding's classes, which
are JDK 22+ FFM bytecode (class file version 66+; on JDK 24 it's 68). Debian's
system groovy is 2.4 on JVM 17 (class file 61) and **cannot read them** —
`groovyc` dies with `UnsupportedClassVersionError`. Our shell-out node's
`run-tests.sh` probes for a *capable* toolchain by actually compiling AND running
a probe against the real classes, and SKIPs (exit 77) when only an incapable
groovy is present.

Converting to `groovy.groovyc_test() { skip_below_groovy("4") skip_below_jdk("22")
… }` does NOT reproduce that: with system groovy 2.4 present, the skip did not
fire and the build ran groovyc under 2.4 → `UnsupportedClassVersionError`, 30
errors, node FAILED. So `skip_below_groovy` / `skip_below_jdk` either don't detect
the system groovy's version, or check the declared version without checking the
JVM the groovy actually runs on / whether it can load the dep classes. A skip
that verifies the toolchain can actually load the compile-classpath (or at least
correctly reads groovy 2.4's version and the running JVM) is needed for this to
go canonical. Same concern likely applies to kotlin_test / clojure.test loading
FFM-era dep classes on an old runtime.

## Also seen: node exits 1 while its own rc marker is 0 (stale test-result state)

Twice during conversion, a node whose body returned 0 (rc marker 0, its own log
printing PASS) was reported `FAILED: 1 target` by aeb, exit 1 — because a prior
run's `_record_test_result(ctx, passed, failed)` with a nonzero failed count
lingered in `target/` and overrode the node's actual success. Clearing
`target/tests/<lang>` + the node's rc/ms markers fixed it. The recorded
test-count should not outlive / override the node's own return code across runs
(and dart Gap 4 is the same family: a bogus recorded failed-count fails a node
that returned 0).

---

Filed from libphonenumber-ae; more cases may be appended as the conversion
proceeds through the remaining bindings.
