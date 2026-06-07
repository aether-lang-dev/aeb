# Distributed Cache — Direction & Policy

Where aeb's remote/distributed cache should land, framed as a
direction rather than a spec. The local content-addressed cache
(`lib/cache/`) is phase 1; this doc tracks phase 2's shape. Wired
in from:

- [`TODO.md` § Remote build cache](../TODO.md)
- [`aeb-vs-bazel.md` (companion comparison)](aeb-vs-bazel.md)

## The framing question

A remote cache makes the wall-clock argument over CMake/Make
trivially. The interesting design question is *what does the cache
promise*, and the easy answer (hermetic reproducibility, Bazel-style)
costs months of pinned-toolchain work that a polyglot monorepo team
of 5–50 people will never pay for. The harder, more useful answer is
**repeatability under stated policy** — a cache contract that names
what it guarantees, names where it doesn't, and uses Wingerd-style
codeline policy as the organising principle.

## Repeatability ≠ reproducibility

These are different products, not better/worse versions of the
same thing.

- **Reproducibility (Bazel-shaped).** Same source + same dependencies
  + same toolchain identity ⇒ same output bytes anywhere. Requires
  hermetic toolchains, sandbox, pinned everything. Optimises for
  *worst-case correctness*: no bad artifact ever lands, even at the
  cost of cache hit rate. The investment is months of work for
  matching toolchains across Linux/macOS/Windows and across compiler
  versions.

- **Repeatability (aeb-shaped).** Same *declared* inputs ⇒ working
  output, where "working" means it links and tests pass. Not
  necessarily bit-identical across environments. Optimises for
  *average-case throughput*: most hits are good, the rare bad hit
  gets caught fast at the next link or test step. Investment is a
  coarse host fingerprint and a paragraph of policy docs.

For most monorepos, average-case throughput is what's load-bearing.
Hyperscaler scale changes the math — Google's pain from a bad
artifact is enormous (incident, paging, rollback); a 50-person org's
pain is "developer notices, deletes cache, rebuilds, moves on."

## The "is it a crime" question

A repeatability cache is a crime if it's dressed up as if it were
reproducible — alice builds c10/util on gcc-12 + libstdc++-14, the
`.o` lands in a shared cache keyed by source-hash alone, bob's gcc-12
+ libstdc++-13 box pulls it on hash match, bob hits undefined
behaviour at runtime three weeks later. Worst kind of bug, because
the build was green.

Three knobs turn a repeatability cache from crime into engineering:

1. **Fold a coarse host fingerprint into the cache key.** OS family,
   libc major, compiler major+minor. Crossing those boundaries
   becomes a cache miss instead of a silent substitution. Give up
   some hit rate; don't get UB in production.

2. **Scope the cache namespace.** A team-internal cache where
   everyone's on Ubuntu 24.04 + gcc 13 is fine. The crime is one
   global "anyone-can-push" cache where alice's musl-libc artifact
   ends up consumed by bob's glibc box. Bounded scope = bounded
   blast radius.

3. **Make the contract loud at consume time.** When a cache hit comes
   from a different fingerprint than the consumer, log it; let CI
   opt-in to "use anyway" or "miss". The contract isn't hidden.

These three knobs are insufficient on their own — they bound failure
mode but don't say *which* scope is authoritative for what. That's
the policy question.

## Cache policy — Wingerd's mainline model, applied

[Laura Wingerd's "High-Performance SCM" Perforce paper](https://www.perforce.com/sites/default/files/high-performance-scm.pdf)
made one observation that ages well: **branches without explicit
policy degrade into chaos; branches with policy become an ergonomic
system**. "Branch by exception, not by reflex; every branch has an
owner and a policy doc; promotion between branches is a first-class
gate."

That maps cleanly onto cache scopes. Aeb's distributed cache should
ship as a small set of named scopes with stated policy, not a single
global pool.

### Mainline cache

The canonical pool. High trust. Reproducible-when-it-matters within
a stated toolchain envelope. Populated only by CI runs with pinned
toolchains. Read-default for releases. Bit-for-bit guarantees inside
this scope.

**Policy.** CI-only writes. Pinned toolchain version recorded in
every entry. Eviction by age + LRU. Named owner: the platform team.

**Equivalent.** Wingerd's mainline that everyone integrates against.

### Development cache

Populated by developer machines, keyed by
`(declared_input_hash, coarse_host_fingerprint)`. Cheap to fill,
hits across a team that's on similar Ubuntu / gcc-major. Useful for
the team, not authoritative.

**Policy.** "Best-effort repeatable; if you cross a major-version
boundary, expect misses." Anyone on the team can write. Eviction by
age. Named owner: the team using the cache.

**Equivalent.** Wingerd's development line — useful for in-progress
work, not the source of truth.

### Release cache

Frozen at a release point, read-only after the release lands. Pinned
to the known-good toolchain envelope that shipped that release.
Lookup falls back to mainline cache for misses, never the other way.

**Policy.** Read-only post-release. Pinned toolchain version
mandatory. Eviction policy: pinned-with-release, never aged out
until the release is EOL.

**Equivalent.** Wingerd's release codeline. The "what we shipped"
record, recoverable indefinitely.

### Task cache

Per-PR or per-developer. Ephemeral, scoped tight. Don't let WIP
rebuilds pollute the shared pool. Cleaned on PR close.

**Policy.** Scoped to the PR or developer. Auto-evicted when the PR
merges or closes. Lookups from task cache fall through to dev cache
and mainline.

**Equivalent.** Wingerd's task line — short-lived, intent-bounded.

## Promotion is load-bearing

The hardest piece — and the one that distinguishes "policy" from
"namespace fragmentation" — is the **promotion gate**.

An artifact graduates from development cache → mainline cache only
when it passes a pinned-toolchain re-verification. Same insight as
"merging up only after the codeline below has been stabilized."
Without a promotion gate, the development cache silently becomes the
mainline cache and you're back to the no-policy crime.

Sketch of a promotion run:

1. CI picks artifacts that the development cache wrote in the last N
   hours.
2. Re-runs each one against the pinned-toolchain envelope.
3. Compares the new artifact byte-for-byte against the dev-cache
   entry.
4. On match → promote (write to mainline). On mismatch → mark the
   dev entry suspect, log for human review.

Promotion is what turns a permissive scope into a feeder for a strict
scope, instead of a parallel-and-divergent pool.

## Container vs content artifact classes

A second Wingerd insight transfers: the *container vs content*
distinction. Some cache entries are toolchain-derived (a `.o` whose
correctness depends on the libstdc++ version that linked it); others
are source-derived (a torchgen-emitted `.cpp` whose correctness
depends only on the YAML + the python script that emitted it).

Different artifact classes belong in different scopes:

- **Toolchain-derived** (`.o`, `.so`, linked binaries, fat jars):
  hermetic-mainline. Host fingerprint in the key. Promotion-gated.

- **Source-derived** (`.cpp` from codegen, generated `.h`, `.py` from
  protoc): safe in the permissive dev cache. Text. Downstream
  compile will catch any drift the moment it consumes them.

Aeb's `python.codegen` builder produces source-derived outputs that
the C++ compile step will catch. PyTorch's torchgen.gen produces 102
`.cpp/.h` files that are pure text — share them widely, the eventual
gcc invocation re-verifies them.

## "Branch by exception" generalises

A dozen ad-hoc cache scopes per project is a worse failure mode than
a single sloppy global. The Wingerd rule applies: **don't fragment
the cache namespace unless policy demands it**. Start with one
scope. Split when the policy boundary is real (CI vs dev, release
vs WIP). Resist per-project / per-language / per-team cache scope
proliferation — that's just unowned-branch theatre with more
infrastructure.

## What aeb has, what aeb needs

Today, aeb has:

- `lib/cache` — sha256 + zlib local content-addressed store under
  `$AEB_CACHE_DIR` (default `~/.aeb/cache`).
- Cache integration for Maven classpath resolution, Aether
  manual-path link, Java javac + javac_test classes-tree (tar+zlib).
- Content hashing primitives (`cache.hash_file`, `cache.hash_inputs`)
  used by per-SDK key computation.

What's missing for distributed:

- **Backend protocol.** HTTP CAS (Bazel-compatible
  `bytestream.googleapis.com` shape, or simpler S3/GCS). Pluggable
  via env var like `$AEB_CACHE_REMOTE_URL`.
- **Authentication.** Bearer token / IAM / signed URLs. Pluggable.
- **Host fingerprint computation.** `lib/cache._host_fingerprint()`
  returning `(os_family, libc_major, cc_major_minor)`. Folded into
  cache keys when the cache scope demands it.
- **Scope-aware lookup.** `cache.get(key, scope_chain=["task",
  "dev", "mainline"])` — try in order, return first hit, record
  which scope served.
- **Policy declaration.** A `.aeb-cache-policy.toml` or equivalent
  per repo / per scope, capturing owner, fingerprint requirements,
  promotion rules, eviction policy.
- **Promotion job.** Either a separate `aeb cache promote` CLI or a
  CI step that walks recent dev-cache entries and re-runs them under
  the mainline envelope.

## Sequencing

1. **HTTP CAS backend** behind `lib/cache`. Pluggable; no policy
   logic yet. Single global scope. Read/write via `$AEB_CACHE_REMOTE_URL`.
   Most of the wall-clock win is right here.
2. **Host fingerprint in the cache key.** A coarse-fingerprint
   helper plus opt-in via SDK choice. Bounds the silent-corruption
   failure mode before the cache becomes interesting enough to share
   widely.
3. **Named scopes + policy declaration.** Mainline / dev / release
   / task. Lookups try a configurable scope chain. Writes scoped by
   the run identity (CI vs developer).
4. **Promotion gate.** Re-verify-and-promote between dev and
   mainline. The piece that makes the policy real.
5. **(Later) Content-defined chunking.** See `TODO.md` § Remote
   build cache for the BuildBuddy CDC prior art. CDC is a *layer
   on* this — sensible only after the policy structure is in place,
   and the one constraint it imposes now (don't compress before
   chunking) is recorded in TODO.

## Net positioning

The pure-reproducibility crowd will sniff at a policy-scoped
repeatability cache. The "I just want my CI to be faster" crowd will
use it cheerfully. The pure-reproducibility solution costs months of
pinned-toolchain work; the policy-scoped solution costs a coarse
fingerprint, four named scopes, and a one-page policy doc per repo.

Bazel for the Google-scale problems Bazel was actually built for.
Aeb for the polyglot monorepo problem CMake-and-Make were never
quite shaped to solve — and a distributed cache with Wingerd-style
policy is what closes most of the wall-clock gap without taking the
hermetic plunge.
