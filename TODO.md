# Aether Build — TODO

## SDK function configuration

Today every SDK function takes just the context — zero config, pure convention:

```aether
build.javac(b)
build.kotlinc(b)
build.go_build(b, "c-shared", "libgonasal.so")
```

Three levels of configuration, progressively more expressive:

### Level 1: Zero config (done)

Convention handles standard layouts. No args needed.

```aether
build.javac(b)
```

### Level 2: Named args

Common overrides as named parameters. No trailing block needed.

```aether
build.javac(b, source: "17", target: "17")
build.kotlinc(b, jvm_target: "17")
build.go_build(b, mode: "c-shared", output: "libgonasal.so")
build.cargo_build(b, lib: "libvowelbase.so", profile: "release")
build.shade(b, main_class: "com.example.Main", output: "app.jar")
```

### Level 3: Trailing block DSL

Full control via Aether's `_ctx` invisible context injection — the same
mechanism as `sandbox() { grant_fs_read(...) }`.

```aether
build.javac(b) {
    source_version("17")
    target_version("17")
    annotation_processor("lombok")
    extra_flags("-Xlint:all", "-Werror")
    encoding("UTF-8")
}

build.kotlinc(b) {
    jvm_target("17")
    api_version("1.9")
    extra_flags("-Werror")
}

build.go_build(b) {
    mode("c-shared")
    output("libgonasal.so")
    flags("-ldflags", "-s -w")
    env("CGO_ENABLED", "1")
    tags("netgo")
}

build.cargo_build(b) {
    lib("libvowelbase.so")
    features("jni", "serde")
    profile("release")
    extra_flags("--jobs", "4")
}

build.tsc(b) {
    strict(true)
    target("ES2022")
    module_kind("NodeNext")
}

build.junit(b) {
    includes("**/*Tests.class")
    excludes("**/*IntegrationTests.class")
    jvm_args("-Xmx2g", "-ea")
    parallel(true)
    timeout(300)
}

build.mocha(b) {
    timeout(5000)
    reporter("spec")
    grep("unit")
}

build.shade(b) {
    main_class("com.example.Main")
    output("app.jar")
    exclude("META-INF/*.SF", "META-INF/*.DSA")
    relocate("com.google.common", "shaded.guava")
}
```

Each setter stores config in the `_ctx` map. The SDK function reads
the map after the block runs and translates to compiler flags.

### Implementation plan

1. Named args first — add optional parameters to existing SDK functions.
   `javac(ctx, source, target)` with defaults. Quick, no language changes.
2. Trailing block second — requires the SDK function to accept a block,
   run it to populate a config map, then use the config. Uses Aether's
   existing builder DSL + `_ctx` injection.
3. Each config setter is a function with `_ctx: ptr` as first param
   (invisible injection): `source_version(_ctx: ptr, ver: string)`.

## Runner improvements

### Full Aether CLI entrypoint (replace the bash trampoline)

The user-facing `aeb` command is currently a bash script
(`#!/usr/bin/env bash`): it parses flags, resolves `AEB_HOME`, does the
synonym/`:name` and `--scan`/`--vet` arg handling, lazy-builds the helper
tools, sets the process group, and only then hands off to the compiled
`aeb-main`. That bash front-end is the one piece of aeb that is NOT
Aether — and it pins the whole CLI to a bash-bearing platform (Linux,
macOS, WSL, Git-Bash), with no native Windows/PowerShell story.

**Goal:** a full Aether equivalent of the bash CLI — a compiled `aeb`
entrypoint that does everything the trampoline does today, so bash is no
longer on the critical path.

**Status (2026-06-14): the pure-Aether entry point is LIVE for the core path
+ --sandbox / --init / --use-remote-agents (see DONE list below); the bash
trampoline is still the installed `aeb` on every OS (no cutover yet).** The
remaining work is a short list of exec-handoffs + the cutover, not a missing
primitive. Earlier decision (2026-06-10) was "hedge — keep bash for now"; the
upstream blocker has since cleared. The flag-parsing / env-setup /
lazy-build-dispatch bulk ports cleanly; the one piece bash did well for free
was the *build-supervision tail* (own process group via `set -m`, forward
INT/TERM to the group, timeout watchdog TERM→KILL, group-reap leaked
daemons). That gap is now **closed upstream**: `std.os` gained
`os.run_supervised(prog, argv, env, new_process_group, forward_signals,
timeout_secs, reap_group) -> (exit_code, outcome)` — exactly the bash pattern
— plus `os.kill` (negative-pid groups, `sig 0` probe), `os.wait_pid_timeout`,
and `std.signal` constants. Landed in ae 0.231.0; the installed toolchain is
now 0.235.0 (it was 0.230 mid-session — already bumped). See
`../aether/aeb-process-supervision-primitives.md` and the worked reference
`../aether/examples/applications/build-supervisor.ae` (the bash trampoline
tail as one `run_supervised` call). **So the native entrypoint is no longer
blocked — it's now scheduling, not a missing primitive.** **`run_supervised`
is CROSS-PLATFORM** (CHANGELOG 0.231): the same call uses POSIX process groups
*and* Windows Job Objects (`TerminateJobObject` for timeout/signal,
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` for the leaked-daemon reap), so the
Windows arm has FULL parity — no degrade, no hand-rolled taskkill. (Earlier
notes here said "POSIX-only, Windows degrades" — that was the stale state in
the ask doc's status line; the shipped 0.231 went further. Corrected.) Also
landed and useful: `os.getcwd`/`os.chdir` (now used by `aeb-cli` instead of a
`pwd` shell-out), `os.run_full` (separate stdout/stderr + stdin feed),
`ae run <file> -- <args>` arg forwarding. (NB: the trampoline is ~635 lines
now, not the "~50-line thin trampoline" older notes claim.)

**Progress — the entire argv grammar is now ported, pure + tested, in
`tools/aebcli/module.ae`** (75 assertions across
`tests/test_aebcli_synonym.ae` + `tests/test_aebcli_parse.ae`). The bash
loop's hardest-to-test bulk is now pure Aether:
- `classify_target` / `synonym_dir|name|relpath|fqn` — the `*:*` / `*:*:*`
  classification (plain / synonym / coordinate) + `.name.ae` resolution + the
  `aeb synonym match:` FQN echo. **Windows-correct:** a leading drive prefix
  is stripped before the synonym colon is counted, so `C:\proj` classifies as
  a plain target (the bash `[[ "$a" == *:* ]]` mis-reads it as a synonym) —
  this is the drive-letter disambiguation item 4 below needs.
- `flag_spec` / `flag_known` / `flag_env` / `flag_takes_value` /
  `flag_implies` — the full 22-flag table (10 boolean + 12 value, with the
  `--sbom-json`→resolve-only / `--veto-policy`→vet / `--sandbox-profile`→
  sandbox implications) as pure data.
- **`parse_argv(argv) -> directive list`** — the whole flag loop as a pure
  interpreter. Consumes raw argv, emits ordered tab-separated directives the
  entrypoint executes: `env\tNAME\tVALUE`, `env-append\tNAME\tVALUE` (the
  accumulating `--vet-tool`), `arg\tVALUE`, `synonym\tRELPATH\tFQN`,
  `error\tCODE\tMESSAGE` (terminal — the bash exits on first error). Covers
  the value-flag next-arg consume, the implies-relations, `--timeout` numeric
  validation, coordinate/empty-name/missing-arg errors, and unknown-flag
  passthrough.

**The compiled entrypoint exists and runs — `tools/aeb-cli.ae`.** The impure
executor that interprets parse_argv's directives is written and verified
end-to-end (compiles clean; exercised across flags, the implies-relations, the
accumulating `--vet-tool`, plain + synonym targets with the file-check + `aeb
synonym match:` echo, and the coordinate/timeout/missing-arg/missing-synonym
errors with correct exit codes). It also does `--version` (AEB_STAMP parsed via
the pure `stamp_field`, incl. multi-word values), `AEB_HOME` resolution (env
override else `_dirname(argv[0])` — native, no `dirname` shell-out), and the
podman `DOCKER_HOST` autodetect (POSIX-gated).

**DONE (shipped on main) — the entry point's core path is live:**
- **The supervision tail** — execs aeb-main under
  `os.run_supervised(prog, argv, env, 1, 1, timeout, 1)` (own process group,
  INT/TERM forward, `--timeout` TERM→KILL → exit 124, group-reap). One call,
  the whole tail. CROSS-PLATFORM (POSIX groups / Windows Job Objects). Phase-1
  A/B passes identical to bash (commit `12e4471`). `tools/aeb-cli.ae:270`.
- **`--sandbox` arm** — prepends the `aeb-sandbox` wrapper (commit `873f5c4`).
- **`--init` mode** — lazy-builds + execs aeb-init (commit `9327eae`).
- **Abs-path + file-existence** for the synonym relpath (file-check + the
  `aeb synonym match:` echo) is in the executor.
- **`--use-remote-agents` → aeb-remote** — lazy-build + hand off original argv
  (commit `17b773f`). Ported first because we now run aeb-agent for real.

**What remains for the entrypoint:**
- **The other exec handoffs** — `gcheckout` / `--watch` / `--resolve-only` /
  `--trace-intent` each lazy-build their helper tool and exec it. (`--init` and
  `--use-remote-agents` are done; these four follow the same shape.) Note
  `--resolve-only` / `--trace-intent` also have a *gate* in bash (emit SBOM /
  trace, DON'T build) — port that branch too.
- **Abs-path + file-existence** for the `--agents` / `--veto-policy` /
  `--sandbox-profile` VALUES (parse_argv leaves these as plain `env`
  directives; the bash `cd`s to resolve them absolute and checks the file
  exists — move that into the executor, using native `_dirname`/`_path_join`).
- **Cutover** — once the above land, replace the bash `aeb` with a thin shim
  that just execs the compiled `aeb-cli` (or a per-OS launcher). Recommend
  flag-gating first (`AEB_NATIVE_CLI=1` opts in) to dogfood before flipping the
  default. Native-Windows still gated on aether#681 (`${...}` interpolation),
  but POSIX cutover is unblocked.

Why it's worth doing:
- **Portability.** A compiled entrypoint runs anywhere Aether targets,
  including native Windows — at which point the `:`-in-target /
  drive-letter (`C:`) disambiguation becomes a real (small) concern to
  handle in the resolver, not a moot one. (Now handled in `aebcli`.)
- **Single language.** The CLI's arg grammar (flags, `path/to:name`
  synonym resolution + the `aeb synonym match:` FQN echo, `--scan
  '<glob>'` requiring a glob, `--vet`/`--veto-policy`, `--since`/`--scan`/
  `--shard` narrowing, `--watch`, `gcheckout`, `--init`) would live in
  one typed, testable Aether program instead of split across bash + the
  compiled tools. Today the bash layer is effectively untested.
- **Self-hosting.** aeb building its own front-end closes the loop.

Things the bash layer does that the Aether port must preserve:
- `AEB_HOME` resolution + the stale-install note (Makefile-stamped).
- Lazy-build of helper tools (`aeb-main`, `aeb-link`, `scan-ae-files`,
  `extract-deps`, `topo-sort`, `aeb-vet`, etc.) — first-run compile.
- Process-group / `set -m` job control so a build's whole subtree
  (orchestrator → builders → spawned procs) is reaped together.
- The podman-socket `DOCKER_HOST` auto-detect for TestContainers.
- `exec`-style handoffs (`--watch`, `gcheckout`, `--init`,
  `--use-remote-agents` → `aeb-remote`).

Open question: a thin bash shim may still be wanted purely as the
`#!`-launchable file on Unix (it would just `exec` the compiled aeb),
while the real logic moves into Aether. Decide whether the shim stays or
a platform-native launcher replaces it per-OS.

### Windows support (cut-down runner)

**Goal:** `aeb` runs natively on Windows in a *reduced* mode — enough to
build/test the languages whose toolchains are first-class on Windows (the
JVM family, .NET, Go, Rust, Node, Python), with the POSIX-only features
(`--sandbox`, `--watch`, container/podman lifecycle, group-reap) explicitly
gated off rather than silently broken. Not "full parity" — a *cut-down* that
is honest about what it can't do on Windows.

**Why it's plausible now, not aspirational:**
- Aether itself has a Windows backend, and key pieces are genuinely
  cross-platform, not stubs — e.g. `os.run_supervised` (Windows Job Objects),
  `os.getcwd`/`os.chdir` (`GetCurrentDirectory`/`SetCurrentDirectory`), and
  `os.platform()` (compile-time OS string; see host-detection note below).
  Some surfaces remain POSIX-only (e.g. the `--sandbox` LD_PRELOAD path) and
  those are the ones to feature-gate (item 5).
- **`${...}` interpolation now works on native Windows** (CHANGELOG
  `[current]`, #681): MinGW64's MSVCRT printf made the two-pass
  `_aether_interp` sizing collapse to an empty buffer, so every interpolated
  `println` in `tools/aeb-cli.ae` (`${aether}`, the launch plan, error
  messages) printed *empty* on Windows. Fixed upstream by binding the printf
  family to the C99 `__mingw_*` impls. No aeb change — but it means the native
  entrypoint's output is actually usable on Windows now.
- **CHANGELOG scan 2026-06-13 (aether 0.245–0.247):** the aeb-relevant item is
  **#701 module-level globals (0.247.0)** — it un-blocks the top-level-counter
  pattern I'd wanted for the chokepoint temp names, but my content-hash
  workaround is fine, so it's a future nicety, not action-now. The
  int-shift/narrowing fixes are codegen-internal, not aeb-facing.
- aeb *already* branches by OS at its lowest layer: `aeb-link` has an
  inlined `_is_macos_link()` for the GNU-ld-only `--allow-multiple-definition`
  flag, and `lib/build` carries `_host_os()` returning `"windows"`. Both now
  read the compile-time **`os.platform()`** (ae 0.202+) instead of shelling out
  to `uname -s` — which matters because `uname` does not exist on a *native*
  Windows host (the old shell-out only worked under MSYS/MinGW and silently
  fell back to "linux" on real Windows, mis-driving every OS gate). So the
  conditional-by-OS shape exists and is now native-Windows-correct; Windows is
  a third arm, not a new mechanism.

**Foundation laid (this session, Linux-safe — all return 0 off-Windows):**
- `lib/build`: `_is_windows()` / `_is_linux()` (alongside existing
  `_is_macos()` / `_is_freebsd()`), `_host_os()` (normalised token),
  `_exe_suffix()` (`.exe` on Windows), `_default_cc()` (gcc/cc/MinGW), and
  **`_path_sep()`** (`;` on Windows, `:` elsewhere) — the classpath-join
  separator every JVM SDK needs — and **`_has_windows_drive_prefix()`** (the
  `Prefix::Disk` rule for item 4, ported from Nushell's nu-path). Locked by
  `tests/test_platform_helpers.ae` (cross-platform invariants: exactly one
  `_is_*` fires and agrees with the token; `_path_sep`/`_exe_suffix`/
  `_default_cc` track the host; drive-prefix accept/reject cases).
- `lib/build`: **native path helpers** `_path_is_sep` / `_basename` /
  `_dirname` / `_path_ext` / `_path_join` / `_path_to_slashes` — Windows-
  correct (on Windows both `/` and `\` are separators; dual-separator rule
  ported from Nushell's nu-path) and trailing-sep-stripping like coreutils.
  These are the canonical path ops SDKs should use instead of shelling out to
  `dirname`/`basename` or rolling a `/`-only `dirname_pure`. Locked by
  `tests/test_path_helpers.ae` (29 assertions). First conversion done:
  `_resolve_aether_dir` dropped its `dirname $(command -v …)` shell-out for a
  native `_dirname` (verified byte-identical to the old pipeline).
- **Host detection moved off `uname -s` to `os.platform()`** (ae 0.202+) in
  all three sites: `lib/build._host_os()` (+ `_is_macos()` folded onto it),
  `tools/aeb-link._is_macos_link()`, and `tools/aeb-sandbox`'s Linux-only
  containment gate. Compile-time, never-fails, and correct on a native Windows
  host where `uname` is absent (the old shell-out fell back to "linux" there).
  Also removes three coreutils shell-outs per the native-over-coreutils rule.
  `_host_os()` still returns this module's historical `"macos"` token (maps
  `os.platform()`'s Go-spelling `"darwin"`). Locked by the existing
  `tests/test_platform_helpers.ae` token-agreement assertions.
- Linux-green against `./tests/run.sh` (99/99).

**Reference: Nushell** (`../nushell`, MIT, shallow clone). A mature
Windows-first shell in Rust — high-value comparison for these exact seams.
Findings written up in `docs/windows-cross-platform-notes.md` (attribution in
`NOTICE`). Takeaways: (a) its drive-letter handling = Rust std's
`Prefix::Disk`, now ported as `_has_windows_drive_prefix` (item 4); (b) the
dual-separator path rule, ported into the lib/build path helpers above.
(Its process-supervision approach — skip groups on Windows, shell out to
`taskkill` — is NOT aeb's path: Aether's `os.run_supervised` gives
cross-platform group-reap via Job Objects. Kept as context in the doc.)

**Work items (in rough dependency order):**

1. **Native entrypoint is the gate.** Windows has no bash, so the cut-down
   runner *requires* the native Aether entrypoint above (no longer blocked —
   see the supervision note). The supervision tail is one cross-platform
   `os.run_supervised` call: on Windows it runs the build in a Job Object with
   group-reap, so the Windows arm has FULL parity (not the spawn-and-skip-reap
   degrade earlier notes assumed). `tools/aeb-cli.ae` already resolves the
   launch; the remaining work is the single `os.run_supervised` call to exec
   aeb-main. (Historical note: Nushell skips groups on Windows and shells out
   to `taskkill /F /T` precisely because Rust std hands it no group primitive;
   aeb has `os.run_supervised`, so it doesn't take that path — see
   docs/windows-cross-platform-notes.md §1–2 for the comparison.)

2. **Classpath separator → `_path_sep()`.**
   **Leaf joins DONE.** All five JVM SDKs' runtime `-cp` assembly now routes
   through the shared **`build._cp_append(cp, part)`** helper (conditional join
   on `_path_sep()`, tested in `tests/test_platform_helpers.ae`) instead of
   `string.concat(cp, ":")` — `lib/{java,kotlin,scala,groovy,clojure}`. Byte-
   identical on Linux (suite 104/104); Windows-correct shape. The maven-
   coordinate split `string.split(coord, ":")` (java) was correctly left as
   `:` (it's a `g:a:v` coordinate, not a path list).

   **NOT yet functional on Windows** — the leaf joins are necessary but not
   sufficient, because the cross-module classpath *plumbing* still hardcodes
   `:` and shells out to coreutils. Remaining (the chunk that makes Windows
   classpaths actually work; also overlaps item 6's coreutils removal):
   - `build._build_dep_classpath` reads the `jvm_classpath_deps_including_
     transitive` artifact via shell `echo | tr '\n' ':' | sed` and joins with
     hardcoded `:`. → native newline-split + `_cp_append`.
   - **Artifact format is inconsistent**: java/clojure/groovy write that
     artifact newline-separated (via `tr ':' '\n'`); scala writes it
     `:`-joined directly. Unify to a canonical newline-separated on-disk form
     read natively (newlines are platform-neutral; convert to `_path_sep()`
     only at the `-cp` boundary).
   - `maven.classpath(ctx)` returns a `:`-joined classpath → `_path_sep()`.
   - groovy `_nl_to_colon` / `_colon_to_nl` (shell `tr`) → native + `_path_sep()`.
   - classpath SPLITs once producers emit `_path_sep()`: scala
     `string.split(full_cp, ":")`, clojure `string.split(maven_cp, ":")`.
   - `ld_path` joins in lib/java (the `LD_LIBRARY_PATH` native-lib search path,
     2×) — POSIX-specific; on Windows native libs resolve via `PATH` (`;`).
     Separate from classpath; handle with the native-lib-path story.
   - Reminder (item A / WSL2): `_path_sep()` is host-based as a proxy for the
     toolchain target — correct for native-Win+Win-JDK and Linux/WSL2+Linux-JDK,
     wrong only for the WSL2→Windows-`java.exe` boundary (out of scope).

3. **`.exe` suffix on built binaries. DONE.** Native-binary outputs append
   `build._exe_suffix()` (".exe" on Windows, "" else) so the recorded/executed
   path matches what MinGW gcc / `go build` / cargo actually emit:
   - `lib/c` already did it (`c.program`).
   - `lib/aether`: `program` / `program_test` / `driver_test` binaries (the
     `.c` intermediate stays unsuffixed).
   - `lib/rust`: the `cargo_binary` artifact (crate name → always suffixable).
   - `lib/go`: `go_build` output, but ONLY when the name has no extension (a
     bare exe) — a shared-lib output (`libfoo.so`/`.dll`) keeps its extension;
     the `.so`↔`.dll` cross-platform naming is a separate concern.
   - `tools/aeb-link`: the composite `_ae_build_all` binary (suffixed once so
     the `-o`, the per-node exec, and the aeb-driver call agree).
   Byte-identical on Linux (suffix == ""); suite 104/104.
   Not covered (separate concern): cross-platform **shared-library** extension
   (`.so`/`.dylib`/`.dll`) for the FFI handoff SDKs (go c-shared, rust cdylib,
   the JNI `.so`s) — that's its own item, not the `.exe` one.

4. **Path / drive-letter handling in the resolver.** The `path/to:name`
   target-synonym grammar collides with Windows `C:\...` drive letters. The
   native entrypoint's arg parser must disambiguate (a lone drive letter is
   not a `:name` suffix). **Helper now in place:**
   `build._has_windows_drive_prefix(s)` (lib/build) implements the
   `Prefix::Disk` rule (single letter + `:` + sep-or-end), ported from
   Nushell's nu-path — call it *before* splitting a `:name` synonym. **Now
   wired:** `tools/aebcli`'s `classify_target` / `synonym_*` strip the drive
   prefix before counting the synonym colon, so `C:\proj` classifies as a
   plain target and `C:\a\b:build` still resolves as a synonym (tested). What
   remains: route the entrypoint's actual synonym-split through `aebcli`
   (replacing the bash loop), and the `/`-vs-`\` path-join normalisation
   (`build._path_to_slashes` exists; apply it on input). Known limitation: the
   rare drive-*relative* `C:name` form (no separator) is treated as not-a-drive.
   (NB: `aebcli` keeps its own copy of the drive rule, not `import build`, to
   dodge the two-level transitive qualified-symbol compiler bug — consolidate
   when that's fixed upstream.)

5. **Feature-gate the POSIX-only capabilities with a clear message.** On
   Windows, `--sandbox` (LD_PRELOAD seccomp-shaped), `--watch` (inotify/
   fswatch), the container/podman lifecycle steps, and group-reap should each
   fail-fast with "unsupported on Windows (cut-down runner)" rather than a
   cryptic missing-tool error. One gate helper reading `build._is_windows()`.

6. **The 47-file coreutils dependency is the deep blocker.** ~47 SDK/tool
   files shell out to POSIX coreutils (`find`, `sed`, `awk`, `tr`, `cut`,
   `sha256sum`, `dirname`, `mktemp`). A native Windows shell has none of
   these. Two strategies, not mutually exclusive:
   - **(A, pragmatic) Bundle a busybox/POSIX layer.** Ship/require a busybox
     or Git-for-Windows `usr/bin` on PATH so the shell-outs resolve. Fastest
     to a working cut-down; keeps aeb dependent on a POSIX shim.
   - **(B, going-forward) Rewrite shell-outs in native `std.string`.** Each
     `sed`/`tr`/`cut`/`dirname` shell-out replaced with `std.string` /
     `std.fs` is one fewer Windows dependency and one less fork on *every*
     platform. This is the **going-forward rule** (see below) — new SDK code
     prefers native ops; the existing 47 get converted opportunistically.
     A module is "Windows-native" once it has zero coreutils shell-outs.
     **Existence proof: Nushell's `nu-command`** reimplements `ls`/`str`/
     `path`/etc. as native Rust rather than shelling out — a Windows shell
     replaces coreutils with library calls, exactly strategy (B) at scale.
     **Started:** `lib/build` now ships native `_basename`/`_dirname`/
     `_path_ext`/`_path_join` (the path-manipulation slice of the coreutils
     surface). Remaining `dirname`/`basename` shell-out sites to convert onto
     them: `lib/bash` (4×), `lib/dotnet` (2×), `lib/go`, `lib/ts`,
     `lib/container`, `lib/angular`. Also the drifting `_dirname` copies in
     `tools/{aeb-query,affected-targets,gcheckout}` + `tools/aeblabel`'s
     `dirname_pure` (all `/`-only) should consolidate onto these once a
     tools→lib import path exists (today tools import `aeblabel`, not `build`).

7. **Symlink fallback already works.** `aeb --init` materialises
   `.aeb/lib/<name>`; on platforms without symlink privilege it already
   falls back to copying. Windows (without Developer Mode) is the same case —
   no new work, just verify.

**Going-forward rule (applies to ALL new SDK code, not just Windows work):**
Prefer native `std.string` / `std.fs` over POSIX-coreutils shell-outs. A new
builder that needs to split a string, trim, replace, or compute a dirname
should use the stdlib, NOT `os.exec("sed ...")` / `tr` / `cut` / `dirname`.
Rationale: every coreutils shell-out is (a) a Windows portability blocker,
(b) a per-call fork cost on every platform, and (c) a quoting/injection
surface. The existing 47 shell-out sites are grandfathered and converted
opportunistically (item 6B); new code starts native.

**Honest status:** unstarted beyond the platform-detection foundation +
this plan. Cannot be tested from the Linux dev box — every change must stay
Linux-green (the new predicates return 0 off-Windows; `./tests/run.sh` is the
guard). Real verification needs a Windows box with the JVM/.NET/Go toolchains
installed. Lower priority than the native entrypoint it depends on.

### Target filtering (done)

`aeb <target>` builds only the named target and its transitive deps.

```bash
aeb java/applications/monorepos_rule          # just this + deps
aeb javatests/components/vowelbase            # auto-detects test
aeb --dist java/applications/monorepos_rule   # compile + package
```

### ~~`scan()` grammar function — glob-based dep discovery~~ (done)

`build.scan(b, "<glob>")` lives in lib/build/module.ae. Static
extraction is wired in tools/extract-deps.ae (alongside the
existing dep() needle). The runtime side calls fs.glob and
forwards each match through dep() so cargo/npm/maven
classification works transparently. Tests in
tests/test_extract_deps_scan.ae (6 assertions, fixture-tree
based — first one of its kind alongside test_aether_resolvers).
README documents it under "Affected-target detection" as the
declarative complement to `--scan`.

What's NOT implemented from the original sketch:
- **`.aebignore` respect**: scan() expansion currently ignores
  the same .aebignore file that scan-ae-files reads. Low priority
  — most users want their tests/builds/dists picked up regardless
  of the global ignore list, and scan patterns are explicit
  enough that the user's intent is clear. Revisit if a real
  porter hits the gap.
- **Multi-pattern scan() in one call**: today's signature is
  one pattern per call. Users compose by writing N scan() lines.
  Could add `scan_all(b, "p1", "p2", ...)` if a real consumer
  needs it; not asked for yet.

### Parallel execution

Independent modules in the DAG can build concurrently. The visited map
needs thread-safe access (mutex or atomic). Aether actors are a natural
fit — one actor per module, message-passing for completion.

### ~~Affected-target detection~~ (done)

Shipped via `aeb --since <ref>` and `aeb --print-affected <ref>`.
Walks reverse-dep edges from changed-file owning targets. Source-
to-target ownership rule: nearest enclosing directory with a
dot-prefixed `.ae` build file. Multiple build files in one dir
all share ownership of source files in that dir (the round-218
multi-binary case).

Useful CI shape: `aeb --since main` (or `--since origin/main`)
runs only the targets affected by the PR's changes. Telemetry
shows what built; cache integration ensures hits stay hits even
when the broader CI pipeline rebuilds something else.

**TODO: `--since` is Git-only today.** The changed-files list comes
from a hard-coded `git diff --name-only <ref>` shell-out in
`tools/aeb-main.ae` (~line 489). Only that one step is VCS-specific
— everything downstream (owning-target resolution, reverse-dep DAG
walk, `--scan` / `--shard` narrowing) is VCS-agnostic and works
off a plain changed-paths list. Other VCS could be added by
detecting the repo type and swapping the diff command:
`hg status --rev <ref>` / `jj diff --name-only` / `svn diff
--summarize`, etc. The clean shape is a small `_changed_files(ref)`
helper that picks the command by repo type (probe for `.git` /
`.hg` / `.jj` / `.svn`), feeding the same `_changed.txt` the
affected-targets tool already consumes — no change to the walk.

### Local content-addressed cache (done across all artifact SDKs)

`lib/cache/` ships sha256+zlib content-addressable storage under
`$AEB_CACHE_DIR` (default `~/.aeb/cache`). Wired into every
artifact-producing SDK:
- `lib/maven` — resolved classpath
- `lib/aether` — manual-path link binary
- `lib/java` — javac + javac_test classes trees (tar+zlib)
- `lib/kotlin` — kotlinc + kotlinc_test classes trees (stdlib jar hashed)
- `lib/scala` — scalac + scalac_test classes trees (compiler-cp hashed)
- `lib/ts` — tsc out-dir tree (excludes `*.tsbuildinfo`; non-empty guard
  so a project tsconfig that redirects output never false-hits)
- `lib/dotnet` — `bin/<config>` only (never `obj/`); test projects are
  not cached (`dotnet test --no-build` needs `obj/`)
- `lib/go` — `go_build` output binary/.so (single-file; lower value, go
  has its own cache)
- `lib/rust` — `cargo_build` / `cargo_project` cdylib (single-file, gated
  on `lib_name`; lower value, cargo has its own cache)
- `lib/clojure` — AOT `classes/` tree (main_ns branch only)

`lib/python` is deliberately NOT cached (venv non-portable; pip already
skips satisfied installs) — see the `lib/python` module header. The one
future-cacheable surface is the `python.package` wheel.

Each SDK's cache wiring is the same shape: hash inputs (sources +
classpath/manifest + flags + toolchain version) → probe `cache.get` →
restore artifact on hit, run on miss → `cache.put`. Shared helpers
(`_tar_dir`, `_untar_into`, `_read_argfile_lines`, `_dir_nonempty`) live
in `lib/build`; see `lib/java` (tar tree) and `lib/aether` (single file)
for the reference implementations. Each SDK ships a pure
`_cache_key_for_<sdk>` covered by `tests/test_<sdk>_cache.ae`.

Remaining: end-to-end hit/miss verification on Linux (the macOS ld64
duplicate-symbol issue blocks full `./aeb` links), and the remote cache
layer below.

### Remote build cache (filesystem backend done; HTTP/S3 next)

The next layer up from local caching: share artifacts across
machines (Bazel, Gradle, Nx, Turborepo all do this). Implementation:
hash inputs → check remote store → download artifacts or build locally
→ upload result.

**Done — shared filesystem backend.** `lib/cache` now consults a shared
remote *behind* the local store, transparently (no SDK changes — every
SDK already calls `cache.get/put`). Read path: local hit → else pull the
blob from the remote into the local store → else miss. Write path: write
local → push the blob to the remote. The remote holds the SAME
zlib-compressed sha256-sharded blobs, so local and remote are
interchangeable CAS. Config: `AEB_REMOTE_CACHE_URL` = `file:///abs/path`
(a plain path also works) — an NFS mount, a shared CI volume, a
bind-mount; the equivalent of Bazel `--disk_cache` / Buck2 disk cache.
`AEB_REMOTE_CACHE_MODE` = off|read|write|readwrite (default readwrite
when a URL is set; CI runners `write`, dev machines `read`). Every
remote op is best-effort — a remote failure never fails the build.
Covered by `tests/test_remote_cache.ae` (config core) and
`tests/test_remote_cache_roundtrip.ae` (two simulated machines sharing a
remote: put on A → get on a fresh B via the remote, byte-identical).

**Next — HTTP/S3 backend.** Add an `http(s)://` backend behind the same
`_remote_pull`/`_remote_push` seam (the scheme is already recognised and
currently no-ops). Use `std.http.client` GET/PUT/HEAD with a bearer
token (`AEB_REMOTE_CACHE_TOKEN`); the one thing to verify on a working
toolchain is binary-safe blob download (the blobs contain NULs).
S3/GCS/a tiny CAS server then all speak the same GET/PUT/HEAD-by-sha256
shape.

**Direction & policy:** [`docs/distributed-cache-plan.md`](docs/distributed-cache-plan.md)
captures the design framing — repeatability vs reproducibility,
Wingerd-style named scopes (mainline / development / release / task)
with explicit promotion gates, container-vs-content artifact classes.
The doc proposes a 5-step sequencing that backs into CDC (below) as
a later layer.

#### Content-Defined Chunking (CDC) — a later layer, but it shapes the format now

Prior art: BuildBuddy's "Remote Cache CDC: Reusing Bytes" (May 2026)
— Bazel 8.7 / 9.1+ `--experimental_remote_cache_chunking`. The idea:
don't cache a large output as one indivisible blob. Run a rolling
hash over it (FastCDC), cut at content-defined boundaries, store each
chunk as its own content-addressed entry plus a small reconstruction
record keyed by the whole-blob digest. A small source change then
re-transfers/-stores only the chunk(s) it perturbed. BuildBuddy
reports ~85% byte dedup on chunk-eligible writes (blobs > 2 MiB;
20–40% across all traffic). Read/write split: `SplitBlob` (fetch the
chunk layout, pull only missing chunks) / `SpliceBlob` (push missing
chunks + the reconstruction record).

Why it matters for aeb specifically:

- **It is the byte-level partner of the `c889f25` import-closure
  key.** That key (correctly) busts every consumer's cache entry
  when a widely-imported module changes — so a `repo_storage`-shaped
  edit re-caches N near-identical consumer binaries. Correct
  invalidation + CDC = consumers still rebuild, but the restoring
  near-identical artifacts cost only their changed chunks. The
  big-transitive-output actions CDC targets (linking, packaging) are
  exactly aeb's `aether.program`, `java.shade`, driver-test binaries,
  container images.

- **One design constraint binds NOW, before any CDC work: chunk the
  *uncompressed* bytes.** CDC needs byte-level similarity across
  revisions; a compressed stream loses it — a small input change
  rewrites much of a `.gz`. aeb's `lib/cache` is sha256 **+ zlib**
  whole-blob, and `lib/java` caches the classes-tree as **tar+zlib**.
  Compress-then-store is the CDC anti-pattern. If CDC is ever wanted,
  the cache format must be chunk-first, then compress per chunk (or
  not at all) — never chunk a `.tar.gz`. Worth keeping the door open
  even though CDC itself is far off.

Sequencing: CDC is a *layer on* the remote cache, not step 1. Order
is (a) remote CAS + backend protocol + auth, (b) CDC on top —
`lib/cache` is already a local content-addressed store, so chunks
slot in as ordinary CAS entries. Honest status: aeb is ~6 months in;
remote cache itself is unstarted. CDC is recorded here as prior art
and as the one constraint (uncompressed chunking) that affects cache
format decisions made before then.

### ~~Build graph visualization~~ (done)

Shipped in commit `be2d97c`. `aeb --graph` (DOT default) /
`aeb --graph mermaid` for inline-Markdown output. Pipe DOT to
`dot -Tsvg` or paste Mermaid into a `\`\`\`mermaid` fence.

### ~~Watch mode~~ (done)

Shipped via `aeb --watch [target]`. Watches source dirs derived
from the current edges file (sparse-checkout-aware: only dirs
that exist on disk get watched, so gcheckout co-existence is
clean). Linux uses inotifywait; macOS uses fswatch. Change
events flow through `--changed-paths-from` → affected-targets →
narrowed rebuild. Debounce: 200ms.

Composes with everything that just shipped: cache makes warm
rebuilds fast, telemetry shows `[hit]`/`[miss]`/`<P>/<T> PASS|FAIL`
per target, the affected-target walk skips unchanged targets.

What might be follow-up:

- **Sparse-checkout dynamism**: today the watch list is computed
  once at start. If `aeb gcheckout add foo` materialises new dirs
  while a watch is running, those new dirs aren't picked up until
  the user restarts the watch. Tracked: detect changes to
  `.git/info/sparse-checkout` and rebuild the watch list.
- **Per-target dirs vs per-source patterns**: today a recursive
  watch on each target's dir catches all changes. Some SDKs (Java
  with `source_layout("maven idiomatic")`) might want narrower
  scopes (`src/main/java/**` only, not `target/**` or `node_modules/**`).
  Today's exclude list (`target`, `.aeb`, `.git`) covers the
  common feedback loops; add more as needed.

### User-defined builders

Currently all builders live in `lib/*/module.ae` shipped with aeb.
Users should be able to define project-local builders in their own
`.ae` files without forking the SDK. A `local_lib/` directory
alongside `.aeb/lib/` that the compiler searches first.

### Lockfiles for reproducible dep resolution

Maven/NuGet/npm versions can shift between builds (ranges, snapshots,
latest). A `dep.lock` file recording exact resolved versions ensures
reproducible builds. The resolver already computes the full closure —
just needs to write it out and check it on subsequent runs.

### Build telemetry (partially done)

Per-module wall-time + cache outcome rendered as a `[telemetry]`
block at the end of every build. The orchestrator (generated by
`tools/gen-orchestrator.ae`) records (label, type, wall_ms, cache)
per module into an in-memory list and hands it to
`build.render_telemetry` for the stdout renderer.

Cache outcomes wired in every artifact-producing SDK (`lib/aether`,
`lib/java`, `lib/maven`, `lib/kotlin`, `lib/scala`, `lib/ts`,
`lib/dotnet`, `lib/go`, `lib/rust`, `lib/clojure`); `lib/python` reports
`n/a` by design (see its module header).

Test-result outcomes (per-target pass/fail counts) wired across
all test builders:
- `bash.test` — exact counts (already tracked internally)
- `java.junit5` — parses `[N tests successful]` / `[N tests failed]`
- `java.junit` — parses `OK (N tests)` / `Tests run: N, Failures: F`
- `jest.test` — parses `N passed, M failed` from summary line
- `python.pytest` — parses `N passed, M failed` and `N error`
- `dotnet.test` — parses `Passed: N, Failed: M`
- `aether.program_test`, `go.go_test`, `rust.test`,
  `rust.test_workspace`, `kotlin.kotlin_test`, `clojure.test`,
  `scala.munit`, `ts.mocha` — coarse 1/1 success or 0/1 failure
  (per-test count parsing is a follow-up per SDK as consumers
  ask for it)

The `[telemetry]` block now shows test rows with a
`<passed>/<total> PASS|FAIL` trailer alongside the existing
`[cache]` annotation: `test: foo  3.03s [n/a] 17/17 PASS` or
`test: bar  5.40s [hit] 28/30 FAIL`.

What's left:

- **More cache integration → better telemetry**: each SDK that
  grows `cache.get`/`cache.put` integration also gets honest
  `[hit]`/`[miss]` reporting in telemetry for free.
- **Alternative renderers**: file dump (JSON, JSON Lines) for CI
  consumption; HTML/JS for a richer view (force-directed graph
  with node sizes by wall-time, colors by cache outcome). The
  records list is the single source of truth; renderers walk
  it without modifying.
- **Cross-build aggregation**: "what's our cache hit rate over
  the last 100 builds?" Needs persistent storage (per-build
  telemetry file under `target/_aeb/` or central `~/.aeb/log/`).
  Postpone until a real consumer asks.
- **Per-builder timing inside an SDK**: today telemetry sees
  per-target wall-time. Inside `aether.program(b)`, regen vs
  aetherc vs gcc isn't separated. Useful for SDK profiling;
  needs each SDK to emit phase markers. Defer.

#### Telemetry — the four-tier vision

Today's implementation is the degenerate case of a much larger
shape. As aeb grows parallel module execution, multi-process
worker fan-out, and remote build, the telemetry channel evolves
through four tiers. Each tier is its own session of work; the
*data model* is forward-compatible across all four (records can
gain fields without breaking renderers), but the *transport*
between informer and consumer must change at each step.

A node informs the graph "I started" and later "I ended,
extra-info...", with arbitrary other informers writing
interleaved between. The data model captures that explicitly
with two-sided events:

```
{ kind: "start", label: "ae/myserver:seed", at_ns: ..., type: "build" }
{ kind: "end",   label: "ae/myserver:seed", at_ns: ..., cache: "hit", ... }
```

The current "records" shape (one map per completed module) is
the synchronous fold of those events: start arrived → in-progress,
end arrived → record completed. When transport stays single-
process synchronous, folding can happen at append time and the
events are never materialised (today's case).

##### Tier 0 — single process, synchronous (DONE)

In-memory list, records appended as each module finishes, lost
on exit. The orchestrator (one process) is the only writer. No
synchronization needed. What this commit ships.

##### Tier 1 — single process, multi-thread

Triggered when aeb grows parallel module execution (already on
the TODO under "Parallel execution"). Multiple worker
threads/actors build independent DAG branches concurrently.

Transport: a `TelemetryActor` owns the records list. Workers
`send Started{label,...}` / `send Ended{label, cache, ...}`.
No locks; message-passing is the synchronization. Aether's
actor model is the natural fit.

Inflection point: the records→events refactor lands here. The
TelemetryActor's mailbox IS the event stream; it folds events
into records as messages arrive, hands the records to the
existing `render_telemetry` at session end. Renderer signature
unchanged.

`clock_ns()` is monotonic and meaningful between threads on the
same host (sub-microsecond drift). Wall-time semantics survive.

##### Tier 2 — multi process, same machine

Triggered when aeb spawns subprocess workers (e.g. parallel
`aetherc`/`javac`/`gcc` invocations from `tools/aeb-link.ae`,
or per-target subprocess fan-out). All workers share the
filesystem and the wall clock.

Transport: append-only file log at `target/_aeb/telemetry.jsonl`.
Each subprocess opens the file in `O_APPEND` and writes one
event per line. POSIX guarantees writes ≤ PIPE_BUF (4096 bytes
on Linux, 512 minimal POSIX) are atomic against concurrent
writers; events fit comfortably. No locks, no coordination.
Standard practice — Bazel BES, Buck2, Nx Cloud all use
append-only logs.

Workers find the log via env var (`AEB_TELEMETRY_LOG=...`)
inherited from the orchestrator. The orchestrator reads the
log post-build, folds events to records, hands to the renderer.

`clock_ns()` is monotonic per-process. Cross-process timing is
accurate to ~microseconds (different processes have their own
monotonic baselines). For "what's slow?" this doesn't matter.

##### Tier 3 — multi machine / VM / container

Triggered when aeb grows remote build execution. Workers run
on different hosts. No shared filesystem, no shared clock.

Transport: a network-reachable telemetry sink. Industry
standard is Bazel's Build Event Stream (BES) — gRPC streaming
of protobuf events, well-defined semantics for incomplete
builds, reusable consumers (BuildBuddy, EngFlow). Don't roll
own; adopt BES when the time comes.

Each event gains identity discriminators: `host`, `pid`, `tid`,
container/VM ID. The records→events refactor from Tier 1 means
adding fields is a no-op for renderers (they ignore unknown
keys).

Clock skew is real: cross-host timing requires either NTP-bound
wall-clock with accepted skew, or logical clocks (Lamport,
vector). Per-host monotonic order is preserved; cross-host
causal ordering is the harder problem. BES sidesteps by
standardising on UTC wall-clock with skew tolerance.

Backpressure: if the sink is slow or unreachable, workers can't
block on inform. Local buffer + async flush + drop-on-overflow
counter (Bazel's pattern).

##### Forward-compatibility checklist

The current Tier 0 implementation should not lock decisions
that constrain Tiers 1-3. Status:

- ✓ Records are `map<string, string>` (open-ended; can grow
  fields like `host`, `pid`, `cache`, `exit_code` without
  changing the renderer signature).
- ✓ Renderer takes a list and a total — same shape as
  events-folded-to-records will produce in Tier 1+.
- ✓ Cache markers are per-target files, readable across
  process boundaries — already Tier 2 compatible (a worker
  subprocess writing the marker is observable to the
  orchestrator parent).
- ✗ The events shape is not yet a thing. Tier 1's records→
  events refactor IS the event-protocol introduction. ~50
  LOC of orchestrator + actor + renderer; defer until the
  parallel-modules feature drives it.

##### Where each tier's preconditions live

| Tier | Blocked on | Estimated session work |
|---|---|---|
| 0 → 1 | Parallel module execution (TODO above) | ~half-session, riding the parallel-modules feature |
| 1 → 2 | Subprocess fan-out in aeb-link or per-SDK | ~half-session, tied to whichever feature spawns subprocesses |
| 2 → 3 | Remote build execution + BES adoption | Multi-session; the telemetry transport piece is the smaller part |

### Code coverage — per-language SDK wiring

Today `aeb --coverage` is a cross-cutting CLI flag (set as
`AEB_COVERAGE=1` env by the trampoline, every SDK reads it if it
knows what to do). Wired in `lib/aether/` only:

- shell-out path: appends `--coverage` to `ae build` (Aether
  0.115 feature; injects `gcc --coverage` and forces `-O0 -g`)
- manual path: swaps `-O2` for `-O0 -g --coverage` in the gcc
  command emitted by `aether_link_cmd`
- cache key segregates coverage from non-coverage builds

Each non-aether language has its own native coverage flow —
none yet wired to honor the aeb-side flag. Per-SDK follow-up:

- **java.junit5 / java.junit**: JaCoCo. Add `-javaagent:jacocoagent.jar=destfile=target/<mod>/jacoco.exec`
  to the JVM args. User runs `java -jar jacococli.jar report ...`
  to render. Bounded — one javaagent flag, one extra classpath
  download or maven coordinate for the agent jar.
- **jest.test**: `jest --coverage`. One flag.
- **python.pytest**: `pytest --cov=<src>`. Or wrap with `coverage run -m pytest`.
- **dotnet.test**: `dotnet test --collect:"XPlat Code Coverage"`.
  Drops .coverage files; `reportgenerator` renders.
- **go.go_test**: `go test -coverprofile=target/<mod>/cover.out`.
  Built-in.
- **rust.test / rust.test_workspace**: `RUSTFLAGS="-C instrument-coverage"`
  + `LLVM_PROFILE_FILE=...` env vars, or `cargo-llvm-cov` if
  installed. Per-rustc-version variation.
- **scala.munit**: scoverage compiler plugin. Different shape.
- **kotlin.kotlin_test**: usually JaCoCo (JVM-shared).
- **clojure.test**: cloverage.
- **ts.mocha**: nyc / c8.

Cross-cutting render: aeb does not render; users delegate to
gcovr/lcov/jacococli/reportgenerator/etc. per language.

### Cross-compilation targets

Building for a different OS/arch than the host. Relevant for Go
(`GOOS=linux GOARCH=arm64`), Rust (`--target aarch64-unknown-linux-gnu`),
.NET (`-r linux-arm64`). DSL: `target_platform("linux-arm64")`.

### Hermetic dependency pinning

aeb currently trusts whatever version the resolver returns. For
production builds, pin every transitive dep to an exact version with
integrity hashes (like `package-lock.json` or `go.sum`). Detect drift
between lock file and resolved deps.

### Toolchain selection & generated locks (partially done)

Design: `docs/toolchain-selection-and-locks.md`,
`asks/versioned-bom-and-self-validating-lock.md`. Subsumes the
"Lockfiles" section above (that lock should be the *generated*,
hash-stamped node described here) and is the multi-SDK half of the
"uses whatever's on PATH" gap.

**Done:**
- Generic version-match / selection / `lock_validate` core in `lib/build`
  (`_match_major_version`, `_select_jvm_home`, `_jvm_dir_major`,
  `_toolchain_not_found_msg`, `lock_validate`); `tests/test_toolchain_select.ae`.
- `lib/java`: `java.select_jdk("21" | "21+")` — discover-select-or-fail
  among installed JDKs, end-to-end verified on a multi-JVM box.

**Deferred — could NOT verify on the dev Chromebook (single version /
SDK wholly absent). Implement + verify on a box that has alternates:**
- **`python(...)` / `ruby(...)` runtime selection.** The generic core is
  done; the per-SDK setter + discover-select-or-fail is not. This box has
  only Python 3.11 and Ruby 3.1 — no second version to *select between*,
  so only the "use the one present" and "fail for a missing version"
  paths are testable here. Needs a box with e.g. pyenv 3.11+3.12+3.13 /
  rbenv multi-Ruby to verify a real pick. CRITICAL difference from Java
  (do not copy Java's semantics): the interpreter version is part of
  wheel/gem identity (`cp312` ABI), so `python(...)` must feed the
  wheel-resolution cache key and a version bump must re-resolve — NOT an
  orthogonal axis the way `select_jdk` is. See the fidelity-asymmetry
  table in the design doc.
- **`_ensure_venv` hardcodes `python3` from PATH** (`lib/python`). Until
  `python(...)` lands, every Python build is silently bound to PATH's
  interpreter and nothing records which version built the venv. The fix
  is version-tagged venvs (`.aeb/venv-py312`) driven by the selected
  interpreter.
- **`.NET` selection + anything dotnet-shaped is unverifiable here —
  `dotnet` is wholly absent on this box.** `lib/dotnet` exists but the
  SDK-version-selection story (global.json-style pinning / multiple
  installed SDKs) was never exercised. Verify on a box with the .NET SDK
  (ideally multiple) installed.
- Other multi-version-capable toolchains worth a selection setter once
  the pattern is proven: Go (multiple `go` via gvm/asdf), Node (nvm),
  Rust (rustup toolchains). All would reuse the generic `lib/build` core;
  each is orthogonal-vs-entangled per its own dep model (Node/npm ≈
  entangled like Python; Go/Rust ≈ mostly orthogonal like Java).

**Lock generator — produce side (the consume side `lock_validate` is
done + tested):**
- A versions BOM node (`pip_versions.ae` / `gem_versions.ae`; Java reuses
  the existing `.bom.ae`) + a generator target `aeb .<lang>_make_lockfile.ae`
  that resolves the closure *for the BOM's runtime* and emits a generated
  lock node carrying `generated_from("<bom>", "sha256:…")` + `locked_for("<tag>")`
  + the closure. The lock self-validates on visit (re-hash the BOM,
  hard-fail on drift / missing / runtime-mismatch), so a consumer deps
  the lock alone. Expressed as an embedded content hash, NOT a `dep()`
  edge, so the consumer needn't also dep the BOM. Generic mechanism in
  `lib/build`; SDKs provide a `<lang>.make_lockfile` builder.

## Aether compiler issues to fix upstream

- [x] **0.146 regression: `string.substring` return aliased + outer
      reassign-to-`""` corrupts the alias.** Fixed in 0.147.0
      (ownership-transfer logic at the reassignment-wrapper, see
      `../aether/CHANGELOG.md` § [0.147.0]). Cleared three of the
      four downstream failures (`test_brew`, `test_telemetry_render`,
      `test_affected_targets`).
- [x] **0.147 regression: `list.add` of a heap-string alias doesn't
      count as escape.** Fixed upstream — 0.149.0 cleared the
      escaped-LHS-alias source flag, and 0.151.0 replaced that with a
      full ownership transfer (heap flag moves on alias). See
      `../aether/CHANGELOG.md` §§ [0.149.0] (Regression A) and
      [0.151.0]. `test_java_cache` passes on 0.161.0; the defensive
      `string.concat(x, "")` copies in `tools/gcheckout.ae`'s
      dep-walk loop were removed (verified with a dep-chain run).
- [x] **0.147 regression: tuple-destructure reassign of a
      string-interp variable double-frees at function exit.** Fixed
      upstream in 0.149.0 — the destructure-wrapper-emission gate now
      fires whenever the LHS is heap-tracked, regardless of the
      destructure position's type, freeing the prior heap value and
      treating the non-string position as a borrow. See
      `../aether/CHANGELOG.md` § [0.149.0] (Regression B).
      `test_pyproject_content` passes on 0.161.0.
- [x] **0.146 regression: bare `_` is a single type-bound variable,
      not a per-use fresh discard.** Fixed upstream (aether `[current]`
      / post-0.162.0) — filed via `aeb-ae-help-and-toolchain-feedback.md`
      #4. `_` is no longer registered as a symbol; each occurrence is
      an independent discard and a plain `_ = <expr>` lowers to
      `(void)(<expr>)`. The `_status` workaround at
      `tests/test_cache.ae` was reverted to bare `_`.
- [ ] `module` as a variable name silently breaks codegen — should be
      a reserved word or the codegen should handle it
- [ ] Module function return type inference fails when first `return`
      is a literal `0` — infers `int` instead of `ptr`. Workaround:
      return `map_get(m, "_null_")` to force ptr type.
- [x] `MAX_MODULE_TOKENS` was 2000, needed 20000 for the build SDK.
      (Fixed: bumped to 20000 in `aether_module.h`)
- [x] Module function return types not inferred across module boundaries.
      (Fixed: `lookup_symbol` → `lookup_qualified_symbol` in `typechecker.c`,
       with void/unknown guard to avoid regressing pure-Aether return types.
       Regression test added: `tests/integration/module_return_types/`)
- [ ] `const char*` vs `void*` warnings on every `map_put`/`list_add`
      call. The codegen should emit casts for `string` → `ptr` params.
- [ ] **macOS link step fails with duplicate symbol errors.** Root
      cause: the Aether compiler emits imported module functions (e.g.
      `rust_cargo_build`, `build__mkdirs`) into every translation unit
      without a `static` qualifier. GNU ld silently dedupes them via
      the `-Wl,--allow-multiple-definition` flag currently hard-coded
      in `tools/aeb-link.ae:294`. That flag is GNU ld only — Apple's
      ld64 rejects it, and `-multiply_defined,suppress` was removed in
      Xcode 15. Consequence: a full `./aeb` multi-module run fails
      with duplicate-symbol errors on macOS.
      Two fixes, in order of preference:
      (1) **Upstream compiler fix** — `compiler/codegen/` should either
      mark imported module functions `static` so each TU gets a private
      copy, or emit each function exactly once with `extern` declarations
      in the callers. This is the root-cause fix and unblocks macOS for
      every downstream tool, not just aeb.
      (2) **Local workaround in `aeb-link.ae`** — platform-gate the
      link flag so Linux keeps `-Wl,--allow-multiple-definition` and
      macOS drops it. Useful for small builds that happen to not have
      duplicate symbols, buys time until (1) ships.
      Until this is fixed, macOS users can run the unit tests
      (`./tests/run.sh`) but `./aeb` itself cannot link full builds.
- [ ] `maven.classpath` resolution fails when a test file imports
      `java` (which imports `maven`). Reproduces on `test_javac_cmd.ae`,
      `test_junit_cmd.ae`, `test_kotlinc_cmd.ae` via `./tests/run.sh`.
      Likely a qualified-symbol resolution issue across two levels of
      module imports.
- [x] **`ae help` library hint files (`*.help.md`) were stdlib-only.**
      Fixed upstream (aether `[current]` / post-0.162.0) — filed via
      `aeb-ae-help-and-toolchain-feedback.md` #1+#2. `ae help` now
      accepts `--lib` and `find_help_md_path` probes each `--lib`
      entry's `<name>/` dir. aeb now ships hint files:
      `lib/bash/bash.help.md`, `lib/aether/aether.help.md`,
      `lib/build/build.help.md`. They ride inside the module dirs, so
      `aeb --init`'s `.aeb/lib/<name>` symlinks carry them to consumer
      repos automatically — no `shipped_modules()` change needed.
- [ ] **`ae help` still reports project-library calls as undefined.**
      Even with `--lib lib`, `ae help` on a `.build.ae` flags
      `build.start` / `bash.script` etc. as `undefined function` —
      the `*.help.md` hints fire correctly alongside, but the output
      is signal + noise. Likely the same transitive qualified-symbol
      resolution gap as the `maven.classpath` item above. Filed as a
      follow-up in `aeb-ae-help-and-toolchain-feedback.md`.

## Build environment validation

Run before any module builds. Fail fast with install hints.

```aether
build.env(b) {
    tool("javac", ">= 21")
    tool("kotlinc")
    tool("go", ">= 1.24")
    tool("rustc", ">= 1.78")
    tool("cargo")
    tool("tsc")
    tool("node")
}
```

## Per-task sandboxing (phase 2)

Whole-build runtime containment shipped — `aeb --sandbox` runs the build
under Aether `spawn_sandboxed` (LD_PRELOAD, deny-by-default grants, no tcp;
contains the whole gcc/cc1/javac subtree at the libc boundary). See
docs/build-veto-and-sandbox.md. Phase 2 is the *finer* grain: per-SDK-call
grant profiles instead of one whole-build profile, e.g.

```aether
build.javac(b) {
    sandbox() {
        grant_fs_read("src/**")
        grant_fs_write("target/**")
        grant_exec("javac")
    }
}
```

## Supply-chain veto + sandbox — stack COMPLETE; frontier follow-ups

The veto/sandbox stack (docs/build-veto-and-sandbox.md) is complete and
shipped: the tree & patch rule scan (agent-side), the external-scanner hook
(`--vet-tool`), the AST veto (`--vet`), the dependency SBOM/CVE
(`--resolve-only`), the intent trace (`--trace-intent`), and the runtime
sandbox (`--sandbox`). What remains are *extensions* of shipped capabilities,
not missing layers:

- **SBOM/CVE — more ecosystems.** `--resolve-only` ships the maven slice
  (`aeb-resolve.jar --output sbom`). Add cargo (`.crate.ae`) + npm (`npm:`)
  the same way — an `--output sbom` for those resolvers, merged into the
  emitted JSON.
- **Intent trace — more categories + whole-tree.** `--trace-intent` records
  the `os.*` shell-out surface (the universal chokepoint). Extend the
  doppelganger to also record `dep`/`link_flag`/`std.net` intent; and wire a
  whole-tree `--trace-intent` that walks the DAG (currently per-leaf) via
  orchestrator integration.
- **Agent-side `spawn_sandboxed` wiring.** `aeb --sandbox` ships for the
  non-agent CLI; the *agent* hosting a dispatch under the sandbox per its
  operator profile is still the design seam
  (docs/build-veto-and-sandbox.md / run-policy-class-and-cloud-leverage.md).
- **One-policy-object option (deliberately deferred).** The three operator
  surfaces (veto policy / `--vet-tool` / sandbox profile) are kept separate on
  purpose; a single `policy.ae` driving all three was considered and parked.

## ~~`aeb --init` documentation~~ (done)

Documented in README.

## Trailing-block DSL for remaining languages

All language SDKs now use `defer` functions with trailing-block DSL:

- [x] `javac()` / `javac_test()` — release, source, target, lint, encoding, etc.
- [x] `junit()` — jvm_args, extra
- [x] `kotlinc()` / `kotlinc_test()` — jvm_target, api_version, language_version
- [x] `go_build()` / `go_test()` — build_mode, output_file, tags, ldflags, race, env_var
- [x] `cargo_build()` — lib_name, profile, features, jobs
- [x] `tsc()` — strict, ts_target, module_kind, out_dir
- [x] `mocha()` — mocha_timeout, reporter, mocha_grep

## Platform-branching ergonomics

Aeb is Aether, so `if`/`else` inside `main()` or a closure block is
the working answer to platform-conditional builds today. The
mechanic is fine; the surface is ugly. Example of the current
shape — pick sources + flags by host OS:

```aether
import build
import c
import c (sources, cflag)
import std.os
import std.string

main() {
    b = build.start()
    host = os.getenv("HOST_OS")
    c.compile(b) {
        sources("core.c")
        if string.equals(host, "darwin") == 1 {
            sources("plat_macos.c")
            cflag("-DPLAT_MACOS")
        }
        if string.equals(host, "linux") == 1 {
            sources("plat_linux.c")
            cflag("-DPLAT_LINUX")
        }
        if string.equals(host, "windows") == 1 {
            sources("plat_windows.c")
            cflag("-DPLAT_WINDOWS")
        }
    }
}
```

This isn't Bazel's `select()`. Bazel's mechanic specialises the
target graph at *analysis time* based on a configuration object
(`--config=…`, `--define=…`, platform constraints, `config_setting`
labels). aeb's `if/else` runs every build — functionally
indistinguishable for string-compare-to-literal branching, but
semantically a runtime decision, not a configuration-time one.

Three ergonomic sugar layers, in increasing scope:

### 1. `build.host_os()` / `build.host_arch()` primitives

Hide the `os.getenv("HOST_OS")` dance behind a one-liner accessor
that returns "linux" / "darwin" / "windows" / "freebsd" derived
from `uname -s` (or the existing `os.host_os()` if Aether ships
one) plus the `HOST_OS` env-var override. Cheap; closes most of
the verbosity without inventing any new grammar.

### 2. `when_os("darwin") { ... }` closure-DSL helper

A `lib/build` helper that takes a string + a closure, evaluates
the closure only when the host matches:

```aether
c.compile(b) {
    sources("core.c")
    when_os("darwin") {
        sources("plat_macos.c")
        cflag("-DPLAT_MACOS")
    }
    when_os("linux") {
        sources("plat_linux.c")
        cflag("-DPLAT_LINUX")
    }
}
```

Same runtime behaviour as the raw `if`-block above, much shorter
to read. The implementation is one Aether function plus the host-
OS primitive.

### 3. `select(host, { "darwin": fn, "linux": fn, "default": fn })`

A multi-way switch helper that takes a value + a map of label →
closure-or-value. Closer to Bazel's `select()` surface, still
runtime-evaluated. Useful when the same branch decides multiple
unrelated things (`sources` AND `cflag` AND `link_flag`) and the
`when_os(...)` form would repeat the OS check three times.

What's NOT in scope of any of these three: real configuration-
phase selection. That needs (a) a configuration object the
orchestrator builds before running module functions, (b) a
constraint-solver over platform / `--config` / `--define`,
(c) per-config target-graph specialisation. None of those are
small; none are demanded by any project currently in `itests/`.
File when a real consumer needs it (gRPC, Bazel-migrated
hyperscaler repo, anything with fine-grained platform-conditional
deps).

Selenium's actual platform branching (rust binary local-build
vs prebuilt download, per-OS test variants) is coarse enough
that one `.build.ae` per platform plus the suffix-tag convention
(`.build-linux.ae` / `.build-macos.ae`) covers it without
needing this sugar at all. The ergonomic sugar above pays off
for the *fine-grained inside-one-target* shape, not the
coarse-grained one.

## Test coverage gaps (this session, deliberately deferred)

The round-218 backfill (`tests/test_aether_*.ae`, `tests/test_bash_*.ae`,
`tests/test_file_to_label.ae`) covered the pure string-builders for
this session's SDK additions: `aetherc_emit_lib_cmd`,
`aether_link_cmd`, `bash_xargs_cmd`, `bash_runner_body`, plus the
mtime-driven `_regen_action` and the install-layout resolvers (with
filesystem fixtures). Three behaviours are still uncovered. None
blocks any consumer; all need either a refactor or harness work that
wasn't worth doing in-session.

### `_run_regen_pass` integration

`_run_regen_pass` in `lib/aether/module.ae` orchestrates the full
.ae → _generated.c regen flow: derive paired paths, mtime-check via
`file.mtime`, resolve caps (explicit or auto-detect), invoke real
`aetherc --emit=lib` via `os.system`, append to `extra_source`,
hard-fail on aetherc error.

The pure parts are already factored out (`_paired_generated_c`,
`_regen_action`, `_detect_caps_from_content`, `aetherc_emit_lib_cmd`)
and unit-tested. The orchestration loop itself isn't testable
without either:

- Stubbing aetherc with a recording wrapper script that captures
  args. Doable; needs a small bash fixture under `tests/fixtures/`
  and a per-test PATH override.
- Or extracting a "planner" function that returns a list of
  `(ae_path, c_path, caps, action)` records without invoking
  aetherc, then testing the planner. Simpler but means the actual
  aetherc-invocation loop is still uncovered.

End-to-end smoke (`/tmp/aeb-regen-smoke`) covers the integration
today. Worth formalising into a `tests/integration/` directory if
this gap bites.

### `bash.test` parallel-mode end-to-end

`bash.test(b) { jobs(N) }` writes scratch files (item list, runner
script), invokes `xargs -P` via `os.exec`, parses stdout with
`_parse_xargs_output`. The string-builders (`bash_xargs_cmd`,
`bash_runner_body`) and the parser are unit-tested. The dispatch
loop isn't — would need a fixture tree of `test_*.sh` files plus
a way to assert the resulting parallel runtime ordering, which is
non-deterministic. End-to-end smoke (`/tmp/aeb-bash-smoke`) covers
this today.

### Three-copy `file_to_label` drift detection — RESOLVED

~~The label-derivation logic exists in three places that must stay
in sync.~~ Consolidated. The three former copies
(`tools/file-to-label.ae`, `tools/gen-orchestrator.ae`,
`tools/aeb-link.ae`) now all `import aeblabel` from the single
canonical module `tools/aeblabel/module.ae`. `tests/run.sh` builds
with `--lib lib --lib tools` (multi-entry `--lib`, aether 0.150) so
`tests/test_file_to_label.ae` imports the *same* module the build
path runs — no fourth inlined copy. Drift is now structurally
impossible: there is one implementation. Tool builds thread
`--lib tools` through the Makefile (`AEFLAGS`), `aeb-main`'s
aeb-link build, and `aeb-link`'s gen-orchestrator build.

Consolidation also closed three latent inconsistencies the copies
had drifted into: `gen-orchestrator` classified types with
`string.contains` (vs `ends_with`) and computed dirname via a
`os.exec("dirname ...")` subprocess (vs the pure `dirname_pure`);
`aeb-link` open-coded suffix slicing in `infer_type`.

## Container SDK — Proxmox support

The container module currently supports OCI images (podman/docker) and
LXC containers. Proxmox adds two more backends, both using the same
DSL-setter pattern.

### `container.pct()` — Proxmox LXC containers

Local mode (on the Proxmox host, shells out to `pct`):

```aether
import container
import container (template, hostname, memory, cores, net, storage)

container.pct(b) {
    template("local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst")
    hostname("web-1")
    memory("2048")
    cores("2")
    net("name=eth0,bridge=vmbr0,ip=dhcp")
    storage("local-lvm")
}
```

Generates: `pct create <vmid> <template> --hostname web-1 --memory 2048 --cores 2 --net0 name=eth0,bridge=vmbr0,ip=dhcp --storage local-lvm`

Remote mode (over the wire via Proxmox REST API):

```aether
container.pct(b) {
    host("pve.internal:8006")
    api_token("user@pam!aeb", "token-secret")
    node("pve1")
    template("local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst")
    hostname("web-1")
    memory("2048")
}
```

Generates: `curl -k -X POST https://pve.internal:8006/api2/json/nodes/pve1/lxc -H "Authorization: PVEAPIToken=user@pam!aeb=token-secret" -d 'ostemplate=local:vztmpl/...'`

### Local vs remote convention

The `host()` setter is the boundary. Present → remote API call via curl.
Absent → local CLI. Same DSL setters for the container config either way.
This convention extends to any future backends that have both local and
remote modes.

### Additional Proxmox setters

- `host(addr)` — Proxmox API address (e.g. `pve.internal:8006`)
- `api_token(user, secret)` — PVE API token for auth
- `node(name)` — target Proxmox node
- `hostname(name)` — container hostname
- `memory(mb)` — RAM in MB
- `cores(n)` — CPU cores
- `swap(mb)` — swap in MB
- `disk(spec)` — root disk (e.g. `local-lvm:8`)
- `net(spec)` — network interface config
- `storage(name)` — storage target
- `vmid(id)` — explicit VM ID (auto-assign if omitted)
- `unprivileged()` — create as unprivileged container
- `start_on_create()` — start immediately after creation
- `ssh_key(path)` — inject SSH public key

### `container.qm()` — Proxmox VMs (future)

Same pattern for full VMs via `qm create`. Lower priority — containers
cover most deployment use cases.

### Test approach

Same as other SDKs: test the command string builders (`pct_create_cmd`,
`pct_api_cmd`) in isolation. No Proxmox host needed for tests.

## In-process language hosting via `aeb-link`

`container.run` runs a guest language as a *separate process* (a
container). Aether's other option — `contrib.host.<lang>` (Lua,
Python, Perl, Ruby, Tcl, JS) — embeds the interpreter *in-process*:
the bridge is linked into the binary and the guest runs in its
address space. For aeb that means the guest would run inside the
orchestrator (`target/_ae_build_all`), which is the purest fit for
the one-process model. The container-vs-hosted tradeoff is written
up in `docs/guest-languages.md`.

It does **not** work from a real `.build.ae` yet. The orchestrator
linker (`tools/aeb-link`) doesn't link foreign-language bridges, so
`import contrib.host.lua` resolves but `lua.run(...)` fails to link.
The work:

- `aeb-link` detects `import contrib.host.<lang>` anywhere in the
  module closure.
- For each, it adds the bridge `.c`, `-DAETHER_HAS_<LANG>`,
  `-DAETHER_HAS_SANDBOX`, and `pkg-config` cflags/libs to the
  orchestrator's gcc invocation — exactly what
  `tests/test_host_lua.build.sh` does for the test today. That
  sidecar is the working reference; promote its logic into `aeb-link`.
- Degrade gracefully: no dev library → stub mode (the bridge's
  `#else` no-ops), so a missing `liblua` never fails the build.

Blocked-ish upstream: the installed Aether tree ships
`contrib/host/<lang>/` with `.ae`/`.h`/`README` but not
`aether_host_<lang>.c`, so the bridge source is currently only
locatable from a sibling Aether checkout. A clean fix wants Aether to
ship the bridge `.c` (or fold the stubs into `libaether`) — flagged
for the Aether side.

## ~~Build environment validation~~ (not doing)

Decided against `aeb --check`. The build already fails fast with a clear
error when a tool is missing, scoped to exactly the module that needed it.
A pre-flight check would need to stay in sync with SDK internals, and
would report missing tools you don't even need. If a specific SDK's
failure message is ever cryptic, fix that message rather than adding a
separate validation system.

## Scala

1. Assembly jar / fat jar packaging — replace `scala-cli --power package`.
   Needs a `scala.shade(b)` or reuse of `java.shade(b)` since Scala
   compiles to .class files on the JVM.

2. Scala version DSL — `scala_version("3.8.2")` setter exists but
   untested with versions other than 3.8.2. Cross-compilation
   (2.13 + 3.x) not supported.

3. sbt project migration — the current itest uses scala-cli's
   `//> using` convention. An sbt multi-module project (with
   `build.sbt`, `project/`, sub-projects) would prove aeb can replace
   sbt end-to-end. The Scala SDK already does direct `scalac` invocation
   so it's just a matter of writing `.build.ae` files for a real sbt project.

4. Compiler plugins — some Scala projects use compiler plugins
   (e.g. wartremover, better-monadic-for). Would need a
   `compiler_plugin("org.wartremover:wartremover_3:version")` setter
   that adds `-Xplugin:path.jar` to the scalac invocation.

## .NET

1. Hierarchical config via `load_config()` — a shared `.config.ae` file
   that sets default DSL values (sdk, target_framework, nullable, etc.),
   loadable at the top of each `.build.ae`. Leaf projects override
   individual setters. aeb generates the complete `.csproj` every time —
   no `Directory.Build.props` inheritance, no MSBuild walking up the
   tree. The `.build.ae` is the single source of truth.

2. Eliminate `Directory.Packages.props` — move NuGet version management
   into aeb. Either a shared `.versions.ae` file or version suffixes on
   `nuget("PackageName:1.2.3")`. Central version pinning becomes an aeb
   concern, not an MSBuild concern.

3. `dotnet publish` / deployment packaging — the current SDK has
   `build_project` and `test` but no publish/container/self-contained
   deployment support.

4. F# support — the SDK auto-detects `.fsproj` but hasn't been tested
   with F# projects. Should work since MSBuild handles F# the same way.

5. Multi-targeting (`net8.0;net10.0`) — the `target_framework()` setter
   currently takes a single TFM. Multi-targeting would need
   `<TargetFrameworks>` (plural) in the generated `.csproj`.

6. Package asset control — `PrivateAssets`/`IncludeAssets` on NuGet refs.
   Prevents analyzers/tools from flowing to downstream projects. Needs
   a richer `nuget()` setter, e.g. `nuget("EF.Tools", private: "all")`
   or a trailing block on nuget.

7. Conditional package references — some packages only apply in Release
   (e.g. `BuildBundlerMinifier`). Needs `nuget_if("Release", "Pkg")` or
   a `condition()` setter.

8. Content/resource copy rules — `CopyToOutputDirectory` for
   `appsettings.json`, Razor views, etc. Needed for `dotnet publish`
   and deployment. DSL: `copy_to_output("appsettings.json")`.

9. User secrets — `<UserSecretsId>` for ASP.NET Core dev-time secret
   management. DSL: `user_secrets("guid")`.

## Cross-cutting — inspired by Cake (C# Make)

Cake is a mature .NET build orchestrator. These are capabilities it has
that aeb doesn't yet, worth considering across all languages:

### Versioning

Cake integrates GitVersion for semantic versioning — the build script
knows its own version derived from git tags/branches, and injects it
into assembly metadata, package versions, and release notes. aeb has
no versioning story at all.

Possible aeb approach: a `version()` builder or DSL that reads git
tags/describes and exposes `${version}` in the build context. Language
SDKs use it for jar manifests, NuGet package versions, npm versions, etc.

### Test result reporting

Build-failure propagation is now wired (was a repo-wide silent-green
bug — a failed compile/test exited 0). The orchestrator captures each
node's rc + `build.record_status` and `exit(1)`s on `build.any_failed`,
and every `builder` failure site across all SDKs calls
`build.fail(ctx, reason)`. See `asks/node-failure-propagation.md`.
Remaining follow-ups there: distinguishing "test failed" from "test
errored" (depends on the structured-output migration below), and
exercising the `record_status`-from-explicit-`return` path (rarely hit,
since users seldom `return` from a builder call).

aeb today has two layers of test reporting:

1. **Pass/fail counts in `[telemetry]`**: each test SDK calls
   `build._record_test_result(ctx, passed, failed)` and the
   summary shows `<passed>/<total> PASS|FAIL` per target.
2. **Persisted test stdout/stderr**: `target/<module>/test_output.log`
   captures the full test runner output for failure diagnosis.
   Currently wired in `java.junit5`, `java.junit`, `jest.test`,
   `python.pytest`, `dotnet.test`; other test SDKs still print
   only to terminal scrollback.

What's left:

- **Wire `test_output.log` for the rest of the test SDKs**:
  `bash.test`, `aether.program_test`, `go.go_test`, `rust.test`,
  `rust.test_workspace`, `kotlin.kotlin_test`, `clojure.test`,
  `scala.munit`, `ts.mocha`. Each is a small per-SDK change
  (replace `os.system(cmd)` with `tee`-to-target_dir).
- **Switch parsers to structured outputs**: today's pass/fail
  parsers regex over freeform stdout. Each test runner has a
  structured-output mode that's more correct:
  - junit-platform-console: `--reports-dir` writes JUnit XML
  - pytest: `--junit-xml=path` writes JUnit XML
  - jest: `--ci --json` writes structured JSON
  - dotnet test: `--logger trx` writes TRX (.NET XML format)
  - cargo test: `--message-format=json` (nightly) or `cargo2junit`
  - go test: `gotestsum` wraps `go test` with JUnit XML output
  Switching to structured ground truth removes the regex
  parsers and gives CI dashboards a consumable artifact at
  `target/<module>/test-results.xml` (or .json/.trx). Each SDK
  is a bounded migration; the cross-cutting decision is "stdlib
  XML/JSON parser, or shell out to a parser tool?"
- **Cross-build aggregation**: cumulative test-result history
  across builds (which test broke this morning vs yesterday).
  Needs persistent storage outside `target/`. Defer.

### Task lifecycle hooks (setup/teardown)

Cake has global and per-task setup/teardown. aeb has nothing — if a
test starts a server and crashes, the server leaks. A `teardown()`
block in `.tests.ae` would run regardless of test outcome.

### Conditional task execution

Cake tasks have `.WithCriteria()` — skip a task based on runtime
conditions (branch name, env var, flag). aeb currently runs everything
it finds. Useful for: skip integration tests in CI, skip signing
locally, skip publish on non-tag builds.

Possible: `skip_if(b, "CI != true")` or a `criteria()` DSL setter.

### NuGet/Maven package publishing

Cake has DotNetNuGetPush, NuGetPush for publishing packages to feeds.
The Java side has `mvn deploy`. aeb has `shade()` for fat jars but no
publish step — built artifacts stay local.

Needed for `.dist.ae`: a `publish()` builder or DSL that pushes to
NuGet feeds, Maven Central, npm registry, etc.

### Code signing

Cake integrates Azure Key Vault + SignTool for signing packages before
publish. Relevant for any project that ships binaries.

### CI system detection

Cake auto-detects 15+ CI systems (GitHub Actions, GitLab CI, Jenkins,
etc.) and adjusts behaviour — setting output variables, uploading
artifacts, detecting PR context. aeb is CI-agnostic (runs the same
everywhere), which is a strength, but knowing "am I in CI" and "is
this a PR" would enable conditional logic.

Possible: `build.is_ci()`, `build.branch()`, `build.is_pr()` functions
that read standard CI env vars (GITHUB_ACTIONS, CI, GITLAB_CI, etc.).

### `aeb --ci <git-url> <commit-hash> <scan-target>` — the wake-on-commit one-shot

**Designed; not built.** Design:
[docs/aeb-vs-snap-ci-and-the-wake-on-commit-flow.md](docs/aeb-vs-snap-ci-and-the-wake-on-commit-flow.md)
(the "concrete CLI" section). The one-shot command a CI trigger / hook hands
to a runner: clone (or fetch into a cached mirror) the URL, `git checkout
<hash>`, then run the scan over the target as if you'd `cd`'d in and run `aeb
<scan-target>` — exit code + telemetry = the flow result.

NOT a new responsibility: `aeb-agent` already does `git fetch + checkout
<hash>` → vet → build the prepared tree. `--ci` surfaces that same
fetch-a-named-revision-and-build as a **direct local CLI** (no dispatch/lease
protocol). Respects the boundary: aeb owns the deterministic fetch+checkout+
build of a named revision; it does NOT own the trigger (a hook), nor the
runner/secrets/approval/deploy wrapper (CI's).

- **Trust posture: `--vet --sandbox` ON by default** — a `--ci` run fetches a
  commit you may not have reviewed (a trigger fired on someone's push), so the
  fetched tree is untrusted-until-cleared (matching the agent's
  pre-integration model). `--no-vet`/`--no-sandbox` = explicit trusted fast
  path. Composes the three tracks: `--ci` is the entry, veto/sandbox is the
  trust gate, prereq()/provisioning gives the runner the needed toolchains.
- Open: workdir lifecycle (per-run temp clone vs. cached bare mirror — lean
  cached mirror keyed by URL); optional `--patch <file>` overlay (the agent's
  untrusted-delta path, for "test this PR's uncommitted diff"); private-repo
  auth relies on the runner's ambient git credential helper / SSH agent (aeb
  never manages secrets — that's CI's column).

### Gentoo-style source-dependency graph — `.src.ae` + `src.fetch` + USE flags

**Designed/analysed; no code yet.** Design doc:
[docs/gentoo-style-src-deps.md](docs/gentoo-style-src-deps.md). aeb's core
already IS a source-dep graph that makes binaries as it traverses (the DAG +
the bootstrap-tool pattern). "Gentoo-style" adds three things, each modeled on
an existing mechanism: (1) a `src` SDK — `src.fetch(url, sha256)` (the one
genuinely-new primitive; shared with provisioning's pinned fetches), (2) a
`.src.ae` from-source dep node (same dot-suffix shape as `.crate.ae`/`.jar.ae`,
resolving to built-from-source artifact), (3) USE flags — a graph-wide feature
vector (`--use`, modeled on `--coverage`, with cache-key segregation). System-
install/slots deliberately left out (aeb's hermetic `target/` is the better
answer). Composes with --vet/--sandbox (a fetched tree is untrusted) and shares
the fetch primitive with prereq()/provisioning.

### Build prerequisites & provisioning — `prereq()` / preflight / podman layering

**Fully designed; no code yet.** Design doc:
[docs/build-prerequisites-and-provisioning.md](docs/build-prerequisites-and-provisioning.md).
This is the principled version of the "Multi-SDK bootstrapping" idea below
(Cake's build.sh installs specific .NET SDK versions; `require_tool(...)`):
a leaf *declares* its system-toolchain requirements, and a missing one is a
clean attributable verdict rather than a confusing build failure.

Motivated by a real monorepo with huge per-leaf toolchain variance (**skir** —
~27 leaves where each `bindings/{rust,go,java,kotlin,dart,csharp,swift,gleam,
zig,moonbit,cpp,python,typescript}` needs that language's entire system
toolchain). Today `bindings/zig/.build.ae` → `zig: not found` → a build
failure indistinguishable from "the code is broken." (Same class as the
kotlinc-1.3-vs-JDK-24 mismatch hit during the aeb(cap) sim/repo migrations.)

The design: `prereq(b, "<toolchain>:<version>")` reuses the `dep()` DAG
machinery (greppable via `extract-deps`, no evaluation) — leaves are
toolchain tokens, not build files. It feeds two phases: **preflight**
(always, every agent, fail-closed → a distinct `unmet-prereqs` verdict, never
silently provisions) and **provision** (opt-in only: `--allow-provision` +
podman → layers the missing toolchains onto the agent's base image so a
subsequent build passes). Composes with the veto/sandbox stack:
*provisioning adds capability, never trust.*

Build order (from the doc):

1. **`prereq(b, "<toolchain>:<version>")`** — the dep-shaped, greppable
   declaration; extend `tools/extract-deps` to collect it; flatten over the
   dep DAG to the prerequisite set. *(the data)*
2. **preflight** — probe the set vs. the environment; missing → the distinct
   `unmet-prereqs` verdict; never provisions. *(the fail-closed default)*
3. **`ping` advertises held tokens** + originator subset-routing. *(routing)*
4. **`--allow-provision` agent + the operator token→recipe map** — one combined
   layer keyed by `sha256(sorted set)`, built on `aeb-agent-base`; the
   subsequent clone+build runs inside it. *(provisioning — opt-in, podman)*
5. **Later:** the *pluck-select-into-base-layer* optimization, once rebuild
   cost is measured to justify it.

### Multi-SDK bootstrapping

(Superseded by the prereq()/provisioning design above — kept for the
cross-tool context.) Cake's build.sh/build.ps1 install specific .NET SDK
versions before building. aeb assumes tools are on PATH. A
`require_tool("dotnet", "10.0")` or similar could validate/install
prerequisites.

## Cross-cutting — capabilities from CI-as-code (TeamCity, Jenkins)

TeamCity (Kotlin DSL) and Jenkins (Declarative + Scripted Groovy) are
CI-orchestration platforms; aeb is a build orchestrator. There's
real overlap, real divergence, and real questions about where the
boundary should sit.

This section catalogues every plausible capability from those
platforms, marked **SHOULD** / **MAYBE** / **SHOULDN'T** based on
whether the shape fits aeb's "the .ae file IS the graph node"
position. Most of the items here are deliberately not on the
roadmap — capturing the analysis so future sessions don't
re-derive it from scratch.

### The structural difference (read this first)

TeamCity and Jenkins both treat *the build invocation* as their
atomic unit. A Jenkins stage runs a script. A TeamCity build type
runs steps. The DAG nodes are opaque inside.

aeb treats *the source-tree target* as the atomic unit. A target
IS a `.ae` file. The DAG is **derived from the source tree** in
aeb, **declared separately from the source tree** in
TeamCity/Jenkins. That separation is where pipelines drift out
of sync with reality. aeb avoids it by construction.

So even if a capability looks transplantable, the right shape
in aeb is usually a new dot-prefixed `.ae` file type
(`.trigger.ae`, `.notify.ae`) discovered by file scan, not a
top-level DSL block in some root config. **Same convention as
`.build.ae` / `.tests.ae` / `.dist.ae`: discoverable, greppable,
lives next to the code it describes.**

### SHOULD — these compose with aeb's existing shape

#### `.trigger.ae` target type

Declares CI hooks alongside the code they trigger on. aeb doesn't
*fire* the trigger — it emits a schedule artifact a CI system
consumes. Same factoring as the `meta` SDK + `brew.formula`
exporter: source-of-truth lives in `.trigger.ae`; emitters
translate to GitHub Actions YAML, GitLab CI, TeamCity DSL, etc.

```aether
import build
import trigger
main() {
    b = build.start()
    trigger.cron(b, "0 4 * * *")            // nightly
    trigger.vcs_change(b, "main")           // on push to main
    trigger.path_filter(b, "java/**")       // only when Java changed
    trigger.dep(b, "java/components/.tests.ae")  // run this on trigger
}
```

`aeb --print-triggers --emit github-actions` walks every
`.trigger.ae` and writes `.github/workflows/aeb-triggered.yml`.
Single source of truth; CI YAML becomes a generated artifact.

**Why SHOULD**: composes with `--affected`, `--graph`,
`--print-affected`. New target type, same scan/parse pipeline.
No daemon, no server, just file emission.

#### `on_failure(b) { ... }` setter inside test/build closures

Symmetric to the existing `pre_command` / `post_command` /
`fixture_seed` lifecycle hooks. Fires the contained command when
the enclosing target fails. Useful for Slack/email notifications,
log capture, artifact preservation.

```aether
bash.test(b) {
    script("test_acl.sh")
    on_failure(b) {
        run_command("notify-slack 'tests failed in ${MOD}'")
        copy_to("/tmp/aeb-failures/${MOD}-$(date +%s).log")
    }
}
```

**Why SHOULD**: small extension to the lifecycle pattern we
already have. Doesn't grow into "notification ecosystem"
because the body is just a shell command — same escape hatch
`pre_command` uses.

#### Test-passage as a build dep

Today's `.dist.ae` runs whenever `aeb path/.dist.ae` is invoked,
regardless of whether the corresponding `.tests.ae` passed. A
`requires_passing(...)` setter would make distribution gated:

```aether
brew.formula(b) {
    aeb_target("lib/hello/.build.ae")
    requires_passing("lib/hello/.tests.ae")
}
```

aeb resolves the dep, runs the tests if not cached, refuses to
emit the formula if any failed.

**Why SHOULD**: closes a real safety gap (no-one wants a brew
formula for a binary whose tests don't pass) using existing
mechanism (graph dep + cache). One-line setter, ~30 LOC of
build-time check. The Aeocha-driven test-result marker we
already write means we have the data on disk to consult.

#### Artifact promotion / cross-target output passing (formalize)

Already partially done: `target/<module>/` is per-target,
downstream modules read `jvm_classpath_deps_including_transitive`
etc. via `build.dep`. What's missing is a *named* artifact API:

```aether
java.shade(b) {
    main_class("com.Main")
    output("app.jar")
    artifact("app-fat-jar", "app.jar")   // names the artifact
}
brew.formula(b) {
    consume_artifact("ae/app/.dist.ae", "app-fat-jar")
}
```

vs. today's "downstream reads a known-named file from
`target/<module>/`." Names give artifacts an explicit public
interface; renaming the file in the producer doesn't break
consumers.

**Why SHOULD**: makes implicit artifact contracts explicit. Aligns
with how Bazel/Buck/Pants do it. Doesn't grow aeb's surface much.

### MAYBE — interesting but the cost/value isn't obvious yet

#### Pipeline visualization beyond `--graph`

Today `aeb --graph` emits DOT/Mermaid of the static dep graph.
TeamCity/Jenkins UIs show *runtime* state: which steps ran in
this build, how long each took, where the failure was, what
artifacts were produced. We have the data (the `[telemetry]`
records, the `.aeb_test_failures` markers, per-target
`test_output.log`) — what's missing is a renderer that joins
them into a per-build view.

```bash
aeb --build-report --format html > target/_aeb/last-build.html
```

Static HTML, opens in a browser, no server. Force-directed
graph with nodes coloured by cache outcome / duration / pass-fail.

**Why MAYBE**: useful but cosmetic. The data is already in the
`[telemetry]` block; the HTML renderer is "just" a static-site
generator over the records list. Lower priority than functional
gaps. Defer until someone asks.

#### CI-system detection (`build.is_ci()`, `build.branch()`, `build.is_pr()`)

Cake auto-detects 15+ CI systems and exposes a unified API. aeb
is CI-agnostic today (runs the same everywhere), which is a
strength. Knowing "am I in CI" enables conditional logic
(skip-on-CI, skip-when-not-PR), which TeamCity/Jenkins handle
via build parameters.

**Why MAYBE**: small feature, mild value. Reading `$CI` /
`$GITHUB_ACTIONS` / `$JENKINS_HOME` is six lines. The
question is whether to expose it as a builder primitive or
let users read env vars in their `.ae` files. Lean: expose
sparingly when a real need surfaces.

#### Conditional task execution (Cake's `.WithCriteria()`)

Already in the Cake section above. Worth re-flagging here
because TeamCity/Jenkins both have it:

```aether
java.junit5(b) {
    criteria(b, "${BRANCH} == 'main'")
}
```

**Why MAYBE**: the implementation is environment-variable
substitution + a string equality / glob check. Cheap. The risk
is "runtime conditional execution" growing into a mini scripting
language inside `.ae` files. If we add it, keep the predicate
language *minimal* — env-var equality, env-var presence/absence,
nothing else. Don't accidentally reinvent Bash inside Aether.

#### Multi-platform / hermetic toolchain (TeamCity agent requirements)

TeamCity has `agentRequirement("teamcity.agent.jvm.os.name=Linux")`
to route a build to a matching agent. Jenkins has `agent { label
'linux' }`. aeb has nothing — it runs on the host you invoke it
on.

The aeb-shaped version is **NOT** "agent routing" — that's CI's
job. The aeb-shaped version is "validate the host has the right
toolchain version, fail fast otherwise." Exactly the
`build.env(b)` block already in the TODO. Same idea.

**Why MAYBE**: already on the roadmap as `build.env`.
Cross-listed here for the connection.

### SHOULDN'T — these break aeb's structural position

#### Agent pool / fleet management

TeamCity manages a fleet of build agents, distributes builds
across them, drains agents for maintenance, prioritises
pipelines. Jenkins has labels + nodes. aeb is a single-machine
CLI by design.

**Why SHOULDN'T**: building a fleet manager is a different
product. The right factoring is what the article on bash-vs-CI
argues: build tool decides what to do (aeb), CI orchestrator
decides where each shard runs (Buildkite/GitHub Actions/etc).
If a user wants 4-way sharding, they run `aeb --since main
--shard 1/4` four times across four runners. aeb provides the
sharding semantics; the CI provides the distribution.

#### Build history / cross-build dashboards

TeamCity/Jenkins maintain a database of every build that ever
ran. UIs show "this pipeline used to take 8 minutes, now it
takes 22, here's the commit." aeb's `[telemetry]` is per-run,
ephemeral.

**Why SHOULDN'T**: that's a server. aeb is a CLI. Building a
server is a different product (and there are several already —
BuildBuddy, EngFlow, Honeycomb-for-builds). If aeb writes
structured telemetry to a file (Tier 2 vision in the telemetry
section above), those servers can consume it. **Emit, don't
ingest.**

#### Triggers as runtime behaviour

aeb shouldn't become a daemon waiting for VCS pushes or cron
firings. The `.trigger.ae` form above is fine — emit a
schedule artifact for *another* system to consume. Becoming the
scheduler is the wrong direction.

**Why SHOULDN'T**: scope explosion. As soon as aeb fires
triggers itself, it needs durable queue management,
backpressure, retry semantics, distributed locks (multiple aeb
instances contending for a cron tick), monitoring of its own
triggers. That's a separate product called "a job scheduler"
and it's solved.

#### Notifier ecosystem (Slack / Teams / email / PagerDuty plugins)

TeamCity has built-in notifiers and a plugin system. Jenkins has
a vast plugin marketplace including 50+ notification plugins.

**Why SHOULDN'T**: ecosystem trap. Better to expose hook points
(`on_failure`) and let users shell out (`run_command("curl
$SLACK_WEBHOOK ...")`). Same factoring as how `bash.test`
exposes `pre_command` / `post_command` rather than a typed
fixture API: keep the SDK surface small, let the escape hatch
be a shell command. If the escape hatch isn't enough, the user
can write a small `.ae` SDK in `.aeb/lib/notify/module.ae` —
that's exactly the consumer-local SDK pattern documented in
LLM.md.

#### Build queue management / priority lanes

TeamCity/Jenkins let you tag builds as high/medium/low priority
and the scheduler picks accordingly. aeb runs serially in one
process; the only "queue" is the topological order.

**Why SHOULDN'T**: orthogonal to aeb's job. If you have multiple
aeb invocations contending for a CI worker pool, the CI system's
queue is what should arbitrate. aeb running on one machine is
already done in topo order.

#### Approval gates ("manual approval before deploy")

Common in CI/CD pipelines. The build pauses, a human clicks
approve, the build resumes. TeamCity calls these "manual
trigger" build types; Jenkins has `input` steps.

**Why SHOULDN'T**: aeb is a build tool, not a deployment
orchestrator. Approval gates are a deployment-pipeline concern
that lives on the CI side. The aeb-shaped equivalent is "split
your pipeline into pre-approval and post-approval stages, each
calling `aeb` for the relevant target set"; the CI handles the
human-in-the-loop.

TODO: add integration tests for every approval provider path:
`approval.jira`, `approval.servicenow`, `approval.github`,
`approval.gitlab`, `approval.azure_devops`, `approval.http`,
`approval.command`, and `approval.attestation`.

#### Generic pipeline-as-code language

The temptation: "let users write arbitrary Aether-DSL pipelines
that aeb interprets." A `pipeline { stage(...) parallel(...)
when(...) }` block.

**Why SHOULDN'T**: this *is* TeamCity/Jenkins. The whole point
of aeb's structural position is that the pipeline IS the source
tree, derived not declared. Inviting users to write arbitrary
pipelines reintroduces the source-tree-vs-pipeline drift problem
that aeb's design exists to solve.

If a user genuinely needs imperative pipeline orchestration on
top of aeb, the answer is a thin shell or Make wrapper that
calls `aeb <target>` multiple times — same factoring the bash
article we discussed argues for at the CI level.

### Summary table

| Capability | Verdict | aeb shape if SHOULD |
|---|---|---|
| Triggers (cron, VCS, path filter) | SHOULD | `.trigger.ae` + `--print-triggers` exporter |
| `on_failure(b)` lifecycle hook | SHOULD | Setter inside test/build closures |
| `requires_passing(...)` dep | SHOULD | Setter; resolver-time gate |
| Named artifacts | SHOULD | `artifact()` + `consume_artifact()` setters |
| Pipeline visualization (runtime view) | MAYBE | Static HTML from `[telemetry]` records |
| CI-system detection | MAYBE | Sparingly; expose env-var reads as primitives |
| Conditional execution | MAYBE | `criteria()` setter; minimal predicate language |
| Hermetic toolchain check | MAYBE | Already roadmap as `build.env()` |
| Agent pool / fleet routing | SHOULDN'T | CI orchestrator's job |
| Build history / dashboards | SHOULDN'T | Different product (BuildBuddy, etc.) |
| Triggers as runtime daemon | SHOULDN'T | Scope explosion; emit, don't run |
| Notifier ecosystem | SHOULDN'T | Hook + shell escape; users write own SDKs |
| Build queue / priority | SHOULDN'T | CI's queue arbitrates |
| Approval gates | SHOULDN'T | Deployment-pipeline concern, not build |
| Generic pipeline-as-code | SHOULDN'T | Reintroduces source-vs-pipeline drift |

### A note on Jenkins's `parallel { }`

Jenkins's most useful primitive is the `parallel` block — run
N stages concurrently, fail fast or wait-all. aeb already has
the equivalent at the test level (`bash.test(b) { jobs(N) }`,
`junit5` parallelism via `forkCount`) and is on track for
target-level parallelism (the "Parallel execution" item under
Runner improvements above). When that lands, "two independent
tests run concurrently" works without a `parallel { }` block —
the DAG already knows they're independent. **The DAG IS the
parallelism specification**, same way the DAG IS the
dependency specification.

This is the strongest concrete demonstration of why the
TeamCity/Jenkins shape isn't the right import path: their
`parallel` blocks exist to declare what aeb derives.

## Java/Maven

What we have today: `java.javac()` covers the maven-compiler-plugin
surface (release / source / target / lint / encoding / parameters /
debug / `--enable-preview` / `--module-path` / annotation processors /
generated sources). `java.junit()` and `java.junit5()` cover the
surefire core case. `java.shade()` builds classic fat JARs.
`maven.resolve()` + `maven.classpath()` + `load_bom_file()` handle
dependency resolution including BOM-managed versions.

Below is what's still missing measured against mainstream Maven
plugin grammars — grouped by how often a typical Java shop actually
needs each.

1. tools/aeb-resolve.jar - maybe not check that it. Maybe  have is slimmer and source transitive deps from ~/.m2/repository using the manifest. If those transitive 
deps are missing go get them and place them in there

2. ~~maven should have its own aeb module~~ (done — `lib/maven/module.ae`)

3. Surefire equivalent in aeb grammar — `build.junit(b)` already handles
   the core case (find test classes, fork JVM, run with JUnit). Missing
   pieces vs Surefire: test filtering/includes/excludes, parallel forks
   (`forkCount` / `reuseForks` / `argLine`), `parallel=classes` worker
   pool, XML report output (`target/surefire-reports/TEST-*.xml`).
   Single-JVM `junit5_cmd` won't scale on a real test suite. Add
   incrementally.

### Tier 1 — every serious Java project needs these

4. **Resources + resource filtering** (maven-resources-plugin). Copy
   `src/main/resources` into the classpath, optionally substituting
   `${project.version}` etc. Today `java.javac()` only sees `*.java`,
   so properties / YAML / XML / SQL resources have no path onto the
   classpath. DSL sketch:

   ```aether
   java.javac(b) {
       resources("src/main/resources")
       filter("application.yml")            // do placeholder sub
       property("project.version", "1.2.3")
   }
   ```

5. **Manifest / Main-Class** (maven-jar-plugin). Today plain `jar`
   output has no manifest control. Needed for runnable JARs and
   `-Multi-Release` headers. DSL sketch:

   ```aether
   java.jar(b) {
       main_class("com.example.Main")
       manifest_attribute("Implementation-Version", "1.2.3")
       multi_release(true)
   }
   ```

6. **Sources JAR + Javadoc JAR** (maven-source-plugin,
   maven-javadoc-plugin). `*-sources.jar` and `*-javadoc.jar` next to
   the main artifact — required by Maven Central, used by every IDE.
   Builders: `java.sources_jar(b)`, `java.javadoc(b) { link(...); doctitle(...) }`.

7. **Spring Boot fat-JAR layout** (`spring-boot-maven-plugin
   repackage`). Different from `shade()` — uses `BOOT-INF/`,
   `PropertiesLauncher`, layered jars. High leverage given the
   `itests/spring-data-examples` scale. DSL: `java.spring_boot_repackage(b)`.

8. **Integration test phase** (maven-failsafe-plugin). `*IT.java`
   pattern, separate from unit tests, post-suite verify that fails
   the build only after teardown runs. Today `junit5()` runs
   everything in one phase. Add `java.junit5_it(b)` with an `*IT`
   default include pattern and post-test cleanup hook.

9. **Code coverage** (jacoco-maven-plugin). Inject
   `-javaagent:jacocoagent.jar=destfile=...` into junit invocations
   and emit exec/HTML/XML reports. One agent flag in `junit5_cmd` +
   a small report builder. DSL:

   ```aether
   java.junit5(b) {
       coverage("jacoco")               // or coverage_off()
   }
   java.coverage_report(b) { format("xml", "html") }
   ```

### Tier 2 — needed to publish or distribute artifacts

10. **POM emission**. Maven Central (and most artifact stores) need
    a `pom.xml` next to the jar. Even Gradle has to emit one. Cheap
    to implement — a `pom_xml_content(opts, deps)` content builder in
    the same shape as the new `dotnet.csproj_content()`. Without this
    nothing aeb produces is publishable.

11. **mvn install / deploy** (maven-install-plugin,
    maven-deploy-plugin). `mvn install` populates `~/.m2` for
    cross-project local consumption; `mvn deploy` pushes to
    Nexus/Artifactory/Central. aeb's vendored/registry pattern
    doesn't write to `~/.m2`, and there's no push step at all.
    Builders: `java.install(b)`, `java.deploy(b) { repo(...);
    credentials(...) }`.

12. **GPG signing** (maven-gpg-plugin) + checksums. Central requires
    `.asc` signatures and `.md5` / `.sha1` / `.sha256` / `.sha512`
    siblings on every artifact. DSL: `java.sign(b) { key_id(...) }`,
    `java.checksums(b) { algorithms("sha256", "sha512") }`.

### Tier 3 — quality / static analysis

13. **Checkstyle / PMD / SpotBugs / Spotless**. Run as part of build,
    fail on violations. Each is a small `.cmd_string` builder
    invoking the respective standalone runner. Group under
    `java.lint(b) { checkstyle(...); spotbugs(...); spotless_check() }`
    or one builder per tool.

14. **errorprone / NullAway** (javac `-Xplugin:` style). Distinct
    from annotation processors — these ride `javac` itself. Add an
    `xplugin()` setter to `java.javac()` that emits `-Xplugin:` flags.
    Existing `processor()` covers AP path; this is the missing
    sibling.

15. **maven-enforcer-plugin** equivalents. Banned-deps,
    dep-convergence, no-snapshot-deps, required Java version. DSL:

    ```aether
    java.enforce(b) {
        require_java(">= 21")
        ban_dep("commons-logging:commons-logging")
        require_convergence()
        no_snapshots()
    }
    ```

### Tier 4 — build-system meta

16. **maven-toolchains-plugin** equivalent. Pick one of several
    installed JDKs by vendor/version per module — multi-JDK builds
    in a monorepo. Today aeb uses whatever `javac` is on PATH. This
    is the same gap as the hermetic-toolchain item in
    `docs/aeb-vs-bazel.md`; if that gets resolved at the runner level
    (hermetic-LLVM-style fetch + pin), this falls out.

17. **Profiles** (`<profile id="ci">`). Maven's environment-specific
    config switches. aeb has no profile concept. Could ride
    `criteria()` (cross-cutting Cake item above) plus a profile
    selector flag — same DAG, same SDK calls, just different setter
    values per profile.

18. **Properties / interpolation**. `${project.version}` and
    friends used by resources, manifest, POM, jib. Tied to the
    versioning story in the Cake section above and to (4) and (10)
    here. One `properties` map on the build context, expanded by
    each builder that reads strings.

19. **versions-maven-plugin**. `display-dependency-updates`,
    `use-latest-versions`. Mostly tooling, not build. Could be a
    standalone `aeb deps update` subcommand rather than a builder.

20. **flatten-maven-plugin**. Resolves parent/property references
    in the published POM. Only matters once (10) lands.

### Tier 5 — domain-specific

21. **protobuf-maven-plugin + os-maven-plugin**. `protoc` codegen
    with platform-specific compiler binary selection. Big for
    gRPC/Spring-gRPC shops. DSL: `proto.compile(b) { ... }` —
    probably its own SDK module rather than crammed into Java.

22. **jib-maven-plugin**. Daemonless layered OCI images. We have
    `lib/container/` via podman/docker; the Jib approach (no daemon,
    layered jars) is materially different and worth a separate
    builder.

23. **graalvm native-maven-plugin**. AOT `native-image`. DSL:
    `java.native_image(b) { no_fallback(); reflect_config(...) }`.

24. **Liquibase / Flyway**. DB migration tasks. Probably its own
    `db.migrate(b) { ... }` SDK rather than under Java.

### Suggested order if attacking this

POM emission (10) → Resources (4) → Manifest (5) → Sources/Javadoc
(6) → Spring Boot repackage (7) → Surefire forking + XML reports (3)
→ Jacoco (9). That sequence unblocks "publishable library" and
"runnable Spring Boot app" — the two shapes most Java itests in this
repo actually exercise.

## itest-driven gaps (surfaced 2026-05)

Each of these came out of running a real-world itest to completion
and hitting a specific missing feature. Listed with the expected
grammar so a future session can pick one up cold.

### `kotlin.assembly(b)` — complete the JVM fat-jar set

The executable-fat-jar shape now exists for three of the four
JVM-family SDKs:

- [x] `java.shade(b, main_class, jar_name)` — `lib/java`
- [x] `scala.assembly(b) { main_class(...) output_jar(...) }` — `lib/scala`
- [x] `clojure.uberjar(b) { main_ns(...) output_jar(...) }` — `lib/clojure`
- [ ] **`kotlin.assembly(b)` — the remaining gap.**

Kotlin is the odd one out: `lib/kotlin` has `kotlinc` / `kotlinc_test`
but no packaging builder. The expected grammar mirrors scala.assembly
(Kotlin compiles to plain JVM classes, so no AOT/source-in-jar
wrinkle like Clojure):

```aether
import kotlin
import kotlin (main_class)

main() {
    b = build.start()
    dep(b, ".build.ae")
    kotlin.assembly(b) {
        main_class("com.example.MainKt")   // note the Kt suffix for
                                            // top-level `fun main()`
        output_jar("app.jar")              // optional; default
                                           // <module>-assembly.jar
    }
}
```

Implementation is near-identical to `scala.assembly` (in
`lib/scala/module.ae`): stage compiled classes + the kotlin-stdlib
jar + every maven dep (unzip each jar), write a Main-Class manifest,
`jar cfM`. The one Kotlin-specific note is the `Kt` class-name suffix
that the compiler appends to a file's top-level `fun main()` (file
`Main.kt` → class `MainKt`); the builder should NOT munge this — the
user supplies the exact class name. Reuse the three pure helpers
(`assembly_unzip_jar_cmd`, `assembly_copy_classes_cmd`,
`assembly_jar_cmd`) — they're generic enough to lift into a shared
`lib/build` helper if a fourth caller justifies the move.

While here: scala.assembly fixed a latent bug where
`scala.scalac`'s `jvm_classpath_deps_including_transitive` artifact
omitted the transitive `build.dep` classpath. Check `lib/kotlin`'s
`kotlinc` for the same omission before relying on the artifact in
`kotlin.assembly`.

### `lib/c` third-party C/C++ library build — unblock pytorch c10/util

`itests/pytorch/c10/util/.build.ae` compiles 39 of 42 `.cpp` files
clean. The 3 omissions (`env.cpp`, `signal_handler.cpp`,
`tempfile.cpp`) all `#include <fmt/format.h>` and need the {fmt}
library staged + on the include path. Today there's no aeb-side way
to declare "fetch + build this third-party C++ lib, then add its
headers/objects to my compile."

The fetch half exists (`lib/fetch`). The missing half is a C/C++
third-party build + consume contract. Expected grammar — a sibling
`.build.ae` for {fmt} that produces an artifact the c10/util build
consumes via `build.dep`:

```aether
// itests/pytorch/third_party/fmt/.build.ae
import build
import fetch
import fetch (url, sha256, extract_to, strip_components)
import c
import c (sources, cflag, header_dir)

main() {
    b = build.start()
    fetch.archive(b) {
        url("https://github.com/fmtlib/fmt/archive/refs/tags/10.2.1.tar.gz")
        sha256("...")
        extract_to("src")
        strip_components(1)
    }
    c.library(b) {                  // NEW builder: compile to a .a /
        cc("g++")                   // .so + export an include dir as
        cflag("-std=c++20")         // a consumable artifact
        sources("src/src/format.cc")
        header_dir("src/include")   // NEW setter: dir to re-export on
                                    // the `c_include_dirs` artifact
    }
}
```

Then c10/util consumes it:

```aether
build.dep(b, "../../third_party/fmt/.build.ae")
// c.compile auto-picks the dep's c_include_dirs + links its archive
```

Two new pieces required:
1. **`c.library(b)`** — compile sources into a static archive
   (`ar rcs`) or shared object, and write two artifacts:
   `c_archive` (the `.a`/`.so` path) and `c_include_dirs` (the
   header roots to re-export). `lib/c` already has `c.compile`
   (object set) — this adds the archive/library step + the
   header-export artifact.
2. **`header_dir(...)` setter + dep-aware include resolution** in
   `c.compile` so a downstream module that `build.dep`s a
   `c.library` automatically gets `-I<dir>` for each exported
   header root and links the archive. The shared-library handoff
   contract (`ldlibdeps` / `shared_library_deps_including_transitive`)
   used by the JVM↔native FFI path is the model; this is the
   C-consumes-C variant.

Once {fmt} is consumable this way, re-enable the 3 omitted sources
in `c10/util/.build.ae` and the leaf compiles 42/42.

### aeb-resolve.jar: interpolate POM parent/property versions

`itests/clojure-multiproject-example` carries a
`clojure-dep-patches.bom.ae` that lists Jetty transitives by hand
(`dep("org.eclipse.jetty:jetty-server:11.0.21")`, …) because
aeb-resolve.jar can't interpolate `${jetty.version}`-style version
properties declared in a parent POM / BOM. The resolver walks the
closure but leaves property-interpolated versions unresolved, so
those transitives silently drop and the build fails at link/run with
a `ClassNotFoundException`.

No new `.ae` grammar — this is a `tools/resolver/` (Java) capability.
Expected behaviour: when a dependency's POM declares
`<version>${some.prop}</version>`, resolve `some.prop` from the
`<properties>` block of that POM and its parent chain (and from any
imported BOM's `<properties>`) before failing. The Maven Resolver
API exposes the effective model; the gap is that
`SimpleModelResolver` in `MavenResolver.java` doesn't fully
property-interpolate the parent chain.

Acceptance: delete `clojure-dep-patches.bom.ae`, re-run the clojure
itest, and the Ring/Jetty web apps (`snafuapp`,
`usermanager-first-principles`) still resolve their full Jetty tree
and pass tests.

### Environmental itest blockers (NOT aeb gaps — recorded for honesty)

These two itests don't compile/link to green, but the cause is a
missing host library or an upstream/toolchain incompatibility, not
an aeb feature gap. No grammar to add; recorded so a future session
doesn't chase them as aeb bugs.

- **`rust-multi-module-oxen`** — `crates/server` compiles to objects
  then fails to link with `-lduckdb`: `libduckdb-dev` is not
  installed on the dev box. `cargo build` fails identically outside
  aeb. Fix is `apt install libduckdb-dev` (or a container), not aeb
  work. `oxen-py` is also skipped (needs PyO3 + maturin + Python
  headers).
- **`mrhdias_rust_store`** — upstream `ord_subset` crate is
  incompatible with the current rustc. Fails under bare `cargo build`
  too. Would need an upstream bump or a pin to an older rustc; not
  aeb work.
