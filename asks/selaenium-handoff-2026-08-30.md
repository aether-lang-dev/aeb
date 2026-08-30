# Handoff from the Selenium-on-Aether port (selaenium) — 2026-08-30

The `paul-hammant/selaenium` port drove a lot of aeb SDK growth this week
(binding-node grammar migration + consumer packaging/install proofs across 24
languages). Everything below is committed to `origin/main` and green in
selaenium's own runs, but three concrete bugs and a test-coverage gap are for
you. Thanks for the parallel work already — your `6d5e5f4` (cmd-test coverage
for ruby/php/kotlin/groovy/erlang + a new haskell test) and `2b6552d` (asks
triage) closed the earlier round.

## 1. BUG — `map.get`-string interpolation renders a raw pointer

**Symptom:** interpolating a string value read from a builder map with
`x, _ = map.get(_builder, "key")` sometimes renders the **raw pointer** instead
of the string. Concretely, in a `consumer_example` builder:

    mode_env, _ = map.get(_builder, "mode_env")   // set to "SEL_MODE" by a setter
    one = "... env -u FOO ${mode_env}=${a} ..."    // rendered: env -u FOO -1210327568=ffi

The `-1210327568` is the pointer. `env` then fails with `invalid option -- '1'`.
`string.concat(mode_env, "")` did NOT fix it, and `string.length(mode_env)` on
the same value fails to COMPILE (`incompatible pointer type` to `string_length`)
— yet the identical pattern in `_zig_of` (`z, _ = map.get(...); if
string.length(z) > 0`) compiles and works. So it's value/context-dependent, not
a blanket rule.

**Repro:** any builder that reads a scalar string via `map.get` and then either
`${interpolates}` it into a command or calls `string.length` on it. Compare a
working case (`_zig_of`) with a failing one (the dropped `mode_env` in
`lib/zig/module.ae` / `lib/lua/module.ae`, git history around commit `30d8bbe`).

**Workaround shipped:** selaenium dropped `mode_env` and passes the value through
a shell wrapper in the node instead (`run_cmd("sh -c 'SEL_MODE=\"$1\" bin' _")`),
so the string never crosses the interpolation boundary. But the root cause is an
aeb string-lifetime/interpolation issue worth fixing — it will bite any SDK that
reads a scalar string from the builder map and interpolates it.

## 2. BUG — `aeb-resolve.jar` is not installed by `make install`

**Symptom:** `$AEB_HOME/tools/aeb-resolve.jar` is missing after `make install`
(it's excluded from `INSTALL_TOOLS`), so maven-dep resolution silently emits
`warning: no maven jars resolved` and the dependent build fails downstream
(java: `package org.junit.jupiter.api does not exist`; scala:
`ClassNotFoundException: dotty.tools.dotc.Main`).

**Impact:** breaks java + scala (any maven-dep binding) on every fresh
`make install` — I had to re-`rsync` the jar from a build tree repeatedly this
session. Fix: add `tools/aeb-resolve.jar` to the install manifest so it lands in
`$AEB_HOME/tools/` like the other tools.

## 3. BUG — `dotnet.test` / `dotnet.test_existing` don't thread block `env()`

**Symptom:** a block-level `env("SELENIUM_CORE_LIB", path)` on `dotnet.test()`
(and `test_existing()`) does not reach the `dotnet test` **test-host** process
(Release), so a P/Invoke binding hits `DllNotFoundException`. The C# binding is
proven correct: `SELENIUM_CORE_LIB=<path> dotnet test` passes 7/7 when the env
is set in the shell manually. Both builders DO call `_env_export_prefix` and the
env()/`_env_export_prefix` pair agree on the `proc_env` key — so the export
reaches the `dotnet test` invocation but not the spawned test host. Likely
`dotnet test`'s Release test-host doesn't inherit the exported env the way the
build step does.

**Workaround:** selaenium's F# node stages the .so into `native/` + a fsproj
`CopyToOutputDirectory` so the C# NativeLoader's `native/`/BaseDirectory search
finds it without env; the C# node still relies on env (and shows the failure in
a cold full-presubmit run). Worth aligning `dotnet.test`'s env-to-test-host so
block `env()` is honored uniformly (same family as the earlier
`test_existing`-env note).

## 4. COVERAGE — new SDKs + consumer_example builders lack cmd-test coverage

This session added (all committed `origin/main`):

- **New SDKs:** `lib/lfe/module.ae` (LFE), `lib/julia/module.ae`,
  `lib/crystal/module.ae` — NONE have a `tests/test_<lang>_cmd.ae` (unlike the
  ones you covered in `6d5e5f4`).
- **New builders on existing SDKs, all UNtested in the suite:**
  `python.package_existing` (setup.py + wheel_dir), `ruby.package` (gem_dir),
  `java.package_jar`, `javascript.pack`, and **`<lang>.consumer_example`** in
  python/ruby/javascript/java/rust/go/dart/nim/zig/lua (10 of them — the rust
  one carries the generic `stage`/`stage_dir`/`run_cmd`/`pre_cmd`/`mode_env`/
  `assert_file` setters the others were derived from).
- `erlang.link_engine`/`run_main`/`test_source`/`pa`, `kotlin.jvm_args`,
  `groovy.run_script`, `php.ini`, `ruby.minitest`, `haskell.link_dir`/`target`,
  `swift` loud-skip gate — the pure command-builder halves are testable like the
  `6d5e5f4` batch.

Same treatment as `6d5e5f4` would be ideal: `tests/test_{lfe,julia,crystal}_cmd
.ae` for the new SDKs, and cmd-tests for the pure helpers in the new builders
(e.g. `_hs_lib_flags`, `php_ini_part`, the consumer_example staging-manifest
assembly).

## Context

selaenium is at: engine + 24 bindings all green (grammar migration COMPLETE),
transparent driver management, Grid-over-HTTPS, the native Aether client, and a
proven-live WebDriver-BiDi transport (shape C demux, concurrent, through the C
ABI). It leans on aeb for every binding's build/test/package/example node, so
aeb correctness directly gates selaenium's presubmit.

---

## Triage (aeb side, 2026-08-30)

### #1 map.get pointer interpolation — CANNOT REPRODUCE on current ae; likely an already-fixed Aether codegen bug

Investigated on `ae 0.596.0`. Built five faithful reconstructions of escalating
fidelity — plain map.get→interpolate; pre-declared "" then conditional reassign;
loop with `${mode_env}=${a}`; inside a `builder` fn reading `_builder`; and the
FULL shape (builder + local var name-shadowing the `mode_env` setter + `has_`
flag + args loop). **All compiled and rendered the string correctly** (`SEL_MODE=ffi`,
never a pointer). Then compiled the ACTUAL pre-30d8bbe `lib/lua/module.ae`
verbatim (git show 30d8bbe^) — **compiles clean, no `incompatible pointer type`.**
Note `string.length(mode_env)` never appears in the real code; it was a debug
probe. The `map.get(_builder,…)`→interpolate pattern is used in 38 lib builders
and the suite is 127/127, so it is not broadly broken.

Conclusion: this reads as an Aether **compiler/codegen** bug (string value from
map.get mis-typed as ptr in some context) that was **live on the toolchain the
30d8bbe session used but is fixed by 0.596** — not an aeb bug, and nothing to fix
in aeb. The `sh -c` workaround shipped in 30d8bbe is harmless to keep; `mode_env`
could be restored + retested on a current `ae` if the cleaner form is wanted. If
it recurs on a specific `ae`, capture that exact `ae --version` + the minimal
failing snippet and it becomes a precise Aether ask — but it doesn't repro here.

### #3 dotnet env → test-host — CANNOT REPRODUCE on .160 (dotnet 10, Linux); shell export DOES reach the Release test-host

Built a P/Invoke repro on the cachyos box (dotnet 10.0.111): a native
libtestengine.so + a net10 xUnit test that loads it, and ran `dotnet test -c
Release --no-build` three ways:
  1. no env → DllNotFoundException (baseline confirmed).
  2. `export TESTENGINE_LIB=<path> && dotnet test` (exactly aeb's
     _env_export_prefix path) → **PASSED 1/1** — the Release test-host DID
     inherit the exported env.
  3. `dotnet test -- RunConfiguration.EnvironmentVariables.KEY=val` → also passed.
Repeated with the fragile classic case — a PLAIN `[DllImport("testengine")]`
by soname relying on LD_LIBRARY_PATH inheritance (not a SetDllImportResolver
callback): shell export ALSO passed. So on current tooling the block env()
reaches the test host uniformly; the reported failure does not reproduce.

Conclusion: not reproduced, and aeb's existing shell-export already works
here. Did NOT add `-- RunConfiguration.EnvironmentVariables` to the dotnet
builder — it would be complexity for an unreproducible failure and the
finicky `--` RunSettings syntax risks breaking the working export path. IF a
repro can be pinned (capture: exact `dotnet --version`, OS, the csproj's
`<UseAppHost>`/runsettings, whether `dotnet test` detaches the host), the
RunConfiguration.EnvironmentVariables injection is the known fix and I'll add
it gated behind that evidence. The selaenium F# node's native/ + CopyToOutput
staging workaround is fine to keep meanwhile.

### #2 aeb-resolve.jar / Maven-install coupling — COMPILE-SEVER LANDED (mvn no longer needed to COMPILE the resolver)

Root cause: the jar is (correctly) gitignored and was built out-of-band via
`mvn dependency:build-classpath` (chicken-and-egg: Maven to build the Maven
resolver). We do NOT check the jar in. Instead, since compile only needs
symbols not behavior, tools/resolver/stubs/ now holds 38 hand-written
empty-body Java stubs (the "headers") for the org.eclipse.aether.* /
org.apache.maven.* compile surface — `javac` builds the resolver with NO mvn,
NO jars (verified exit 0, -Xlint:all clean). Committed as the proven
compile-sever (54796ab). The full mvn-free BUILD (shade still needs the real
impl) is the scoped follow-up: compile against stubs → rm the stub .class from
the out dir → shade the real impl (fetched by coordinate from Central). The
earlier reclaim-loop wipe was already fixed (908e582); `cp -R tools` installs
the jar when present. Net: a fresh tree will build the jar with a JDK alone
once the shade-sourcing lands.

### #4 coverage — DONE for the new SDKs + consumer_example (extract-then-test)

The new SDKs (lfe/julia/crystal) and consumer_example assembled their commands
INLINE in the builder — nothing pure to unit-test 6d5e5f4-style. Extracted the
command assembly into pure helpers (behavior-preserving, byte-identical) and
added std.spec cmd-tests:
  - crystal: crystal_spec_cmd + _crystal_of + setters (tests/test_crystal_cmd.ae)
  - lfe: lfe_run_cmd + setters (tests/test_lfe_cmd.ae)
  - julia: julia_script_cmd + _julia_of + setters (tests/test_julia_cmd.ae)
  - consumer_example: consumer_run_cmd + consumer_run_arg_cmd + 6 setters
    (tests/test_consumer_example_cmd.ae)
All builders now call the extracted pure helpers (same bytes as before). The
other consumer_example langs (python/ruby/js/java/go/dart/nim/zig/lua) derive
from the rust generic; extracting/​testing each is the same mechanical pass if
wanted, but the generic helper + its test now cover the assembly logic.

---

## UPDATE (2026-08-30, later): #2 SUPERSEDED — resolver now runs on bld, no mvn at all

The stub/fetch/shade path above was a dead end (java.shade can't fat-jar a
classpath_file classpath; the resolver .dist.ae was also broken by JDK-24
drift). Replaced wholesale: aeb-resolve is now an ~8 KB thin shim
(tools/resolver/BldResolve.java) over Geert Bevin's bld (com.uwyn.rife2:bld) —
one self-contained 2 MB jar with its own lean Maven resolver, ZERO runtime
deps, no logging framework. Commits c32a5be (cutover) + 7fdea75 (flatten).
lib/maven + aeb-sbom invoke it unchanged (thin jar's Class-Path manifest finds
bld alongside). Verified: junit → 8 jars (compiles a real @Test),
spring-boot-starter → 20 managed jars, --bom parent/property inheritance,
sbom mode. Build needs only JDK + curl. Old MavenResolver.java, pom.xml, and
the 38 stubs are retired. Further pure-Aether resolver tracked in
docs/plans/aether-maven-resolver-todo.md.

A follow-up attempt to rewrite the resolver's .dist.ae in aeb's own java DSL
(jar_pinned + javac + a new thin_jar verb, instead of shell string.concat) was
parked: it needs a small java-SDK fix (javac reading a node's OWN accumulated
jar_pinned jars) + no_module_info for bld's automatic-module, and the thin_jar
attempt tripped a NAME COLLISION (its `jar_name` param shadowed the existing
java.jar_name() setter → interpolated the function pointer, not the string) —
a self-inflicted naming bug, NOT an Aether compiler bug. The working imperative
.dist.ae stays for now.
