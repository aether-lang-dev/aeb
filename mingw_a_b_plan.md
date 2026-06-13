# MINGW A/B Plan — proving the pure-Aether `aeb` facsimile

> Working doc, lives in **`aeb`** (the repo we iterate primarily). The
> **acceptance harness** is the sibling **`../google-monorepo-sim`** — a real,
> aeb-built, polyglot, cross-module monorepo we A/B against. Read this first
> each session; paths below are relative to the `aeb` repo root unless noted.

## TL;DR

`aeb` today = a **635-line bash trampoline** (`./aeb`) + an **all-Aether tool
chain** (`aeb-main` → `aeb-link` → `transform-ae`/`gen-orchestrator` → gcc →
`_ae_build_all` → `aeb-driver`). The only non-Aether piece is the trampoline.

**`tools/aeb-cli.ae` is the pure-Aether facsimile of that trampoline.** Its
front-end is done (argv grammar, env injection, synonym resolution, `--version`,
podman autodetect — it resolves the complete launch plan). The single remaining
gap is the **supervised exec of `aeb-main`** (`tools/aeb-cli.ae:179`, today a
dry-run `println`), which is one `os.run_supervised(...)` call — the primitive
is available as of ae 0.235.

The goal: prove `aeb-cli` builds `../google-monorepo-sim` identically to the
bash `aeb` (**A/B**), first on **Linux** (proves facsimile fidelity, no Windows
needed), then on **Windows MINGW** (the cut-down target).

## Two axes — keep them separate

1. **Axis 1 — the pure-Aether facsimile (the entrypoint).** Replace the bash
   trampoline with `aeb-cli`. ≈ one `os.run_supervised` call from done. This is
   the deliverable. **Testable on Linux today.**
2. **Axis 2 — the build the chain drives being Windows-correct.** Classpath
   separator plumbing, POSIX↔Windows path translation, per-SDK quirks. Needed
   for *green tests on Windows*, but orthogonal to "is the entrypoint pure
   Aether." Only fully verifiable on a MINGW box.

A faithful Axis-1 A/B can pass on Linux **before** any Axis-2 Windows work.

## Background: what the bash trampoline does (and aeb-cli must replicate)

`./aeb` (bash): sets `AETHER`, `AEB_HOME` (= dir of `$0`), `ROOT` (= cwd),
optional `DOCKER_HOST` for podman; routes `--init`/`gcheckout`/`--version` to
subcommand binaries; otherwise execs the launch under a supervision tail:

```
set -m; trap INT/TERM → forward to the group; timeout watchdog; group-reap
"${AEB_LAUNCH[@]}" "$AEB_AETHER_ARG" "$AEB_HOME" "$ROOT" "$@"
#  AEB_LAUNCH = tools/aeb-main (or the aeb-sandbox prefix under --sandbox)
```

The whole supervision tail collapses to ONE cross-platform call (POSIX process
groups / Windows Job Objects under the hood):

```
os.run_supervised(prog, argv, env, new_process_group=1, forward_signals=1,
                  timeout_secs, reap_group=1) -> (exit_code, outcome)
```

Reference shape: `../aether/examples/applications/build-supervisor.ae`.

## Current state of `aeb-cli` (Axis 1)

- **Done & tested** (`tools/aebcli/module.ae`, pure grammar, 130+ assertions
  across `tests/test_aebcli_*`): the tab-separated directive model — `env`,
  `env-append`, `arg`, `synonym`, `error`; the 22-flag table; drive-letter-aware
  target classification.
- **Done** (`tools/aeb-cli.ae`, the impure executor): resolves `AEB_HOME` /
  `ROOT` (native `os.getcwd`, no `pwd` shell-out), `--version` (`AEB_STAMP`
  parse), podman autodetect, executes the directive plan (setenv, env-append,
  synonym file-check + `aeb synonym match:` echo, error→exit), prints the
  resolved launch plan.
- **The one gap**: line ~179 prints `(pending: supervised exec of aeb-main …)`
  instead of running it. **Wire the `os.run_supervised` call here.**

### Wiring detail to handle

The bash trampoline lives AT `./aeb`, so its `AEB_HOME = dirname($0) = <repo>`
is correct. `aeb-cli` builds to `tools/aeb-cli`, so `dirname(argv0) =
<repo>/tools` — one level too deep (`lib/` is at `<repo>/lib`). For A/B runs,
set `AEB_HOME=/abs/path/to/aeb` explicitly (the executor already prefers the env
override), OR teach `aeb-cli` to walk up out of `tools/`. Decide this when
wiring.

## What's already landed on Axis 2 (Windows build-correctness)

All byte-identical on Linux; suite green:
- **Host detection** via compile-time `os.platform()` (no `uname` shell-out) —
  `lib/build._host_os`, `tools/aeb-link`, `tools/aeb-sandbox`.
- **`.exe` suffix** on built native binaries — `lib/{c,aether,rust,go}` +
  `tools/aeb-link` (the `_ae_build_all` composite). `go` only suffixes
  extension-less (executable) outputs; shared libs keep their name.
- **Classpath separator — leaf joins** routed through `build._cp_append(cp,
  part)` (= `_path_sep()`, `;` on Windows) in all five JVM SDKs.

## What remains on Axis 2 (ordered by leverage for the harness repo)

`../google-monorepo-sim` is **JVM-dominant**: 56 build files, **21 JVM nodes
with cross-module deps**, every JVM node also depping `junit` + `hamcrest` jars.
So:

1. **Classpath plumbing (THE blocker).** Leaf joins are necessary but not
   sufficient — the cross-module currency is still `:`-hardcoded:
   - `build._build_dep_classpath` reads the artifact via shell
     `echo | tr '\n' ':' | sed` and joins with `:` → native newline-split +
     `_cp_append`.
   - Artifact format is inconsistent (java/clojure/groovy write newline-sep via
     `tr ':' '\n'`; scala writes `:`-joined). Unify to canonical newline-sep
     on-disk, convert to `_path_sep()` only at the `-cp` boundary.
   - `maven.classpath`, groovy `_nl_to_colon`/`_colon_to_nl`, and the classpath
     `string.split(cp, ":")` sites (scala, clojure) all → `_path_sep()`.
   - Without this, a multi-module JVM build on a Windows JDK produces a MIXED
     `classes;dep1:dep2` classpath → fails. (See `TODO.md` item 2.)
2. **POSIX↔Windows path translation.** MINGW presents `/c/...`; a Windows
   `java.exe`/`javac` wants `C:\...`. MSYS2 auto-mangling is unreliable for
   `;`-separated / `:`-containing args (classpaths). Likely needs `cygpath -w`
   on classpath entries + file args. Depth unknown until run on MINGW.
3. **Per-SDK shakeout** (each unverified on Windows): maven resolver
   (`aeb-resolve.jar` + `~/.m2`), `junit-fetched` curl download, dotnet/csharp
   paths+cache, ts (pnpm/jest), python venv, go, rust, the `.dist.ae` fat-jar
   shade. Iterate on a MINGW box.
4. **Feature-gate POSIX-only** (`--sandbox`/`--watch`/podman) with a clear
   "unsupported on Windows (cut-down)" message (`TODO.md` item 5).

Note: on **MINGW specifically**, the bash trampoline *would* run (bash present)
and the ~47 coreutils shell-outs *work* (sed/awk/tr present) — so the native
entrypoint and coreutils-removal are NOT MINGW blockers. The bites are the
**toolchain-target** mismatches above (separator, `.exe`, paths). The native
entrypoint matters for *true* cmd.exe Windows and as the pure-Aether goal in its
own right.

## The harness repo: `../google-monorepo-sim`

- Polyglot by design: `java` (bulk), `kotlin`, `go`, `rust`, `typescript`,
  `python`, `csharp`(dotnet), `aether`. Apps named
  `directed_graph_build_systems_are_cool` / `monorepos_rule` — it exists to
  exercise a real cross-module **DAG**.
- `.jar.ae` third-party deps (junit, hamcrest, junit-fetched), `.dist.ae`
  packaging (fat jars), `*tests/` test nodes per language.
- Built by `aeb`; its `.aeb/` holds the per-project SDK symlinks.

Good harness because the JVM DAG hammers exactly the plumbing that's the Axis-2
blocker, and the language spread surfaces per-SDK Windows quirks.

## The A/B method

**Invariants to compare** (bash `aeb` = baseline, `aeb-cli` = candidate),
building the same target set in a clean tree:
- exit code per target;
- the set of nodes built + their order (DAG honored);
- produced artifacts (paths + presence; optionally content hash);
- test pass/fail counts (the `[telemetry]` block);
- stdout of the `aeb synonym match:` / launch resolution lines.

### Phase 1 — Linux (proves facsimile fidelity, no Windows)

Run from the harness repo (`cd ../google-monorepo-sim`):

```sh
AEB=../aeb                    # the aeb repo, from inside google-monorepo-sim

# baseline: bash trampoline
$AEB/aeb <target>             # capture exit, target/ artifacts, telemetry

# candidate: pure-Aether entrypoint (after wiring the exec)
AEB_HOME=$(cd $AEB && pwd) $AEB/tools/aeb-cli <target>   # see wiring detail

# diff the two runs' artifacts + telemetry. Expect identical.
```

Start with a single leaf JVM node, then a cross-module node, then a whole-app
build, then the full repo. Land the harness as `ab.sh` (in `aeb`, run against
`../google-monorepo-sim`).

### Phase 2 — Windows MINGW (the cut-down target)

Same A/B on a MINGW box. Bash `aeb` is the baseline (it runs under MINGW);
`aeb-cli` is the candidate. Expect divergence first on the Axis-2 plumbing
(classpath separator), then path translation — fix forward, re-A/B.

## Ordered next steps

1. ~~**Wire `aeb-cli`'s `os.run_supervised` exec** of `aeb-main` (Axis 1).~~
   **DONE (2026-06-11).** The exec is wired (`tools/aeb-cli.ae` —
   `os.run_supervised(main_bin, argv, null, 1,1, timeout, 1)`), the
   `AEB_HOME`-from-`tools/` walk-up is handled, and the upstream blocker is
   gone: `os.run*` argv corruption for heap strings (**aether #688**) was
   FIXED in **ae 0.239.0** (the argv/env builders now route every
   `list_get_raw` result through `aether_string_data()` instead of a blind
   `(char*)` cast — same class as the glob-match mixed-repr fix). Verified
   end-to-end: a clean-Aether target builds with **IDENTICAL output +
   artifact set + exit code** under `aeb-cli` and the bash trampoline (only
   the wall-clock timing differs). The pure-Aether entrypoint is proven
   faithful for the base case.
2. ~~**Phase-1 A/B on Linux**~~ **DONE.** `ab.sh` landed (runs bash `aeb` +
   pure `aeb-cli` into separate scratch copies, diffs exit code + artifact
   tree + normalised telemetry JSON). Sweep: **6/6 PASS** across C + Rust
   targets of varying shape (c-hello, c-aether-spike-a/b, c-bootstrap-tool,
   rust-registry-crate, rust-workspace). The `--sandbox` prefix arm IS wired
   in aeb-cli (A/B-identical: same binary + "27 grants" line) and `--init` is
   handled (A/B-identical 46-entry .aeb/ scaffold). aeb-cli now covers the
   FULL bash surface: all 22 build flags (parser parity), supervised build
   exec, --sandbox, --version, --init.
   NB on the A/B bar: compiled binaries are compared by PRESENCE not bytes —
   the Aether→C→gcc toolchain isn't reproducible (embeds the abs source path;
   the same bash run twice yields different .o hashes), so byte-identity is a
   separate reproducible-builds concern, not a facsimile one. ab.sh content-
   compares only the text pointer-artifacts (root-path normalised).
3. **Classpath plumbing** (Axis-2 #1) — then re-run Phase-1 (still `:` on Linux,
   so must stay identical) as a regression gate.
   **Axis-2 IN PROGRESS — the POSIX-shell-on-Windows chokepoint (branch
   `feat/win-axis2-orchestrator`).** The core Windows-correctness mechanism is
   built + verified incrementally on winbaz:
   - **`build._sh` / `_sh_capture`** — the chokepoint. On Windows `os.system`
     runs via **cmd.exe**, which rejects every POSIX idiom (`>/dev/null`,
     `|sort`, `mkdir -p`, …). A MINGW box has `sh`, so `_sh` wraps each command
     `sh -c '<cmd>'`; passthrough on POSIX. Two subtleties found + fixed on the
     box: (a) `ae build -o foo.exe` double-suffixes to `foo.exe.exe` → split
     `_toolbase` (suffixless, for `-o`) from `_toolbin` (suffixed, for
     exists/run); (b) cmd.exe acts on `> < & | ^` *inside* the sh single-quotes
     → **caret-escape** them so they reach sh, not cmd.exe.
   - **aeb-main: DONE.** All shell-outs + helper-tool paths converted.
   - **aeb-link + gen-orchestrator + transform-ae: DONE.** The whole orchestrator
     LINK CHAIN now works on Windows — verified on winbaz 2026-06-12:
     **`target/_ae_build_all.exe` LINKS (525 KB PE32+ x86-64) and RUNS.** The
     fixes that got there, each found by tracing the real box:
       - aeb-link: chokepoint on all 13 sites; `.exe` split (`_toolbase` vs
         `_toolbin`); aetherc `--lib` as **repeated flags** not a `;`-joined
         value (a joined value gets re-split by sh as a statement separator —
         cmd.exe doesn't honour the wrap's quotes, sh does, so the `;` leaks);
         **dev-tree include fallback** (box has no `include/aether`, headers under
         `runtime/`+`std/`); **quote-free `sed -e s,^,-I,`** in the -I find (the
         `'s|^|-I|'` quotes collided with the chokepoint wrap → "unexpected EOF").
       - gen-orchestrator: `encode_name` was a `printf|sed` shell-out returning
         EMPTY on Windows → blank `extern (s: ptr)` → unparseable orchestrator.
         Replaced with **pure-Aether** `string_replace_all` (no shell).
       - transform-ae: routed its sed/`resolve-imports.sh` (a BASH script cmd.exe
         can't run → it HUNG) through the chokepoint; the multi-line prepend is
         now **pure Aether**. Dropped inner `'...'` quotes (they collide with the
         wrap; build paths have no spaces).
     **The cmd.exe∘sh quoting law learned:** on Windows `os.system` → cmd.exe →
     sh.exe. cmd.exe passes chars through but does NOT honour the POSIX `'\''`
     escape, so any EMBEDDED single quote inside the `sh -c '...'` wrap collides
     and sh aborts. Rule: inside the chokepoint, use NO inner single quotes and
     NO `;`-joined args — bare paths + repeated flags + quote-free sed.
   - **Axis-2 SDK execute layer — DONE.** The whole shell-out surface is
     converted: lib/c, lib/rust, +28 more SDKs, lib/build's helpers, lib/cache
     (pure fs), aeb-driver/aeb-cli/aeb-vet/aeb-trace, and the inline chokepoints
     in aeb-link + transform-ae. The ONLY direct os.system/os.exec left in lib/*
     is the chokepoint's own internals. ~330+ sites, every batch gated
     byte-identical on Linux (109/109).
   - **The chokepoint was HARDENED** to a temp-script mechanism: write the cmd
     to a %TMP% .sh, run `sh <nativepath>`. cmd.exe only ever sees `sh C:/…/x.sh`
     so it never parses the contents — quotes, `;`, redirects, AND
     spaces-in-paths all survive. This turned the SDK sweep into a pure
     os.system→build._sh swap (no per-command quote surgery). Verified on the
     box against the hardest command shape.
   - **BOTH Windows build modes green on winbaz:** in-process (AEB_IN_PROCESS=1)
     AND the default per-node path (aeb-driver + make). c-hello.exe builds + runs
     rc=0 in both. scan-ae-files (pure byte-wise sort) + topo-sort (pure stderr)
     also de-shelled — the last core-path shell-outs.
   - **Peripheral tools — Windows-reachable ones DONE.** aeb-init (inline
     chokepoint), aeb-query + affected-targets (pure sort -u), aeb-sbom +
     aeb-remote (build._sh_capture), and **aeb-agent** (all 15 sites: git prep /
     veto / build via chokepoint, rm→fs.delete, policy-bin .exe-suffixed) all
     converted + A/B/suite-green. **aeb-agent COMPILES + smoke-runs on winbaz**
     (682KB .exe, std.http server, --help works) — a bare-host Windows build
     agent is real. Marked MUCH-LATER (no current Windows need): gcheckout (git
     util), aeb-sandbox (Linux-ONLY — spawn_sandboxed refuses off Linux),
     mvn-to-aeb (migration util). Also future: aeb-agent's podman run_on /
     container-layering (can't run on Windows yet — bare-host path is done).
   - **Remaining Axis-2:** the bulk SDK-layer LIVE verification on Windows awaits
     the non-C language toolchains being installed on the box (winbaz has only
     gcc/sh/make today — see the prereq/install-prereqs feature, which exists to
     resolve+install exactly those per-OS).
4. **Phase-2 A/B on MINGW** — iterate path translation (#2) + per-SDK (#3).
   **Status (2026-06-12): Axis-1 PROVEN ON WINDOWS; now genuinely at the
   Axis-2 boundary.** Three upstream blockers were found on the box and all
   FIXED: **#688** (argv heap-string corruption), **#693** (stale
   `runtime/memory/memory.c` ref breaking dev-tree builds), and **#706**
   (`os.run*` Windows spawn — two parts: `lpApplicationName=NULL` so
   `CreateProcessW` PATH-resolves, *and* `build_command_line` aligned to the
   POSIX argv convention — `prog` is always argv[0], the caller's list is the
   args). With all three in (aether 0.243, branch
   `fix/win-spawn-application-name`), `os.run`/`run_capture`/`run_supervised`
   now spawn correctly on Windows.
   **The aeb-cli entrypoint works on Windows:** `aeb-cli.exe` spawns
   `aeb-main` via `os.run_supervised`, and — the A/B proof — **bash `aeb` and
   `aeb-cli` fail IDENTICALLY** at the same downstream point (entrypoint
   parity = Axis-1 proven on Windows, not just Linux).
   **What remains is pure Axis-2** (and bash `aeb` needs it too — it fails the
   same way): aeb-main shells out to its helper tools (`tools/extract-deps`
   etc.) via `os.system` with **forward-slash paths + no `.exe`**, which
   `cmd.exe` rejects (`'…/extract-deps' is not recognized`), plus
   `aeb-main: cannot write file`. So the next work is the orchestrator's
   Windows tool-invocation + path/`.exe` plumbing — independent of the
   entrypoint, shared by both runners.
5. **Feature-gate POSIX-only** (#4) so the cut-down fails honestly.

## Acceptance criteria

- **Axis 1 (facsimile):** `aeb-cli` and bash `aeb` produce identical artifacts +
  telemetry + exit codes building `../google-monorepo-sim` on Linux. → the
  pure-Aether aeb is proven faithful.
- **Axis 2 (MINGW):** the same A/B holds on Windows MINGW for the target set we
  commit to (JVM family first; other SDKs as they're shaken out).
- **Stretch:** full repo green on MINGW via `aeb-cli`, with the bash trampoline
  retired to a thin compatibility shim (or removed).

## Pointers

- Facsimile source: `tools/aeb-cli.ae` (+ `tools/aebcli/module.ae`).
- Tool chain (already pure Aether): `tools/aeb-{main,link,driver}.ae`,
  `tools/scan-ae-files.ae`, `tools/gen-orchestrator.ae`, `tools/transform-ae.ae`.
- Windows TODO detail: `TODO.md` §"Windows support (cut-down runner)".
- Supervision primitive reference:
  `../aether/examples/applications/build-supervisor.ae`.
- aeb orientation: `LLM.md`.
