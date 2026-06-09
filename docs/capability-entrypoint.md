# The capability entrypoint — `aeb(cap)` as a hosted Aether lib

**Status:** design (2026-06-09). Core mechanism proven end-to-end (see
"Round-trip proof" below); no aether change required. Implementation
(transform/host wiring + the LD_PRELOAD enforcement) not yet built.

This is the entrypoint model for the per-node sandbox — layer 3 of
[build-veto-and-sandbox.md](build-veto-and-sandbox.md). It supersedes the
earlier "rewrite `main()`" and "link a trusted `main`" sketches: those
solved a problem that only exists if a build file is a **standalone OS
binary**, which aeb never produces.

## The reframe

A `.build.ae` is only forced to have a `main()` if you intend to run it as
an executable — `./.build` / `.build.exe`. But aeb never does that. The
invocation is **always** `aeb .build.ae`, with `aeb` as the host. So the
build file doesn't need to be a binary at all: it can be an
**Aether-idiomatic library** whose exported function aeb calls in-process —
exactly the model aeb already uses for every SDK (`lib/build`, `lib/rust`,
… are imported `.ae` modules whose functions aeb invokes).

Concretely, the build file's entrypoint becomes a plain exported function:

```aether
// .build.ae — no main(); a hosted entrypoint that RECEIVES a capability.
aeb(cap) {
    b = build.start()
    rust.cargo_project(b) { crate_name("demo") }
}
```

and aeb (the trusted host) **mints the capability and calls `aeb(cap)`**:

```
cap  = <operator grant set, constructed in aeb's own trusted code>
rc   = <buildfile>.aeb(cap)        // in-process Aether lib call
```

`main` was a red herring. The build file is a **library aeb hosts**, not a
**binary aeb launches**.

## Why this needs no aether change

Aether already ships `aetherc --emit=lib`, whose codegen explicitly
**suppresses the C `int main(int,char**)` entry point** — library consumers
call the exported top-level functions directly, not `main()`. (From
`compiler/codegen/codegen.c::generate_main_function`: *"--emit=lib only:
suppress the C `int main` entry point … library consumers call the exported
top-level functions directly, not main()."*) And one `.ae` importing and
calling another `.ae`'s top-level function in-process is the ordinary module
mechanism aeb uses everywhere.

So `aeb(cap)` is just **a lib export aeb calls with an argument** — the same
shape as `build.start()`. The binary-`main` entrypoint was the only thing
that ever demanded a language-level change; remove it and the requirement
vanishes.

## Round-trip proof (2026-06-09)

Run against the installed toolchain (`ae 0.227.0`). A host `.ae` mints a
capability, imports a build module, and calls its exported `aeb(cap)`
in-process:

- **Host calls imported `aeb(cap)`** → the build function ran in-process and
  received the host-minted capability (4 grant-tokens it did not construct),
  read it, returned. No `main` in the build file. ✓
- **Build file also declares a legacy `main()`** → when hosted (imported and
  called via `aeb(cap)`), the legacy `main()` **never runs** — only the
  function the host explicitly calls executes. No error, no leak. A stray
  `main()` is harmless dead code under hosting. ✓
- **Build file forges its own `cap` list** → trivially possible: a `list` is
  just data, `list.new()` + `list.add(…, "tcp", "evil.com")` succeeds. **This
  is the load-bearing finding** (see next section). ✓

## The two layers — grammar vs. enforcement

The forge result above is the crux: **the grant list is NOT the security
boundary.** If authority were "the list the build holds," untrusted code
mints authority by calling `list.new()`. So the design is explicitly
two-layered, and only the second layer is a fence:

1. **Grammar layer — `aeb(cap)` + the grant verbs.** `cap` is the build's
   *declared envelope*: the build reads it, may *narrow* it, runs its body.
   This layer is for honesty and ergonomics — it lets a build say "I need
   `crates.io`" in readable form, and lets the veto see that declaration.
   It is **not** trusted to enforce anything. A forged `cap` list grants
   nothing real.

2. **Enforcement layer — `spawn_sandboxed` + `LD_PRELOAD`.** The *actual*
   authority is the operator grant set the **host** serialises into POSIX
   shared memory and enforces via the `libaether_sandbox` preload at the
   libc syscall boundary (`open`/`connect`/`execve`/…), propagated to the
   whole process subtree through the child's env. The build file **cannot
   construct this** — it is established by the host, at fork time, in SHM the
   build can't rewrite. A build that forges `cap = [tcp, evil.com]` still
   dies at the `connect()` interceptor, because the *real* grants in SHM do
   not include it.

> **Policy can be fooled by opacity; the LD_PRELOAD interceptor sees the
> actual syscall.** The `aeb(cap)` grammar is the honest layer; the preload
> is the layer that cannot be lied to. Both run — a build has to beat both.

This mirrors Aether's own two sandbox shapes: in-process
`run_sandboxed(perms){}` (the grammar/declaration side) and cross-process
`spawn_sandboxed(grants, …)` (the enforcement side).

## The capability comes from the host, structurally

The whole point of `aeb(cap)` over the earlier "build declares its own
grants" forms: **provenance is in the call.** aeb calls `aeb(cap)` — `cap`
is minted in aeb's process, in aeb's trusted code, and *handed in*. The
untrusted file literally cannot produce the enforced capability; it can only
receive the parameter. This is the original `main(priorSandboxDefn)`
instinct, realised with zero contortion: it is **ordinary function-argument
passing**, the most mundane thing in the language.

- File wrote `aeb(cap)` → host binds `cap` to the operator object; the body
  may read/narrow, never widen (and even an attempt to widen is inert — the
  enforced grants live in SHM).
- File wrote only legacy `main()` → under `--sandbox`, that's the signal to
  refuse (or host it with an empty capability). Outside `--sandbox`, the
  legacy `main()` runs the old way (unconstrained) — see migration.

## `aeb(cap)` for the whole ecosystem; `main()` as the legacy on-ramp

Make `aeb(capability) { … }` the **ecosystem entrypoint** for build files,
and keep `main()` as a legacy initial entrypoint:

| File declares | `aeb` (no sandbox) | `aeb --sandbox` |
| --- | --- | --- |
| `aeb(cap) { … }` | hosted; `cap` = grant-all (unconstrained, honoring "no constraint asked") | hosted; `cap` = operator ceiling, enforced by the preload |
| legacy `main()` only | runs the old way (binary/exe semantics), unconstrained | refuse, or host with empty `cap` (operator policy) — a legacy file can't opt out of the sandbox by lacking `aeb(cap)` |

This honors the language-level rule debated upstream — **`main()` with no
capability argument means *no constraints*, not "fully sandboxed"** — while
making it safe in aeb, because under `--sandbox` aeb never lets an untrusted
build's entrypoint *choice* disable containment: the enforcement is the
host-imposed preload, independent of what the file declared.

## The grant grammar (inside `aeb(cap)`)

The verbs are Aether's sandbox vocabulary, verbatim — anyone who knows
`spawn_sandboxed` already knows these; they are not new aeb nouns:

```aether
aeb(cap) {
    // narrow within the operator ceiling (intersection — never widen)
    cap.grant_fs_read(repo)          // the prepared tree
    cap.grant_fs_read("/usr/*")      // toolchain + libs
    cap.grant_fs_write("target/*")   // build outputs only
    cap.grant_exec("/usr/bin/cc")    // tighten the exec allowlist
    cap.grant_env("PATH")
    // no grant_tcp → network denied (the point)

    b = build.start()
    c.compile(b)
}
```

Categories: `fs_read`, `fs_write`, `exec`, `tcp`, `tcp_listen`, `env`
(+ the grant-all escape, which the veto should flag). Absence of a verb for
a category **is** denial — there is no `deny_*`; deny-by-default outside the
declared set. `repo`/`target` are bound names the host supplies, not
literals the build retypes.

**Authority model: intersection with the operator ceiling.** The in-`aeb(cap)`
grants are a *request* the build can use to *narrow*; the operator's policy
is the *immovable ceiling*. Effective enforced grants = the operator set
(the build can only ask for less, and even an ask for more is inert because
enforcement is the SHM grant set, not the build's list). This preserves the
trusted-harness invariant: a verdict/grant can't be overridden by the code
it's about to compile.

## Open questions / blockers before implementation

1. **Pre-`main` / pre-entry execution (the one true blocker).** Does Aether
   run any user code before the hosted entrypoint is called — `import`-time
   side effects, top-level initializers? If so, hosting `aeb(cap)` does not
   contain that pre-entry code, and the transform/host wiring must account
   for it (or the preload must already be active before the build module is
   loaded). Verify before building. (The LD_PRELOAD layer, set up *around*
   the whole `aeb` process, covers this regardless — another reason it is
   the real fence.)
2. **`--emit=lib` capability rejection as a feature.** aetherc already
   *rejects* `--emit=lib` on a source that imports capability-gated stdlib
   without `--with=`. For the sandbox story this is fail-closed for free:
   an untrusted build reaching for gated powers is refused at lib-emit.
   Decide how aeb surfaces that refusal (→ a veto verdict).
3. **Calling convention for the host → `aeb(cap)` invocation.** The proof
   used a statically-imported module + direct call. The real host resolves
   the build file dynamically at runtime; settle whether that is a
   compile-the-build-as-a-module-then-call path (as proven) or a
   dlopen/`std.dl` path (as `aether.tinygo_lib` uses for `.so`s).
4. **`cap` object type.** The proof used a plain `list` (data, forgeable —
   fine, since it is the grammar layer not the fence). Decide whether `cap`
   stays a list the host reads to build the SHM grant set, or becomes an
   opaque builder type (`build.sandbox`-style `_ctx`) for nicer narrowing
   ergonomics. Either way it is **not** the enforcement boundary.

## Relationship to the rest of the veto stack

- **1a/1b/2b** decide *whether to build* (static veto: rules, external tool,
  AST). They run before this.
- **`aeb(cap)` + the preload (layer 3)** decide *what the build may do while
  it runs* (runtime containment). This is the layer that survives "a clean
  veto is not a clean program": the static layers can be defeated by computed
  commands; the preload sees the real syscall.
- The container/VM layer below catches what the preload can't (statically
  linked tools, raw syscalls, resource exhaustion).

Three layers, each catching the one below's escapes. `aeb(cap)` is the
grammar that makes layer 3 ergonomic and honest; `spawn_sandboxed` /
LD_PRELOAD is what makes it true.
