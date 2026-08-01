# `dep(b, "git:…")` — a git coordinate as a first-class dep (the go-get-alike inside `dep()`)

**Filed by**: aeb Claude, 2026-06-15, after building `fetch.git` (the
clone-pinned-tree primitive, committed `6ab0bfa`) and Paul asking whether
`dep()` itself should accept the same go-get form.

**STATUS: IMPLEMENTED (2026-06-15).** `dep(b, "git:…")` and the
`build.pkg_dep(b, repo@ref, dir:name)` verb both land. The static extractor
(`tools/extract-deps`) resolves a `git:` coordinate by cloning into
`target/_pkg/<slug>/` (model **A**, fetch-at-extract) and emitting the
root-relative `.name.ae` path, so the dep DAG points at a real on-disk target;
the runtime `build._git_dep` does the same clone idempotently. PIN MISMATCH is
enforced at BOTH layers and fails the build loud (exit 1). Slug separator is
`-` not `@` (aeb's `encode_name` symbol encoder handles `/ - .` but not `@`).
Parser unit-tested in `tests/test_git_coord_parse.ae` (26 assertions; suite
110/110). Proven end-to-end against `../zsync` (which added `cmd/zsync/.zsync.ae`
to be addressable): clone → pin-verify → synonym→`.zsync.ae` → registered as a
dep. **Known last-mile gap:** a fetched Aether *program* built as a transitive
`--emit=lib` dep hits the pre-existing `aether-program-dev-tree-include-threading`
/ transitive-regen limitation (`fileio.buf_as_string` undefined) — the SAME tree
builds clean as a ROOT target; this is orthogonal to the resolver. The rest of
this note is the design as settled; it matches what shipped.

`fetch.git` already exists and is proven (clone `--branch <ref>`, verify
`HEAD == commit(...)`, fail loud on drift, publish `fetched_git_dir`). This note
is about letting an ordinary `dep()` *name a remote git target directly*, so a
consumer writes ONE line instead of a separate `fetch.git` block + a hand-pointed
local target.

## The one-liner, decomposed

```
dep(b, "git:github.com/aether-lang-dev/zsync-port@main#cmd/zsync:zsync=a298837195fe60df567c66ff4922e0e5baceee6a")
        └─┬─┘└──────────────┬──────────────┘└─┬─┘ └──────┬──────┘ └────────────────┬────────────────┘
        scheme            repo               ref      synonym                    sha-pin
```

| field | example | role | maps to |
|---|---|---|---|
| `git:` | `git:` | scheme — classifies this dep | (parser branch) |
| repo | `github.com/aether-lang-dev/zsync-port` | the remote | `fetch.git repo(...)` |
| `@ref` | `@main` (or `@0.7.1`) | branch/tag — a **fetch hint, NOT the contract** | `fetch.git ref(...)` |
| `#synonym` | `#cmd/zsync:zsync` | **THE TARGET** to build in the fetched tree | `synonym_relpath` rooted at the clone |
| `=sha` | `=a298837…` | the **immutable contract** (supply-chain pin) | `fetch.git commit(...)` |

**Three orthogonal sigils, no overloading:** `@ref` *finds* it, `=sha` *verifies*
it, `#dir:name` *names what to build*. Each axis is one separator.

## Where the aeb target is named (the settled question)

The target run is the **synonym after `#`**, resolved by aeb's EXISTING
`.name.ae` literal-type rule (`tools/aebcli synonym_relpath`), unchanged — just
**rooted at the fetched tree** instead of cwd:

```
#cmd/zsync:zsync   →   synonym_relpath("cmd/zsync:zsync")  =  "cmd/zsync/.zsync.ae"
                   →   <fetched-tree>/cmd/zsync/.zsync.ae
```

Decision (Paul, 2026-06-15): **`name` = a `.name.ae` file**, NOT "the target whose
`output()` is `zsync`". The strict synonym rule as-is. Rationale: it's already
implemented, it's unambiguous, and — crucially — it makes a repo's **buildable
targets an explicit, greppable surface** (its `.name.ae` files) rather than
something a consumer discovers by parsing `output(...)` calls out of arbitrary
`.build.ae` bodies. Same discipline as a package's public API: you export targets
deliberately.

**Cost (accepted):** a remote repo must ship `.name.ae` synonym files to be
git-dep-addressable. For the zsync worked example that means adding
`cmd/zsync/.zsync.ae` (today it only has `cmd/zsync/.build.ae`; the binary name
`zsync` comes from `output("zsync")` INSIDE that file, not the filename). That's
exactly the "`.name.ae` implicating a target" idea from
`ae-add-implicating-an-aeb-target.md`, now load-bearing.

## Why the SHA pin, not the tag, is the contract (supply-chain)

Tags are **mutable** git refs and have been the load-bearing weakness in recent
supply-chain attacks — `tj-actions/changed-files` (March 2025) retroactively
re-pointed existing version tags (`v1`…`v45`) at a secret-exfiltrating commit;
~23k repos that pinned BY TAG silently started resolving to attacker code with no
workflow change. GitHub/OpenSSF/CISA guidance since: **pin by full commit SHA, not
tag.** A tag is a name an attacker can move; a SHA is content-addressed.

`fetch.git` already does the right thing — `--branch <ref>` is only the clone
*hint*; it then verifies `HEAD == commit(...)` and FAILS the build on mismatch.
So a re-pointed tag surfaces as a hard build failure, not silent execution — the
tj-actions attack would have tripped the pin. The git-dep form inherits this:

```
// ❌ tag/branch only — re-pointable underneath you (the tj-actions failure mode)
dep(b, "git:github.com/u/repo@0.7.1#cmd/zsync:zsync")
dep(b, "git:github.com/u/repo@main#cmd/zsync:zsync")

// ✅ sha-pinned — content-addressed, tamper-evident
dep(b, "git:github.com/u/repo@main#cmd/zsync:zsync=a298837195fe60df567c66ff4922e0e5baceee6a")
```

**Recommendation:** a git `dep()` with no `=sha` should be a build-time
**warning by default** (`fetch.git` already warns), escalatable to a hard error
under a strict mode. The longer-term ergonomic fix is a **lockfile that
auto-pins on first resolve** (Go's `go.sum` model — record the sha a tag/branch
resolved to, verify every later fetch against it), so `@0.7.1` stays readable but
becomes tamper-evident after first use. Ties into
`versioned-bom-and-self-validating-lock.md`.

## The parser (where it slots in `dep()`)

`dep()` today (`lib/build/module.ae` ~288) classifies by prefix: `npm:` first,
then **ANY `:` → maven**, else local file. A `git:` coordinate is full of colons
(`git:`, the synonym `:`), so **the `git:` branch MUST be checked before the
maven `:` test** or it's misclassified as maven. Order:

```
dep(ctx, s):
    if starts_with(s, "npm:")  -> npm dep           (existing)
    if starts_with(s, "git:")  -> _git_dep(ctx, s)  (NEW — before the ':' test)
    if contains(s, ":")        -> maven dep          (existing)
    else                       -> local file dep     (existing)
```

`_git_dep` splits the coordinate on `@` / `#` / `=`:

```
spec  = strip "git:" prefix
sha   = part after "="    (→ commit pin; "" ⇒ unpinned ⇒ warn)
left  = part before "="
synonym = part after "#"  ("cmd/zsync:zsync")
repo@ref = part before "#"
ref   = part after "@"  in repo@ref   ("" ⇒ default branch)
repo  = part before "@" in repo@ref
into  = a content-addressed pinned dir, e.g. target/_pkg/<host>/<user>/<repo>@<ref-or-sha>/
```

Then it drives the EXISTING primitives — no new machinery:
1. `fetch.git`: `repo(repo) ref(ref) commit(sha) into(into)` → clone + pin-verify.
2. resolve the target: `synonym_relpath(synonym)` rooted at `into` →
   `<into>/cmd/zsync/.zsync.ae`.
3. register that resolved `.ae` path as an ordinary local dep on `ctx` (so the
   rest of the build — link, transitive deps, artifacts — treats it exactly like
   a local dep). The fetched tree's own `dep()`/`prereq()` edges then flow
   through the normal DAG.

## The static-extractor tension (the one hard part)

`dep()` is read on TWO paths: runtime (above) AND **static** —
`tools/extract-deps` greps `dep(b, "…")` out of source WITHOUT running it, to
build the BFS dep-graph, then `file.exists()`-checks each resolved path. A remote
git dep **doesn't exist on disk until fetched** — so naive static resolution
sees a path that fails `file.exists` and silently drops the edge (the exact
bug `extract-deps.ae:93-98` already warns about for relative deps).

Two ways to resolve it (decide before implementing):

- **(A) Fetch-at-extract** — extract-deps, on a `git:` dep, runs `fetch.git`
  eagerly (clone to the pinned `target/_pkg/...` dir), then recurses into the
  fetched `.zsync.ae` for ITS deps. The DAG spans the remote repo; prereqs flow
  across the boundary (great for the per-job-image agent — Rungs 3-5 span fetched
  packages). Cost: extraction does network I/O.
- **(B) Fetch-is-a-leaf** — the `git:` dep resolves to a synthetic fetch+build
  node; its sub-deps aren't walked statically; the fetched `.zsync.ae` builds as
  an opaque sub-build at runtime. Extraction stays pure/offline; less transitive
  insight (a fetched repo's prereqs are invisible to `--prereqs`/preflight).

Recommend **(A)** long-term (it's what makes a git dep a true dep, not a
black-box sub-build, and it's what the agent DAG needs), with **(B)** as the
cheap first cut if eager-fetch-at-extract is too invasive to land first.

## Relationship to `build.pkg_dep`

This `dep("git:…")` form and the `build.pkg_dep(b, repo@ver, path:name)` verb
(`ae-add-implicating-an-aeb-target.md`) are the SAME capability, two surfaces:
the string-in-`dep()` form joins the `npm:`/maven: classifier family (terse, one
line); `pkg_dep` is the explicit two-arg verb (readable, no overloaded
punctuation). Build ONE resolver (`_git_dep` above); have both surfaces call it.
`pkg_dep(b, "github.com/u/repo@main", "cmd/zsync:zsync")` is just `_git_dep` with
the synonym as a second arg instead of after `#`.

## Acceptance

`dep(b, "git:github.com/aether-lang-dev/zsync-port@main#cmd/zsync:zsync=a298837…")`
fetches zsync pinned, resolves `cmd/zsync:zsync` → `<tree>/cmd/zsync/.zsync.ae`,
builds it, and links/threads its artifact exactly as a local dep — with a hard
build failure if the pinned sha doesn't match. Worked example: zsync (which must
add `cmd/zsync/.zsync.ae` to be addressable).

## Cross-ref

- `lib/fetch/module.ae` (`builder git`, `git_clone_cmd`, `_sha_matches` —
  IMPLEMENTED; the primitive this drives)
- `lib/build/module.ae` `dep()` ~288 (the classifier to extend — git: BEFORE the
  maven `:` test), `tools/aebcli/module.ae` `synonym_relpath` ~134 (the target
  resolver, reused rooted at the fetched tree)
- `tools/extract-deps.ae` ~45/93 (the static path + the dropped-edge bug the
  fetch-at-extract question must avoid)
- `ae-add-implicating-an-aeb-target.md` (`build.pkg_dep` — the verb surface of
  the same resolver; `aeb --targets` lister of a tree's `.name.ae` files)
- `versioned-bom-and-self-validating-lock.md` (the auto-pin-on-first-resolve
  lockfile that makes `@tag` tamper-evident)
- `../zsync` (worked example; needs `cmd/zsync/.zsync.ae` to be git-dep-addressable)
