# version_quest.md — findings while chasing the Windows-13, side-quests included

Working note, not a repo artefact. No commit, no git-add. Written mid-session
2026-08-11 while getting the aeb suite green on winbaz (Windows/MSYS2) and
cross-checking on cachyos (full-toolchain Linux) + the home Linux box.

---

## ✅ FIXED (commit 31b5d97) — `_toolchain_version()` assumed bare `ae` on PATH

Resolved: added a shared `_ae_bin()` ($AETHER, else bare `ae`) that both
`_toolchain_version` and `_shell_out_ae_build` resolve through, so the version
probe and the build it describes can never disagree. Regression guard added to
test_aether_toolchain_key (fake `ae` printing a sentinel; asserts the probe
reads $AETHER, not PATH). Green on Linux + winbaz. Original write-up below for
the trail.

---

## Latent bug found: `_toolchain_version()` assumes bare `ae` on PATH

`lib/aether/module.ae:494` `_toolchain_version()` does:

```aether
raw, _err = build._sh_capture("ae --version 2>/dev/null | head -1")
```

It shells out to a **hardcoded bare `ae`**, resolved from PATH — NOT from the
`$AETHER` the caller/build is actually using. This feeds the content-addressed
cache key (`ae:<version>` component, line 659), so when the probe returns empty
the key silently loses its toolchain-version segment.

**How it surfaced.** On the cachyos box `~/.local/bin` is not on the non-login
PATH, so `which ae` → nothing, so `_toolchain_version()` → "", so
`test_aether_cache`'s "toolchain_version: non-empty" assertion failed. Put
`~/.local/bin` on PATH and it passes. So the *test failure* was environmental —
but it exposed a real design gap:

- The whole point of aeb's two-Aether split is that `$AETHER` (or the pinned,
  fetched toolchain) is authoritative and "aeb never touches bare `ae`."
  `_toolchain_version` breaks that: it reads a *different* `ae` than the one
  compiling, or none at all.
- Worst case is not the empty string (that at least degrades to a stable key).
  Worst case is a box with a *different* `ae` on PATH than `$AETHER`: the cache
  key would record the wrong toolchain version and could serve artifacts built
  by one compiler as if they were another's.

**Fix shape (out of scope for the Windows-13, noted for later):** resolve the
compiler the same way the rest of lib/aether does — honour `$AETHER`, then the
pinned/fetched toolchain, then PATH `ae` as the last resort — and pass that
resolved path into the version probe instead of the literal `ae`. There is
already toolchain-dir resolution in lib/build (`_to_native_path`, the
`command -v ae` probe near line 1344); the version probe should ride the same
resolution, not a second, weaker one.

**Fixed** in 31b5d97 (the $AETHER resolution + regression test). A follow-up
loose end from that same function — the `_AEB_AETHER_VERSION_CACHE` memo was
read but never written, so the "memoized" comment was false and every target
re-spawned `ae --version` — was closed in 0a32c43 (wire the setenv; store only
non-empty; test clears the memo around its probe).

---

## ✅ FIXED UPSTREAM (aether PR #1492, 2026-08-11) — the "0.516.0" prebuilt reported 0.417.0

Resolved in aether: the Makefile now stamps the version from the VERSION file in
the built tree (authoritative), not from a scan of ambient `git tag` (which the
shallow release-build checkout left stale), and the release build job checkout
was deepened. Diagnosis + fix sketch had been written to
~/scm/aether/version_stamp_bug.md; deleted once the upstream fix landed. Original
write-up kept below for the trail.

---

## the "0.516.0" prebuilt reports itself as 0.417.0 (now fixed upstream)

`aeb`'s trampoline fetched the pinned toolchain to
`~/.cache/aeb/toolchain/aether-0.516.0/bin/ae`, and that binary prints:

```
ae 0.417.0 (Aether Language)
```

So the release tagged/fetched as 0.516.0 carries a 0.417.0 version string in
its `--version` banner. It COMPILES aeb fine (116→118/118 on cachyos once the
environmental issues were cleared), so functionally it is the right toolchain —
but anything keying on the banner string (see the `_toolchain_version` bug
above) records "0.417.0". Two smells stacked: a probe that reads the wrong `ae`,
and a release whose banner disagrees with its tag. Worth a glance upstream:
is the version baked at build time and did the 0.516.0 release job miss the
stamp?

---

## Environmental gotchas on cachyos (192.168.0.160), for next time

Both were pre-existing, neither is a code bug — but both cost a measurement:

1. **Stale gitignored tool binary.** `tools/extract-deps` was from **June 13**
   (the box's aeb had been sitting at an old commit). `test_extract_deps_scan`
   ran that stale binary, which predates coordinate-dep filtering, so it emitted
   `hiccup:hiccup:...`, `npm:left-pad:...` etc. where the test expects only the
   file dep. `rm -f tools/extract-deps*` and re-run → green. **Lesson: after a
   big `git pull`, wipe gitignored `tools/*` binaries so the suite rebuilds them
   against the current source.** (This is the same family as the LLM.md warning
   about `ae`'s own build cache serving stale binaries.)

2. **`ae` not on the non-login PATH** → the `_toolchain_version` failure above.

3. **diffutils not installed on winbaz** (no `cmp`, no `diff`) → the last two
   Windows cache tests read as byte-mismatch failures when the bytes are in
   fact IDENTICAL (same sha256 — measured). `cmp`/`diff` returned 127
   (command-not-found), and `_eq0(127)` is 0, so the assertion failed silently.
   Installed `diffutils` on the box to unblock measurement.

   **Is diffutils an aeb requirement?** NO — it is a TEST-only convenience.
   aeb's runtime (trampoline, SDKs, lib/build, lib/cache, the tar round-trip)
   never shells out to cmp/diff; the cache moves bytes via fs.read_binary +
   fs.write_atomic + zlib, proven byte-perfect on Windows without diffutils. So
   a real aeb user on a bare MSYS2 box is unaffected. The dependency is ONLY in
   `test_cache_tree_roundtrip` (`diff -r`) and `test_remote_cache_roundtrip`
   (`cmp -s`). Left as-is per decision this session (install rather than
   de-diffutils the tests); the portable alternative — a native fs.read_binary
   byte-compare / sha256sum, both present on any MSYS2 — is noted here so the
   next fresh box does not re-diagnose a phantom cache failure.

With both cleared, cachyos runs the aeb suite **118/118** at the fetched
0.516.0 toolchain.

---

## Where the Windows-13 quest actually stands (the main goal)

The 13 winbaz run-failures are NOT one cause — confirmed by direct measurement,
exactly as current_prob.md warned. Three distinct families so far:

1. **Shell never reaches a POSIX shell.** Tests call raw
   `os.system("mkdir -p ..")` / `printf > file` / `rm -rf`. On Windows
   `os.system`/`os.exec` route through **cmd.exe**, which cannot run POSIX
   mkdir/touch/printf — so the fixture is never created and the assertion sees
   empty. (current_prob.md called this "law #2" but under-stated it: even the
   *unquoted* form fails; the issue is cmd.exe, not just quote-eating.) Fix:
   route fixture setup through `build._sh` / `build._sh_capture`, the proven
   temp-.sh chokepoint production code already uses. No-op on POSIX.

2. **Windows absolute paths misclassified as relative.** A genuine Windows
   absolute path is `C:/...`, not `/...`. ~15 SDK sites decided "absolute vs
   relative" with a bare leading-`/` test and mangled `C:/..` into
   `<dir>/C:/..` via path.join. This was a REAL production bug on Windows, not a
   test artefact. Fixed by one canonical `build._is_abs_path(p)` (POSIX `/` OR
   Windows drive/UNC), consolidating three prior near-duplicate copies
   (`_is_abs_native`, lib/aether's `_is_abs_path`, and the scattered inline
   checks), and migrating java/bash/python/ruby/gleam/moonbit/dart/dotnet/
   copy/fetch/veto to it. Verified 116/118 on cachyos with the full toolchain
   (the 2 were the environmental ones above), so the migration is clean on
   Linux.

3. **Test asserts a POSIX-only expected value.** `test_javac_cmd` hard-coded
   `:` as the classpath separator; the correct Windows separator (which the
   production code rightly emits) is `;`. Fixed by building the expectation from
   `build._path_sep()`, same as `test_platform_helpers` already does.

**Progress:** winbaz 0/13 → 2/13 (`test_javac_cmd`, `test_bash_run`) after the
`_is_abs_path` migration landed. The remaining 11 are being converted to the
`_sh` chokepoint fixture pattern one at a time, re-measured on the box after
each — never quoting a count without measuring it, per the pattern that has
needed retracting twice already.

**FINAL: winbaz FULL SUITE 118/118 green** (measured 2026-08-11). Linux also
118/118 with the whole change set. The 13 were fixed with zero regressions to
the other 105. (One scare along the way was self-inflicted: an ad-hoc
`rm -f tools/extract-deps*` glob deleted the tracked `.ae` SOURCE files, not
just the compiled binaries, so 3 subprocess-tool tests briefly read as
failures; `git checkout -- tools/extract-deps.ae tools/aeb-query.ae` restored
them. When clearing gitignored tool binaries, name them explicitly — never
`extract-deps*`.)

Three MORE real Windows
production bugs surfaced past the shell/abs-path families, each fixed at the
right layer:

4. **GNU tar reads "C:/.." as a remote host spec.** aeb's directory-tree cache
   (`build._tar_dir`/`_untar_into`, used by java/kotlin/scala/ts/dotnet/clojure/
   groovy) tars to a native tarball path. `tar -xf 'C:/msys64/..'` fails with
   `tar: Cannot connect to C: resolve failed` — tar parses "C:" as
   rsync-style host:path. Fix: `--force-local` on Windows only (BSD tar lacks
   it; off-Windows the path has no drive colon). The whole tree-cache was
   silently broken on Windows before this — a real user bug, not a test
   artefact.

5. **cache.get needs a native dest path.** `cache.get(key, dest)` writes via
   native fs.write_atomic, so a `dest` from a bare shell `mktemp` (MSYS
   "/tmp/..") silently fails to be written on Windows. Fixed in
   test_cache_tree_roundtrip by putting the fetch/miss dests inside the
   already-native tmpdir instead of a second bare mktemp. (Same class as the
   _mktempdir native-form rule, just a spot the previous pass missed.)

6. **A native "C:/.." cannot go into a ':'-separated PATH.** test_approval_cmd
   prepends a fake-curl bin dir to PATH; "C:/msys64/..bin" splits on its own
   colon into "C" + "/msys64/..bin" and the fake curl is never found (the real
   curl runs). Fix: convert to the POSIX "/c/.." form (cygpath -u) for the PATH
   prepend specifically, while keeping native form for fs.* ops. This is the
   INVERSE of the std.fs rule — the shell's PATH wants POSIX, std.fs wants
   native. Both forms are needed, each in its own place.

The unifying lesson across all six families: on Windows there are TWO path
vocabularies (native "C:/.." for Aether std.fs/std.file/std.io, POSIX "/c/.."
for anything a ':'-list or bare-shell-tool touches), and every bug was a place
that used the wrong one for the consumer. `_sh`/`_sh_capture` and `_is_abs_path`
and cygpath -u/-m are the three tools that bridge them; the discipline is
knowing which consumer wants which form.

Regression guard added: test_platform_helpers now directly tests
`build._is_abs_path` (10 assertions incl. every Windows drive/UNC shape).

Linux stays 118/118 with the whole change set (the `_is_abs_path` migration is
a pure no-op there: POSIX '/' is the first branch, drive/UNC never match).

**The direction question (asked and answered):** the previous session's
native-`C:/` path direction is NOT a wrong turn to revert. Measured on winbaz,
`io.write_file("/tmp/x")` genuinely FAILS ("cannot write file") — Aether's
std.fs/std.file/std.io are native Win32 and cannot see MSYS paths. The native
`C:/..` form is the ONE form both worlds accept (Aether file APIs AND the
shell). The bugs were from incomplete application (raw os.system left
un-migrated; leading-`/` abs checks), not from the choice itself.
