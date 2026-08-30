# target/<buildFileName>/<dir> — the filename IS the route

Status: **IMPLEMENTED (2026-06-14).** The whole `.<type>.ae` segment is the type,
verbatim — `infer_type`/`file_to_label`/`build.begin`/`_dep_target_dir` all take
the literal name; `.compile.ae`→`target/compile/`, `.bidi-codegen.ae`→
`target/bidi-codegen/`, `.essais.ae`→`target/essais/` (French & all). The
`-tag`/`:tag` subsystem is GONE (co-located variants are just different-named
types, e.g. `.build.ae` + `.seed.ae`); `extract_tag` is a deprecated always-""
stub. The one legacy alias kept: `.tests.ae`→type `test` (singular word, plural
`target/tests/` dir). Proven end-to-end: a `.compile.ae` binary lands in
`target/compile/<dir>/` and a dependent resolves it there.

This SUPERSEDES the routing role of the //aeb:output_subdir + //aeb:classify
directives and the old 3-bucket infer (everything-not-tests/dist → "build" →
shown as "compile"). Read alongside `docs/design/label-is-the-addressing-contract.md`
(which established *why* routing must be label/filename-derivable).

## The rule, in one line

```
target/<buildFileName>/<path/to/module>/
```

where `<buildFileName>` is the build file's own name with the leading `.` and
the trailing `.ae` dropped:

```
foo/.build.ae              → target/build/foo/
foo/.tests.ae              → target/tests/foo/
foo/.dist.ae               → target/dist/foo/
foo/.tests-integration.ae  → target/tests-integration/foo/
foo/.whatever.ae           → target/whatever/foo/
```

That's the whole scheme. The filename the author chose IS the route. Nothing
is inferred, classified, prefixed, or commented.

## Why this is the right shape

It dissolves, rather than solves, the long chain of mechanisms we built:

- **No `infer_type` for routing.** Today `.tests.ae` → `infer_type` → `"test"`
  → `test:` label prefix → `/tests` path prepend. Three hops to translate the
  filename into a path. Here the filename segment IS the path segment — zero
  hops.
- **No `test:`/`dist:` label prefix** carrying routing. The buildtype lives in
  the path directly.
- **No `is_colocated_test`** probe (already half-dismantled).
- **No `//aeb:output_subdir` directive.** Want `target/staging/`? Name the
  file `.staging.ae`. The filename is the custom subdir. The directive becomes
  unnecessary *for routing*.
- **No `//aeb:classify` directive** *for routing* — the filename routes; if a
  separate *display* classification is still wanted (summary "test:" column),
  that's a smaller, display-only concern, not a path concern.
- **No special case for `.build.ae`.** Today it's "the default that gets no
  subdir" (`target/<dir>`); here it's `target/build/<dir>`, uniform with every
  other type. The asymmetry that made build files different — and that made
  the "should we sweep them?" question awkward — vanishes. Everything is
  `target/<type>/<dir>`.

And it satisfies the addressing contract for free: every consumer
(`build.begin`, `_label_to_target_dir`, a dependent's `_read_dep_artifact`)
derives `target/<type>/<dir>` from the **same build-file name**, so they agree
by construction — which is the property the whole `label-is-the-addressing-
contract` doc was protecting.

## Why it works with deps (the load-bearing fact)

A dep edge already names the **build file**, not just the directory:

```aether
build.dep(b, "java/components/velar/.build.ae")   // real monorepo form
```

So the dep string *already carries the buildtype* (`.build.ae` → `build`) AND
the dir (`java/components/velar`). A dependent can compute
`target/build/java/components/velar/` purely from the dep string. The
dependency, when it builds, writes to the same `target/build/...` derived from
its own filename. **Match by construction** — no label prefix, no inference,
no handoff. This is the fact that makes the scheme viable: routing info is
already present at every site that needs it, in the build-file name.

## The honest costs

1. **It's a breaking path change.** Every artifact moves:
   - `target/<dir>/...` → `target/build/<dir>/...`
   - `target/tests/<dir>/...` → stays `target/tests/<dir>/...` (already had
     the `tests` segment) — actually unchanged shape, good.
   - So *build* artifacts relocate under a new `build/` segment; test/dist
     are roughly where they were. Anything that hard-codes `target/<dir>`
     breaks: `.gitignore` patterns, the agent container's expectations,
     downstream tooling/scripts, docs, the `_read_dep_artifact` path
     computation, cache-marker finders. All must move to `target/build/<dir>`.

2. **Dep-strings that name a DIRECTORY, not a build file, lose the buildtype.**
   Some deps are written `dep(b, "java/components/vowelbase")` (dir only — the
   doc comments show both forms). A dir-only dep has no `.build.ae` in it, so
   the buildtype isn't recoverable from the string → can't derive
   `target/build/...` vs `target/tests/...`. **Resolution options:** (a)
   require deps to name the build file (`.../.build.ae`) — a migration of
   every dir-only dep; or (b) default a dir-only dep to `build` type
   (`target/build/<dir>`), which is almost always what's meant (you depend on
   a thing's *build* output, not its tests). Option (b) is likely fine and
   keeps dir-only deps working, but must be decided explicitly.

3. **Multiple build files in one dir** (the `:tag` case, e.g. `.build-seed.ae`
   + `.build.ae`) — under this scheme they become `target/build-seed/<dir>`
   and `target/build/<dir>`, which *naturally disambiguates them by the
   filename* — arguably cleaner than the current `:tag` suffix on the label.
   The `:tag` mechanism may fold into this too.

## What it supersedes (and what the just-shipped work still buys)

- `//aeb:output_subdir` and `//aeb:classify` were shipped as the *declared*
  routing/classification channel. Under this scheme they're **unnecessary for
  routing** — the filename does it. If we adopt this, those directives' routing
  role is removed (the code stays harmless but unused for routing, or is
  ripped out).
- The `is_test` deletion (commit 2f09c5e) remains correct and on-the-way-here
  — it removed the dir-name heuristic; this removes the *suffix* inference too,
  finishing the job.
- The addressing-contract doc remains the *why*; this is the *how*, simplified.

## Migration sketch (if adopted)

1. Change the ~3 path-computation sites to `target/<type>/<dir>`, deriving
   `<type>` from the build-file basename (`.build.ae`→`build` etc.):
   `build.begin` (writer), `_label_to_target_dir` (finder), and the dep
   path resolution (`_read_dep_artifact` / `_strip_lang`).
2. Decide the dir-only-dep default (option (b): treat as `build`).
3. Update `.gitignore`, the agent container, docs, any `target/<dir>`
   hard-codes to `target/build/<dir>`.
4. Verify: a clean build + a second build cache-hits; cross-dep resolution
   finds the moved artifacts; the monorepo + itests still green.
5. Remove the now-unused routing role of the //aeb: directives.

No structured comments. No inference. The route is the name. The author
already declared it by naming the file — we just stop translating it.

## Update: implemented, and the directives retired

The `target/<buildtype>/<dir>` layout shipped (the buildtype is the first
segment, derived from the build-file name via `infer_type`/the label prefix).
Then the `//aeb:output_subdir` and `//aeb:classify` directives were **retired
entirely** — `aeblabel`'s `@segment` helpers (`with_output_subdir`,
`output_subdir_of`, `strip_output_subdir`, `label_with_type`, `type_of_label`)
and the three-copy `_read_directive` scan-time reader (aeb-link,
gen-orchestrator, aeb-driver) are gone. They were read once, folded into the
label, then never read again — and once the filename IS the route, they only
fired in a "name disagrees with intent" case that the filename can express
directly (want `target/staging/`? name the file `.staging.ae`). With no real
need found in any repo, they were dead weight + a three-copy drift hazard.

So the end state is a single mechanism: **the build-file name determines the
type and the route, full stop.** No inference layer, no override channel, no
comment grammar. `docs/design/label-is-the-addressing-contract.md` remains the *why*
(routing must be label-derivable); this is the *how*, and it turned out the
filename alone suffices.
