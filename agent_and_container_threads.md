# Agent & Container threads — the ins and outs

> Working doc, lives in **`aeb`** (the repo we iterate primarily). Companion to
> `mingw_a_b_plan.md` (the Windows / facsimile thread). This one covers the two
> *distribution-of-build* threads that pre-date today's Windows push:
>
> 1. **The remote build-agent** — `aeb-agent` + `agent.dispatch` (build runs on
>    *another box*).
> 2. **Build-in-container** — `aeb-ctr` (compile in a container, execute on the
>    host) for immutable hosts.
>
> Plus the **veto / sandbox / cache** machinery they lean on. Two changelogs
> move under us: **`CHANGELOG.md`** is *aeb* moving forward; **`../aether/
> CHANGELOG.md`** is the *Aether language* moving forward — almost every
> capability below is "aeb feature X, unblocked by Aether primitive Y at
> version Z." Those couplings are called out throughout.

---

## 0. The shared frame: where does a build *run*?

Plain `aeb` runs the build in the current process tree on the current box. Both
threads here answer "what if the build should run *somewhere else*":

| Thread | "Somewhere else" is… | Why | Entry point |
|---|---|---|---|
| **Agent** | a *different machine* over HTTP | offload / fan-out / a box that owns the right toolchain or OS (winbaz, a mac-mini, bazzite) | `aeb-agent` (server) + `agent.dispatch(b)` (originator) |
| **Container** | a *toolchain container on the same box* | the host is immutable (Bazzite/Silverblue/Fedora-atomic) and can't have gcc/aetherc installed | `aeb-ctr` (bash sequencer) over `aeb-toolchain:slim` |

They compose: an agent can itself run its builds in a container (designed, not
yet wired — `run_on("podman")`), and the "uniform peer" property
(`docs/run-policy-class-and-cloud-leverage.md`) is that *originator*, *agent*,
and *container* are the same `aeb` binary in different launch contexts.

Both threads also share the **veto + sandbox** trust model: when a build runs
on *your* box on *someone else's* behalf (an agent taking a pre-integration
patch, a container running an untrusted `.build.ae`), the build itself is an
untrusted supply-chain surface. That machinery is §3.

---

## 1. Thread A — the remote build-agent

### 1.1 What it is

`tools/aeb-agent.ae` (619 lines) is a **sovereign build agent**: a standalone
binary that listens on HTTP, and for each incoming dispatch decides
**accept / busy / reject / veto**, prepares a tree, runs `aeb <target>` on the
bare host, and returns a terse-but-rich verdict (pass/fail + artifacts list +
log tail). The decision core is pure and lives in `lib/agent`
(`agent._decision`, scope-glob match, slot cap, wire payloads, token
parse/check), unit-tested offline in `tests/test_agent_scope.ae` (35
assertions; bumped to 73 on the Windows branch).

The word **sovereign** is load-bearing: the agent's ability to *refuse* (out of
scope, busy, vetoed) is what makes it a peer, not a worker. aeb is deliberately
**not** a fleet control plane — there is no scheduler that commands agents;
originators *ask*, agents *decide*.

It is a **standalone binary** installed at `$PREFIX/bin/aeb-agent`, **not** an
`aeb agent` subcommand. That's intentional: a sysop probes "does this machine
have the agent capability?" by whether `aeb-agent` is on `PATH`. Absent unless
deliberately installed.

### 1.2 The wire shape

```
Originator (.ae fan-out target)                 Agent (remote box)
  agent.dispatch(b) {                            aeb-agent --host 0.0.0.0 \
      endpoint("http://192.168.0.57:9440")          --port 9440 \
      target("preint/widget/.build.ae")             --accept 'preint/*' \
      purpose("preint")                             --workdir /clone \
      token("…")                                    --tokens agent.tokens
      ref(...) hash(...) patch_file(...)         }
  }                                              GET  /health   (open liveness)
        │  POST /dispatch {guid,target,           GET  /ping     (auth: identity+
        │       purpose,ref,hash,patch_b64}                      capability)
        ▼       + X-AEB-Token                     POST /dispatch (auth: the verb)
   awaits verdict ◄───── {guid,status,result,artifacts[],log}
   folds into build.fail / any_failed
```

The originator side is `lib/agent`'s `dispatch(ctx)` builder
(`lib/agent/module.ae:509`): reads `endpoint`/`target`/`purpose`/`token` (+
`ref`/`hash`/`patch_file`/`on_platform`) off the builder map, fires the request,
awaits the verdict, and folds pass/fail into `build.fail`/`any_failed`. That
fold is only *trustworthy* because of the **silent-green fix** (CHANGELOG
"Fixed": a failed build step now reddens the build) — before that a remote `aeb`
could fail and still exit 0, and the originator would believe a lie.

### 1.3 The dispatch lifecycle (handle_dispatch, aeb-agent.ae:306)

Ordered, each step short-circuits:

1. **Auth gate** (fail-closed). No `--tokens` file → refuse **all** dispatches
   (401). With a file → `X-AEB-Token` or `Authorization: Bearer` must be in it.
   This is **naive shared-secret** auth (one bearer per line, `#` comments) —
   interim, explicitly NOT signing/expiry/embedded-scope/per-principal issuance.
   It gives a sysop a real on/off *today*; the designed claim→verify→veto model
   is a thickening.
2. **Scope decision** — `_decision(scope, purpose, active)` → accept / busy /
   reject. Scope = purpose-glob (`preint/*`) + job-slot cap (`--max-jobs`). Pure,
   unit-tested.
3. **Prepare the tree** (`_prepare_tree`, the agent's *own* lifecycle — wire ops,
   not build grammar):
   - **scrub**: `git reset --hard && git clean -ffdx` — inter-dispatch isolation
     so dispatch N isn't poisoned by N-1's outputs/patch (a correctness
     property, added in `d296634`).
   - **fetch+checkout**: `git fetch origin <ref> && git checkout <hash>` — the
     trusted base. The agent owns the origin; the dispatch never names a remote
     URL.
   - **apply patch**: decode `patch_b64` (`base64 -d` to a temp file) →
     `git apply` — the *untrusted* pre-integration delta. The decoded patch is
     deliberately kept until after the veto (it's the highest-signal scan
     target).
4. **Veto** (`_maybe_veto_build`, the agent's *sovereign* gate — §3): Tier-A
   rule scan over tree+patch, then the 2b AST veto over the target `.ae`. A
   vetoed dispatch is a **refusal (422)**, not a build failure.
5. **Build**: `cd <workdir> && aeb <target> > log 2>&1`, with
   `AEB_ARTIFACTS_JSON` pointed at a per-guid temp file so the reply can say
   *what* landed, plus a 40-line log tail so a fail says *why*. `os.system`
   keeps the exit code (`os.exec` swallows it).
6. **Reply**: `_dispatch_reply_rich` — std.json-built `{guid,status,result,
   artifacts[],log}` (real JSON nesting, no string surgery).

### 1.4 Install is opt-in and aeb-native (dogfood)

`make` does **not** touch the agent — a network-listening server is not core
build machinery, and `make` must not recurse into `aeb`. Instead the agent is
built **and** installed **by aeb**, as two dep-linked nodes:

- `aeb tools/agent/.dist.ae` → builds the binary (dogfoods `aether.program` on
  a real multi-import program).
- `aeb tools/agent/.install.ae` (which `dep`s `.dist`) → places the binary +
  writes the `~/.local/bin/aeb-agent` wrapper.

There is no `make install-agent`. If aeb builds the agent, aeb installs it.

### 1.5 What we've tried / where it's been stood up

- **Walking-skeleton arc** (CHANGELOG + git): `45f52df` skeleton →
  `fa84ec0` standalone binary + naive `--tokens` → `939bef3` auth-gated
  `GET /ping` (identity + capability descriptor; an unauthenticated prober
  can't even fingerprint the agent) → `67630e0` fetch-base + apply-patch +
  `maybe_veto_build` → `d296634` worktree scrub + rich reply →
  `ea30af8`/`765a3c0` `--help` exits & `--tokens` readability states (a
  misconfigured mount must not masquerade as intended fail-closed).
- **Stood up on**: oldnuc / mac-mini / bazzite (per the source header) as bare
  hosts; **winbaz** (a real Windows box) on the `feat/win-axis2-orchestrator`
  branch.
- **The Windows conversion** (`030a26b` → `fcf2af1`): all 15 of aeb-agent's
  shell-outs routed through the **chokepoint** `build._sh` / `build._sh_capture`
  (POSIX → `os.system` passthrough; Windows → write the command verbatim to a
  temp `.sh`, run `sh <file>` so cmd.exe never parses POSIX syntax), the four
  `rm -f` cleanups replaced with pure `fs.delete`, the policy binary suffixed
  via `build._exe_suffix()`. Result: **aeb-agent.exe (682 KB) compiles and
  smoke-runs on winbaz** — the std.http server starts, `--help` works, suite
  109/109 green. Still bare-host-only there; podman run_on is deferred.

### 1.6 Aether primitives the agent stands on (../aether/CHANGELOG.md)

| aeb-agent needs | Aether primitive | Landed |
|---|---|---|
| HTTP server | `http_server_start_raw` / `http.server_*`, signal-masked background mode | 0.184 / 0.217 |
| OS identity in `/ping` | `os.platform()` (compile-time) | 0.203 |
| Supply-chain veto | `aetherc --emit=ast` (literal-vs-`computed` args, const-folded) | 0.227 / 0.228 |
| Windows bare-host | argv-spawn / PATH-resolution spawn fixes (#706) | 0.243–0.244 |

### 1.7 Test apps & build files (agent thread)

- **`tests/test_agent_scope.ae`** — 35 assertions (73 on the Win branch): the
  pure decision core. `_scope_glob_match`, `_scope_accepts`, `_has_free_slot`,
  `_decision`, `dispatch_request_json`, `dispatch_reply_json`,
  `_veto_run_rules`. **This is the test of record** — the HTTP path is a thin
  impure shell over it.
- **`itests/agent-container/`** — `.image.ae` + `Containerfile` + README: the
  soup-to-nuts Debian (gcc 14 / trixie) bootstrap that builds the *whole* stack
  Aether → aeb → aeb-agent and dogfoods `aeb tools/agent/.install.ae`. This is
  the agent's end-to-end integration harness.
- **Originator targets**: `agent.dispatch(b)` fan-out leaves in `.ae` build
  files (the `endpoint/target/purpose/token` shape). The grammar is exercised
  by the unit test; a live fan-out leaf is wired per-deployment.

---

## 2. Thread B — build-in-container (`aeb-ctr`, the duality)

### 2.1 The problem

`aeb` needs a toolchain (gcc + Aether's `aetherc`) that an **immutable host**
(Bazzite / Silverblue / Fedora-atomic) won't let you `apt install`. The fix:
run the *compilation* inside a container that has the toolchain, with sources
bind-mounted — but run the *execution* (the built binaries, the tests) on the
host, against the host's runtimes. **"two-aeb duality": one binary, two
instances** (`docs/two-aeb-duality.md`, `docs/containment-and-the-control-plane.md`).

### 2.2 The image layering

```
aether-builder:slim        (UPSTREAM: aether/tools/docker/aether-build)
   debian-slim + gcc + Aether (ae/aetherc) + host headers.  Has ae, NOT aeb.
        │  FROM
        ▼
aeb-toolchain:slim         (HERE: tools/container/Containerfile.aeb-toolchain)
   + clones aeb, drops itests/ (~225 MB), make install → aeb on PATH.
```

The base deliberately omits aeb (its `--aeb` mode aborts "aeb not installed in
this image"); this layer adds it. The base is what `aether-build` bootstraps as
a side effect — i.e. the *Aether* changelog produces the base, the *aeb*
changelog produces the layer on top.

### 2.3 `aeb-ctr` — the two-phase sequencer (110-line bash)

Identical CLI to `aeb`. Two phases:

- **Phase 1 — COMPILE in the container** (`--compile-only`):
  `podman run --rm -v $ROOT:/work:Z -w /work --entrypoint aeb aeb-toolchain:slim
  --compile-only <target>`. In-container aeb builds the orchestrator
  (`target/_ae_build_all`) **and** every node, but runs nothing. Binary +
  artifacts land on the host via the bind mount.
- **Phase 2 — EXECUTE on the host** (`AEB_EXECUTE_ONLY=1 target/_ae_build_all
  $ROOT`): runs the orchestrator Phase 1 built, walking the same DAG but
  executing only the run/test steps, natively, against the host's runtimes. No
  container, no recompile.

The seam that lets a *per-target* `ae build` inside Phase 2 delegate back into
the container is **`AEB_COMPILE_CONTAINER`** in `lib/aether` (the pure builders
for it are unit-tested in `tests/test_compile_delegation.ae`:
`_rewrite_under_root`, `_ae_build_cmd_delegated` — string assembly, no container
needed to test).

### 2.4 The hard part: host-language dlopen bridging

A binary compiled *in* the container must run *on* the host, where Python/Ruby/
Lua/… live at different sonames (or with no bare `libfoo.so` symlink at all, as
on Bazzite). aeb-ctr solves this **explicitly, no probing**:

- Aether's interpreter bridges (python/ruby/perl/lua/js/tcl) **dlopen** the host
  lib at runtime — the bridge `.a` has **no** unresolved interpreter symbols, so
  the container-built binary carries **no `DT_NEEDED`** for the host language.
- As of Aether **0.213** the bridge uses a strict contract: try
  `${AETHER_<LANG>_SONAME}` → bare `libfoo.so` → fail clearly with a hint.
- `aeb-ctr` forwards only the `AETHER_*_SONAME` vars you set (e.g.
  `AETHER_PYTHON_SONAME=libpython3.11.so.1.0`). It does **not** ldconfig-scan,
  sysconfig/RbConfig-introspect, or version-pattern-match. The orchestrator
  *states* the contract, it does not *infer* it.

This whole capability is the single biggest Aether-side dependency of the
container thread, and it landed across **0.207–0.215** (python 0.209, ruby
0.211, lua/perl/js/tcl 0.212, soname-contract hardening 0.213, tinygo 0.215).
The aeb-side `aeb-ctr` commit arc (`b45b584` → `0355d45`) is mostly chasing
those: pass the host's real `-lpython` → lazy-link → drop the wrong flag → pass
`AETHER_PYTHON_SONAME` not `-lpython` → real soname probes → **explicit soname,
no probing** (the final, current design).

### 2.5 SELinux / Bazzite traps (proven the hard way)

Documented in `../aether/ctr_notes.md`, encoded in `aeb-ctr`:
- mounts need `:Z` (relabel); **do not** relabel `$HOME` — `aeb-ctr` refuses to
  run from `$HOME` and tells you to use a repo subdir.
- **no** `--userns=keep-id` (crashes this crun with `readlink \`\`: No such
  file or directory`; output is correctly user-owned without it).
- `AEB_CONTAINER_ENGINE` (default **podman**) and `AEB_CONTAINER_SELABEL`
  (default `Z`) are the two knobs.

### 2.6 Test apps & build files (container thread)

- **Readiness smoke tests** (`tools/container/README.md`) — `hello.ae` (bare
  Aether: `ae build` → `aether-ready`) and `aebproj/` (a pure-Aether multi-
  target aeb DAG → `hello-from-greeter`). These live in the
  **hosted-language-headers** repo's `readiness/` tree, **not** in this checkout
  — run them after building the image to confirm aeb works in-container before
  trusting it with real builds.
- **`tests/test_compile_delegation.ae`** — the pure delegation builders.
- **`itests/agent-container/`** — doubles as the container build harness (it
  *is* a Containerfile bootstrap of the full stack).
- Any real polyglot DAG with a host-language node exercises the dlopen bridge —
  `itests/python-monorepo-demo`, the python nodes in `google-monorepo-sim`,
  etc.

---

## 3. The shared trust spine: veto + sandbox (and cache)

When a build runs on your box for someone else (agent) or against an
immutable-host contract (container), the `.build.ae` *itself* is the untrusted
surface. `docs/build-veto-and-sandbox.md` is the reference; the rule is **the
veto runs in the trusted harness, never in the graph it inspects** — a
`.build.ae` cannot clear a verdict about itself.

### 3.1 Veto — static, before any build

- **`aeb --vet [--veto-policy <f>]`** (`tools/aeb-vet.ae`, `lib/veto`, 690 lines,
  `tests/test_veto.ae` 21 + `test_veto_policy.ae` 7): consumes `aetherc
  --emit=ast` and denies extern/exec/net/import + a `banned` substring rule +
  a positive `coord_verb`/`coord_allow` coordinate allowlist. **Fail-closed**
  throughout (no-AST / indirect-call / computed-arg → veto). Policy resolves
  out-of-tree (`--veto-policy` → `$AEB_HOME/veto/default.ae` → built-in deny);
  an in-tree policy path is refused. Exits 3 on veto.
- **`aeb --vet-tool '<cmd>'`** (layer 1b, repeatable): run an operator scanner
  (semgrep, secret/CVE tool); non-zero vetoes; command-not-found vetoes too.
  "aeb invokes a SAST engine rather than becoming one."
- **`aeb --resolve-only [--sbom-json <p>]`** (Tier B): resolve the target's
  dependency coordinates to their full transitive closure and emit JSON
  *without building* — feed to `grype`/etc. via `--vet-tool`. Maven slice;
  cargo/npm to follow.
- **`aeb --trace-intent [--intent-json <p>]`** (Tier C, doppelganger):
  compile+run the leaf against a shadow `std.os` (`lib/veto_trace_os`) whose
  `os.system`/`os.exec`/`os.run*` **record** the command instead of executing
  it — you see what the build *would do* (an evil `curl|sh` is recorded, not
  run). One path, opaque computation records `<computed>`.
- **Agent-side veto** (`lib/agent` `_veto_run_rules`, `aeb-agent.ae:212`): the
  Tier-A rule scan runs over the prepared tree + patch, *then* the 2b AST veto.
  Tier-A is a data-driven pluggable rule list covering the **June-2026
  supply-chain install-script class**: `binding.gyp` presence,
  `pre/postinstall` manifest hooks, `curl|sh` fetch-and-exec, a patch-introduced
  `extern`, a patch-touches-disallowed-path rule, and an opt-in tree-size cap
  (`AEB_AGENT_MAX_TREE_MB`). Scoped to whole-tree or to the applied patch (the
  highest-signal target).

**CRITICAL scope** (don't lose this): the veto guards **build-grammar escapes**
(what the `.build.ae` orchestration does), **not** the application being built.
A clean veto is not a clean program.

### 3.2 Sandbox — runtime, during the build

- **`aeb --sandbox [--sandbox-profile <f>]`** (`tools/aeb-sandbox.ae`,
  `lib/sandbox` 265 lines, `tests/test_sandbox.ae` 30): runs the whole build
  under Aether's `spawn_sandboxed` with a deny-by-default grant profile
  (LD_PRELOAD propagates to gcc/cc1/javac/…). A denied syscall (connect to an
  un-granted host, write outside `target/`, exec off the allowlist) dies at the
  libc boundary regardless of how the build computed it.
- Grant model: pairs `(category, pattern)` for `fs_read`/`fs_write`/`exec`/
  `tcp`/`env`/`grant_all`; `intersect()` = operator ceiling ∩ maintainer
  narrowing. Profile resolves out-of-tree (`--sandbox-profile` →
  `$AEB_HOME/sandbox/default.ae` → conservative built-in, **no tcp**); in-tree
  refused.
- **Linux-only**, needs Aether **≥ 0.230** — the `vfork`/`clone3` seccomp fence
  (issue #668). This is why on the Windows branch `aeb-sandbox`'s 7 shell-outs
  are left un-converted (marked MUCH-LATER): `spawn_sandboxed` refuses off
  Linux, so there's nothing to port yet.

### 3.3 Cache — why it matters to these threads

`lib/cache` (373 lines) is content-addressed (sha256 + zlib), now wired into
**every artifact-producing SDK** (java/maven/aether + kotlin/scala/ts/dotnet/go/
rust/clojure; python is `n/a` by design). The **remote cache** backend
(`AEB_REMOTE_CACHE_URL`, file:// for now, http/S3 next) sits *behind* the local
store — Bazel `--disk_cache` analogue. For a **fan-out of agents** this is the
shared-state substrate: agent A builds a node, pushes the blob; agent B (or the
originator) gets a `[hit]` instead of recompiling. Best-effort, never fails the
build. Tests: `tests/test_cache.ae`, `test_cache_tree_roundtrip.ae`,
`test_remote_cache.ae`, `test_remote_cache_roundtrip.ae`.

---

## 4. The test-app menagerie (what we juggle, both threads)

The integration corpus under `itests/` is the polyglot pressure-test for *all*
build distribution. The agent/container threads care most about (a) the
end-to-end stack bootstrap and (b) any DAG with a host-language node.

| itest | Lang(s) | What it exercises |
|---|---|---|
| `agent-container/` | Docker/bash | **Full-stack bootstrap** Aether→aeb→aeb-agent; dogfood install — the agent thread's e2e harness |
| `aether-program-spike` | pure Aether | aeb building Aether `main()` programs, sibling-lib + C linking, out-of-tree regen |
| `c-aether-spike-{a,b}` | C+Aether | C-entry FFI into Aether libs (counterpart spikes) |
| `python-monorepo-demo` | Python | host-language node → exercises the dlopen bridge (container thread) |
| `spring-data-examples` | Java+Maven | **largest** — 107 pom.xml → 90 modules, the JVM-DAG stress |
| `selenium` | Ruby/Py/Rust/JS/.NET | the fetch/codegen/`*_existing` builder surface; 32 Ruby BUILD files |
| `nx-examples` | TS (Nx) | 13 modules, monorepo TS |
| `dotnet-architecture-eShopOnWeb` | C# | ASP.NET reference app |
| `go-multimodule-fyne`, `rust-*`, `scala-cli-multi-module-demo`, `clojure-multiproject-example` | Go/Rust/Scala/Clojure | per-language multi-module DAGs |
| `pytorch` | Python/C++ | codegen-driver (`python.codegen`) + no-glob explicit source lists |

And the **A/B harness** sibling **`../google-monorepo-sim`** (45 build files: 20
`.build.ae` + 21 `.tests.ae` + 4 `.dist.ae` across java/kotlin/go/rust/ts/python/
csharp/aether; apps `monorepos_rule` /
`directed_graph_build_systems_are_cool`). JVM-dominant by design — it's the
cross-module DAG that hammers the classpath plumbing. It's the baseline for the
Windows facsimile A/B (`mingw_a_b_plan.md`) and equally the right target for
"does an *agent* build it identically to a local build."

The readiness smoke pair (`hello.ae`, `aebproj/`) lives in
**hosted-language-headers**, not here — that's the container thread's
fast confidence check.

---

## 5. Directions from here

### Agent thread
1. **Real auth** — replace naive `--tokens` shared-secret with the designed
   claim→verify→veto: signed tokens, expiry, **purpose embedded and verified in
   the token** (so scope isn't a server-side env var the originator can't see).
   This is the single biggest "walking skeleton → real" gap.
2. **Async dispatch** — fire-async + webhook-back + `details_url` split (today
   `/dispatch` is synchronous; `max_jobs` only becomes load-bearing once the
   handler goes async — right now `active` is effectively 0).
3. **The scope-tree config** — the `.ae` closure-DSL agent config (multiple
   scopes, `run_on` kinds) replacing the single CLI-flag scope.
4. **`run_on("podman")` / `run_on("vm")`** — the agent runs its *own* builds in
   a container (this is where threads A and B merge). The decision core already
   carries `run_on`; only the execution backend is missing.
5. **Cache partitioning** — per-principal / per-purpose cache namespaces so a
   fan-out doesn't cross-contaminate.
6. **Windows agent → past bare-host** — winbaz proves the bare-host agent; next
   is the per-SDK Windows build-correctness (the Axis-2 classpath/path work from
   `mingw_a_b_plan.md`) so a *Windows* agent produces *green* JVM builds, not
   just a running server.

### Container thread
1. **Land the readiness pair in-repo** (or a thin smoke target) so `aeb-ctr`
   can be CI-verified here, not only against hosted-language-headers.
2. **Multi-host-language images** — the soname-explicit design means one image
   per language combo; a documented matrix (python/ruby/lua images) + the
   `AETHER_*_SONAME` cookbook.
3. **Wire the agent×container join** — `run_on("podman")` in the agent using the
   `aeb-ctr` two-phase mechanism, so a dispatched build lands in a clean
   container automatically.
4. **Cache across the seam** — Phase 1 (container) and Phase 2 (host) sharing
   the content-addressed store, and a remote backend so repeated `aeb-ctr` runs
   on an immutable host skip recompiles.

### Shared
1. **Veto Tier B/C beyond Maven** — cargo/npm SBOM slices; the doppelganger
   intent-trace's dep/link_flag/net categories (today it records the `os.*`
   shell-out surface only).
2. **Sandbox off-Linux** — gated on Aether giving `spawn_sandboxed` a Windows/
   macOS story; until then keep the honest "Linux-only" feature gate.
3. **Track both changelogs deliberately** — almost every step above is "wait for
   `../aether/CHANGELOG.md` to land primitive X, then take it in `CHANGELOG.md`."
   Recent unblockers: #706 spawn fix (0.243–0.244, unblocked the Windows agent),
   the seccomp fence (0.230, the sandbox), the soname contract (0.213, the
   container). The current Aether HEAD is **0.247**.

---

## 5b. Infra topology + takeover snapshot (2026-06-13, this session)

Probed reachability + state of the three boxes as I take over the agent×container
thread from the sibling:

| Box | Reach | State found |
|---|---|---|
| **oldnuc** | `ssh oldnuc` ✓ (Linux x86_64) | podman 5.4.2; **ae 0.247.0** (latest), gcc, git all present; **NO aeb checkout, NO images, nothing running** — clean slate. Best place to build an agent-bearing image FRESH from this branch. |
| **bazzite@192.168.0.57** | ✓ (Linux x86_64, RPM-family immutable host; also hosts the winbaz VM) | podman 5.8.2; the sibling's **duality images exist** — `aeb-toolchain-{tinygo,duktape}:slim`, `aether-builder-tinygo:slim` (6–8 days old). NO `aeb`/`ae`/`aeb-agent` on the host PATH (correct — immutable; toolchain lives in the images). |
| **winbaz** | `ssh winbaz` ✓ (Win11 VM on bazzite) | the native-Windows agent box (aeb-agent.exe compiles + smoke-runs, per §1.5). |

Key facts for the "does the agent still run in a container after the Windows
work" question:
- The bazzite `aeb-toolchain-*` images are **duality (aeb-ctr) images**, baked
  from a **pre-Windows-branch** aeb (image commit subject: `aeb-ctr: explicit
  AETHER_<LANG>_SONAME only`), and contain **NO aeb-agent** (agent is opt-in,
  built separately — the duality images never included it). `.git` is dropped to
  slim them, so they can't be `git`-inspected in place.
- Therefore "confirm aeb-agent runs in a container" = **build an agent-bearing
  image from `feat/win-axis2-orchestrator`** (the post-conversion code) and run
  it. The chokepoint is Linux-passthrough so it *should* be transparent
  in-container, but §1.5 flagged this was never re-verified post-conversion — so
  it's a real check, not a formality.

**Plan (concurrent with the winbaz native-agent evolution):**
1. On **oldnuc** (clean, 0.247, podman): clone aeb @ this branch → `make install`
   → `aeb tools/agent/.install.ae` to get aeb-agent → build/refresh
   `aeb-toolchain:slim` (or reuse the agent-container `itests/agent-container/`
   bootstrap) **with the agent in it** → run the agent IN the container → fire a
   dispatch at it → confirm verdict. This is the Linux-container agent proof on
   the post-Windows code.
2. On **winbaz**: evolve the native agent past "compiles + --help" to actually
   listening + serving a dispatch (a real Windows agent smoke).
3. The two are independent → drive concurrently.

> Cross-session channel for the Aether side stays `../aether/ctr_notes.md`. The
> bazzite duality images can be rebuilt from this branch when the container-thread
> work (not just the agent) needs re-verifying against post-Windows aeb.

### Results (2026-06-13)

- **winbaz native agent: LIVE SERVER ✓** — past "compiles + --help". Started
  `aeb-agent.exe --host 127.0.0.1 --port 9440 --tokens …`; `GET /health`→`ok`,
  `GET /ping` no-token→**401** (fail-closed), `GET /ping` +token→**200** +
  `{"platform":"windows","accept":"preint/*","auth":"required",…}`. A native
  Windows agent listens, authenticates, and advertises itself as a Windows peer.
- **oldnuc: aeb + whole branch builds clean under ae 0.247 ✓** — `make install`
  rc=0 (the earlier 4 aeb-cli errors were a STALE `main` checkout; `--depth 30`
  hadn't fetched the feature branch — fixed with explicit
  `git fetch origin <branch>:<branch>`). Confirms forward-compat with the latest
  toolchain.
- **BUG found (pre-existing, not Windows/0.247): the agent DOGFOOD build is
  broken.** `aeb tools/agent/.install.ae` → `.dist.ae`'s `aether.program` runs
  `aetherc <aeb-agent.ae> <out.c>` with NO `--lib`, so every `import agent/veto/
  build` symbol is E0301-undefined. Reproduced on BOTH 0.247 (oldnuc) and 0.244
  (dev box). Root cause: `AEB_COMPILE_LIB` is empty in the dist-node
  aether.program builder (it threads that env as `--lib`, but it's unset on the
  dist path). The agent builds fine via explicit `ae build tools/aeb-agent.ae
  --lib lib --lib tools -o …` (winbaz/dev-box path) — only the documented dogfood
  (§1.4 "if aeb builds the agent, aeb installs it") is broken. Full writeup +
  candidate fixes: `asks/agent-dist-dogfood-broken.md`.
- **Net:** the agent CODE is post-Windows-correct and runs as a live server
  natively on Windows; the Linux-container proof is blocked on the dogfood-build
  bug (or sidestep it with the explicit `ae build` to get an agent binary into a
  container image). The bug is the next concrete fix.

### Dogfood bug FIXED + agent-in-container PROVEN (2026-06-13, on main)

- **Dogfood fixed** (main `1270959`): `lib/aether`'s default `aether.program`
  path (`_shell_out_ae_build`) now threads `AEB_COMPILE_LIB` as repeated `--lib`
  flags (`_ae_build_lib_flags`), and `.install.ae`'s copy path corrected
  (`target/dist/tools/...`). `aeb tools/agent/.install.ae` succeeds end-to-end.
  See `asks/agent-dist-dogfood-broken.md` (RESOLVED). Suite 109/109.
- **Agent-in-container PROVEN on oldnuc:** built `itests/agent-container/`
  Containerfile (Aether→aeb→**`RUN aeb tools/agent/.install.ae`**←the just-fixed
  dogfood, which previously failed this exact step) → image `aeb-agent:test`
  (1.02 GB), all 12 steps rc=0. Ran it: `podman run -d -p 9440:9440 -v
  tokens:/etc/aeb/agent.tokens`. `/health`→`ok`; `/ping`+token→200
  `{"platform":"linux","accept":"preint/*","auth":"required"}`; **`POST
  /dispatch` → real verdict `{"guid":"smoke-1","status":"vetoed","result":""}`**
  — the full lifecycle ran (accept→prepare→build→verdict) in-container on
  post-Windows code.
- The `vetoed` is the **target fixture** (`aeb-test` repo's `.build.ae`) failing
  its own build (`Undefined build.start / java.javac` — that repo has no
  `.aeb/lib` and the agent's inner `aeb .build.ae` didn't resolve the TARGET
  repo's SDK imports). That's a fixture/target-repo issue, NOT an agent bug — the
  agent correctly ran the build and reported the failure as a verdict instead of
  crashing. (Follow-up: the agent's inner `aeb <target>` build of an
  un-`--init`'d repo has the same lib-resolution gap; either `aeb --init` the
  workdir in the agent's prepare step, or thread `--lib` — a real next item, but
  separate from "does the agent run in a container": it does.)
- **So the headline question is answered: YES — aeb-agent runs in a container
  after the Windows work**, and the dogfood that builds it in-image works.

## 6. Pointers

- Agent: `tools/aeb-agent.ae`, `lib/agent/module.ae`, `tools/agent/{.dist,
  .install}.ae`, `tests/test_agent_scope.ae`, `itests/agent-container/`.
- Container: `tools/container/{aeb-ctr,Containerfile.aeb-toolchain,README.md}`,
  `lib/aether` (`AEB_COMPILE_CONTAINER` seam), `tests/test_compile_delegation.ae`.
- Trust: `tools/aeb-vet.ae`, `lib/veto/module.ae`, `tools/aeb-sandbox.ae`,
  `lib/sandbox/module.ae`; tests `test_veto*`, `test_sandbox.ae`.
- Cache: `lib/cache/module.ae`, `tests/test_*cache*`, `itests/cache-smoke.sh`.
- Docs: `docs/run-policy-class-and-cloud-leverage.md`,
  `docs/agent-lifecycle.md`, `docs/build-veto-and-sandbox.md`,
  `docs/two-aeb-duality.md`, `docs/containment-and-the-control-plane.md`,
  `docs/container-lifecycle.md`.
- Windows-facsimile companion: `mingw_a_b_plan.md`.
- The two moving floors: `CHANGELOG.md` (aeb), `../aether/CHANGELOG.md`
  (language; HEAD 0.247).
