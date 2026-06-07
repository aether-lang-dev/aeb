# aeb vs Bazel — a musing

Filed alongside the PyTorch DAG scaffolding. Not load-bearing for the
migration; useful framing for why aeb's shape lands where it does
versus what a Bazel-shaped attempt would prioritise differently.

## Same starting point

Bazel and aeb start in the same place — declarative file-based DAG,
greppable rule edges, no recursion-driven build — but they diverge on
what they consider load-bearing.

## Bazel's bet: hermeticity

Bazel's bet is **hermeticity**. Sandboxed actions, content-addressed
remote cache, pinned toolchains, deterministic outputs as a feature.
That's what makes the remote-cache story work: if two machines hash
to the same key, they really did do the same work.

The cost is a steep on-ramp — you can't `cargo build` your way in.
Starlark exists because Bazel needed a language constrained enough to
enforce hermeticity (no `os.getenv`, no globs at action time, no
shelling out without sandbox cooperation). The rule ecosystem is huge
because every language has its own carefully-written Starlark wrapper
around its real toolchain.

## Aeb's bet: closure DSL + host toolchain as it stands

Aeb's bet is **closure DSL + the host toolchain as it stands**. No
sandbox. `os.system` is the bottom turtle. Capabilities and isolation
come from Aether the language, not the build runtime.

The DSL is just function calls with implicit `_ctx` — Aether itself,
not a constrained subset. That lets the SDK author write
`os.exec("grep …")` directly when they need it, which is why
`lib/python/codegen` can lean on `python3 + grep` rather than
re-implementing them.

The tradeoff is that the cache key has to be honest about every
input, and "every input" includes "what gcc you happen to have on
PATH." Aeb's current cache is content-addressed but not hermetic —
same input bytes on two machines with subtly different libstdc++
headers would happily share a cache entry that doesn't actually work.

## What the PyTorch exercise revealed

The PyTorch exercise made the asymmetry concrete. Bazel's value
proposition over CMake there isn't "the build is graph-shaped" —
CMake-plus-Ninja is already graph-shaped, that's why Bazel-curious
PyTorch contributors discovered the migration was harder than
expected.

The real wins would be:

1. **Explicit input/output declarations** so codegen staleness isn't
   paper-thin. Aeb gets this for free via the DSL —
   `codegen_input(...)` is the only way to declare an input, no
   GLOB_RECURSE fallback.

2. **A remote action cache** so 30-minute clean builds become 30
   seconds when someone else already paid the cost.

Aeb has (1) by design today, (2) on the roadmap.

## The strict-vs-permissive middle ground

Bazel's hermetic-sandboxed-action model is *strict* about what an
action can read; aeb's model is *permissive* but asks the SDK author
to declare inputs honestly.

- **Bazel** catches mis-declaration at run time (sandbox blocks the
  read).
- **Aeb** catches it at staleness time (output is wrong, you
  re-declare).

Bazel's catch is louder but the sandbox costs minutes per build on
macOS; aeb's catch is quieter but free.

For a monorepo where the build authors are also the platform team,
aeb's approach is arguably better — they can be trusted to declare
inputs because they wrote the SDK. For a hyperscaler where rule
authors and rule consumers are different orgs, Bazel's strictness
pays off.

## The absence of Starlark

Aeb's other quiet win is the absence of Starlark. Aether is the
configuration language *and* it's a real general-purpose language
with stdlib, actors, IPC, `std.http`. So `lib/<lang>/module.ae` reads
identically to a normal Aether program — no impedance mismatch
between "build code" and "production code."

Bazel's `WORKSPACE` / `BUILD` / `bzl` files are three sub-dialects of
Starlark with three different rules; aeb's `.build.ae` / `.tests.ae`
/ `lib/<lang>/module.ae` are all just Aether files.

Whether that matters to you depends on how often you write a new
language SDK — for hyperscalers, rarely; for a monorepo of a few
teams, sometimes; for a polyglot solo project, often.

## The clear gap

The clear gap vs Bazel is **remote cache + reproducibility**. Aeb has
the file-based DAG and content-addressed local cache to support
remote cache, but the toolchain story is what blocks it — pinned
cross-compiler-and-libc toolchains are nontrivial work, and right now
aeb just trusts PATH. That's the next-largest leap if "share
artifacts across a CI fleet" becomes load-bearing.

## Net positioning

Until the toolchain-pinning + remote-cache gap closes, aeb-vs-Bazel
is roughly:

- **Bazel** for the Google-scale problems Bazel was actually built
  for.
- **Aeb** for the polyglot monorepo problem CMake-and-Make were never
  quite shaped to solve.

## Follow-up: the cache gap, reframed

The "remote cache + reproducibility" gap above is true for a
maximalist read. The minimalist read says aeb can ship most of the
distributed-cache wall-clock win without going hermetic, by
borrowing Wingerd's mainline-model policy framework:
named cache scopes (mainline / development / release / task) with
explicit promotion gates and bounded host-fingerprint trust.

That direction is captured in
[`docs/distributed-cache-plan.md`](../../docs/distributed-cache-plan.md)
of the aeb repo, with links from `TODO.md` and `docs/aeb-vs-bazel.md`.
