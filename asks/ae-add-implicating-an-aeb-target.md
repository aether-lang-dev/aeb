# `ae add` implicating a `.name.ae` aeb target — fetch-a-dep + build-a-named-artifact, fused

**Filed by**: aeb Claude, 2026-06-15, after converting `../zsync` to aeb and
wanting `aeb` to link zsync's client/server `.so`. Design note — captures a
forward direction, not a request to implement now.

**Concrete worked example throughout:** zsync. We want
`aeb` to depend on a zsync `.so`, fetched + built from
`github.com/aether-lang-org/zsync-port`, without vendoring its source.

## Two mechanisms that don't know about each other today

1. **Aether-native fetch** — `ae add github.com/u/repo[@version]` +
   `aether.toml [dependencies]`. go-get-style: pulls an Aether **module** you
   then `import`. Resolves into the `lib` search path (`~/.aether`).
2. **aeb's named-target + prereq model** — `path/to:name` **synonym** targets
   (`.name.ae` literal-type files), `build.dep(b, "...")` edges, and
   `prereq(b, "toolchain:version")` read back by `aeb --prereqs` (the basis of
   per-job-image selection on the agents).

`ae add` fetches *importable source*. aeb builds *named artifacts*. **Nothing
bridges "go-get a dep" to "build that dep into the linkable thing I need."**
Today, to consume zsync's `.so` you hand-write a `fetch.archive` + a
`shared_lib` target (see `aeb-build-fetch-and-emit-lib-for-zsync-so.md`). That
works but it's manual plumbing per dependency.

## The idea: `ae add` (or an aeb equivalent) implicating a `.name.ae` target

What if a fetched repo could carry **aeb targets** (the `.name.ae` /
`.build.ae`-style literal-type files), and `add`-ing it made those targets
**resolvable + buildable** — not just its source importable?

```
ae add github.com/aether-lang-org/zsync-port@v0.7.1
  → fetches the repo (as today)
  → discovers its aeb targets, e.g.  zsync:client  zsync:server
     (from cmd/zsync/.build.ae etc., the literal-type model)
  → now a consumer can:
        build.dep(b, "zsync-port//zsync:client")   // build the dep's .so
     and aeb builds libzsync_client.so from the FETCHED tree, links it,
     via the SAME shared_library_deps_including_transitive machinery that
     already handles tinygo sidecars + the rust vendored-crate case.
```

So `add` brings in not "importable `.ae`" but "a **buildable named artifact** I
can `dep` on." It's effectively **`go get` + `go build` of a sibling-language /
cross-license `.so` dependency in one motion** — which is exactly what the
zsync-as-transport plan needs.

## Why this composes with what already exists

- **The `.name.ae` literal-type model is already the naming surface.** A fetched
  repo's targets are just its `path/to:name` synonyms — aeb already classifies
  and resolves those (`tools/aebcli classify_target`). The only new bit is
  qualifying them by *package*: `<pkg>//path:name` (Bazel-label-ish), so a dep's
  target namespace doesn't collide with the consumer's.
- **`--prereqs` flows through unchanged.** A fetched target STATES its own
  prereqs (`prereq(b, "rust:1.75")` etc.); `aeb --prereqs` already flattens
  transitively across `dep()` edges. A dep on a fetched target just extends that
  graph — the agents' per-job-image selection Just Works across package
  boundaries. (This is the natural Rung-3+ generalisation: the cross-language
  DAG can now span fetched packages.)
- **The shared-lib link machinery already exists.**
  `shared_library_deps_including_transitive` + `_collect_shared_libs` put a
  dep's `.so` on the link line + LD path (used today for tinygo). A fetched
  `shared_lib` target publishes the same artifact — no new linking path.
- **License boundary stays clean.** Fetch-and-build (don't `import`) is the
  arms-length relationship: aeb consumes the fetched tree's built `.so`, never
  imports its `.ae` into aeb's module graph. Artistic zsync stays out of MIT
  aeb's import closure; the `.so` carries its own license (Artistic §7/§8 permit
  the link). `ae add`-into-import-path would BREAK this — so the target-implicating
  form must be "fetch + build the named artifact", explicitly NOT "add to imports".

## The design questions to settle

1. **Where do fetched targets live + how are they namespaced?** Proposal:
   `<pkg>//<path>:<name>` labels; the fetched tree under a content-addressed
   `target/_pkg/<host>/<user>/<repo>@<ver>/` (pinned, sha-verified — like
   `fetch.archive` already does), NOT mixed into the consumer's source tree.
2. **`ae add` (Aether) vs an aeb verb?** `ae add` today targets the import path;
   making it ALSO register buildable targets couples Aether's package manager to
   aeb's target model — maybe undesirable (keeps Aether aeb-free). Cleaner
   alternative: an **aeb-side** `build.pkg_dep(b, "github.com/u/repo@ver", "path:name")`
   that fetches (via `lib/fetch`) + resolves the target in the fetched tree,
   leaving `ae add` purely for Aether-module imports. Recommend the aeb-side
   verb — it keeps the import-path vs buildable-artifact distinction explicit and
   keeps Aether's manager unburdened.
3. **Lockfile / reproducibility.** A fetched build dep wants pinning (sha + ver)
   and a lock entry — ties into `versioned-bom-and-self-validating-lock.md`.
4. **Manifest of what a package OFFERS.** A consumer needs to discover a repo's
   buildable targets without cloning-and-grepping — a small `aeb --targets`
   (list the `.name.ae` synonyms a tree exposes), analogous to `aeb --prereqs`.

## Status: the FETCH half is now IMPLEMENTED (`fetch.git`)

**2026-06-15** — the "pull from git + build a `.name.ae` under it" motion is
**built and proven**. `lib/fetch` gained a `fetch.git(b)` builder (the go-get-
alike): `git clone --branch <ref>` into a pinned working tree, then verify
`HEAD == commit(...)` and **FAIL LOUD on drift** (the git analogue of `sha256`).
Setters: `repo` (req), `into` (req), `ref` (branch/tag), `commit` (pin — strongly
recommended), `depth` (shallow). Shells out to `git` (same as the agent's
autoclone — no libgit dep), per Paul's call that shelling out is reasonable.

Proven end-to-end: `fetch.git` pulls `../zsync` pinned to a sha → builds
`cmd/zsync/.build.ae` **under the fetched tree** → runnable `zsync` binary. The
bad-pin path correctly fails the build (`exit 1`, `build.fail`). Idempotent
re-run skips the re-clone (HEAD-satisfies-pin check). Artifact published as
`fetched_git_dir`. See `lib/fetch/module.ae` (`builder git`, `git_clone_cmd`,
`_sha_matches`).

**What remains is the BRIDGE half** — `build.pkg_dep` — which composes
`fetch.git` + target resolution into ONE verb so a consumer writes
`build.pkg_dep(b, "github.com/u/repo@ver", "path:name")` instead of a manual
`fetch.git` + a hand-pointed target. Today you wire the two by hand (fetch into a
dir, then point an ordinary target at `<into>/path/.name.ae` — which is exactly
what the proof did). That manual form already works; `pkg_dep` is the ergonomics.

## Recommendation

Don't overload `ae add` (keep Aether's package manager import-only, aeb-free).
The fetch primitive now exists (`fetch.git`). The remaining step is an
**aeb-side `build.pkg_dep`** (drive `fetch.git` + resolve a named target in the
fetched tree → its `.so`/artifact on the link line) — giving "go-get + build a
`.so` dep" in one verb, with the license boundary intact, reusing `fetch.git`,
`--prereqs`, and `shared_library_deps_including_transitive` wholesale. The
zsync `.so` transport is the first consumer; the per-job-image agent DAG (Rungs
3-5) is the second — it'd span fetched packages for free.

## Cross-ref

- `aeb-build-fetch-and-emit-lib-for-zsync-so.md` (the manual version this
  automates), `zsync-delta-transport-for-dispatch.md` (the first consumer)
- `versioned-bom-and-self-validating-lock.md` (the pinning/lock half)
- `docs/agent-container-ladder.md` (per-job-image DAG that'd span packages)
- `lib/fetch/module.ae`, `tools/aebcli/module.ae` (classify_target),
  `lib/build/module.ae` (`prereq`/`--prereqs`, `shared_library_deps_*`)
- `../zsync` (the worked example: a fetchable repo exposing buildable .so targets)
