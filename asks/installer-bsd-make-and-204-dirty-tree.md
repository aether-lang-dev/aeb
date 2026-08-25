# Two small install-path findings from the .204 (FreeBSD) box

**From:** the aether-ui line (2026-08-21), while bringing all four boxes to
aeb v0.282.

## 1. install.sh dies on BSD make

`install.sh:91` runs a hardcoded `make -C "$src" install ...`. On FreeBSD
that is BSD make, which cannot parse the GNU makefile — the run stops at
"make: stopped making install" and the old aeb stays in place. Same
disease as aether's installer (filed there as
`install-sh-picks-bsd-make-on-freebsd.md`). The `have make || die "GNU
make is required."` guard at line 32 passes because a `make` EXISTS — it
is just the wrong one.

**Ask:** honour `MAKE` (e.g. `MAKE="${MAKE:-make}"`), or probe for gmake
when `uname` says a BSD, or make the guard actually verify GNU-ness
(`make --version | grep -q GNU`).

## 2. The .204 aeb checkout is dirty — deliberate?

`~/scm/aeb` on .204 has uncommitted local modifications to 8 files
(AETHER_FETCH, AETHER_PIN, lib/aether/module.ae, lib/build/module.ae,
lib/c/module.ae, tools/aeb-link.ae, two tests) — presumably from the
2026-08-15 f7a6ed9 install session (the installed version string carries
`-dirty`). It blocks a clean `git checkout v0.282` there. Not touched —
your working state, your call — but if those edits are already upstream,
a reset would let the box track releases; if they are not, they may be
unlanded fixes worth rescuing. The box otherwise works (fan-out clean,
aether-ui matrix 329/0), so nothing is urgent.

### Investigation (2026-08-25) — almost certainly already-landed, safe to reset

`f7a6ed9` ("link: honour @link on aeb's manual gcc path") **is on main**, and
its own `--stat` touches **6 of the 8** named files verbatim: AETHER_FETCH,
AETHER_PIN, lib/aether/module.ae, lib/build/module.ae, tools/aeb-link.ae,
tests/test_aether_link_flags.ae. The remaining two (lib/c/module.ae + the other
test) are covered by the same @link feature spread — `009c830` is also landed
and is the most recent lib/c commit. So the .204 dirty tree looks like **the
f7a6ed9 (+009c830) work edited in place there during that session, then
committed from a different box** — a checkout that diverged from what got
committed, NOT unlanded fixes. The `-dirty` version string is consistent with
"edited locally, never committed here".

**Recommended, run ON .204 to confirm before resetting** (don't reset blind):

```sh
cd ~/scm/aeb
# 1. Are the local edits already in main's history? Diff each dirty file
#    against v0.282 — if empty, the content is identical to the release:
git stash   # or: git diff v0.282 -- <file>  per file
git diff v0.282 --stat        # after stash: should be empty if the tree == release
# 2. If step 1 shows real differences, capture them before deciding:
git stash show -p > /tmp/dot204-local.patch   # rescue candidate
```

If `git diff v0.282 --stat` (with the edits stashed) is empty, the local edits
were == the release and `git checkout v0.282` (or `git reset --hard v0.282`) is
safe — the box then tracks releases. If it is non-empty, `/tmp/dot204-local.patch`
holds the delta to review for anything genuinely unlanded. I could not diff .204
directly from here (no reach to that box); this is the check to run there. The
box works today, so this is cleanup, not a fix.
