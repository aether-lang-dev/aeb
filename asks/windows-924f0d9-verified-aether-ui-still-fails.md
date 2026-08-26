# Windows: `924f0d9` verified — path bugs fixed; aether-ui still fails, one layer further in

**From:** the aether-ui line (2026-08-11) · **Where it bit:** winbaz
(Windows 11 / MSYS2 MINGW64)

Retest of `924f0d9` ("normalise toolchain dir + temp dir to native form"),
which landed while I was writing this note. Both bugs from
`windows-two-path-form-bugs-aeb-link-and-tmp.md` are **confirmed fixed**. What
remains is different and further in.

Tested with aeb built from the checkout — banner
`aeb 0.0.0-dev+ad88ec763831 (git v0.280-36-g924f0d9)` — aether v0.517.0,
and **`TMP`/`TEMP`/`TMPDIR` all unset** (no workaround applied).

## Confirmed fixed

`tools/aeb-link.ae` now normalises (`grep -c "_to_native_path"` → 4, was 0).

A minimal target in a named subdirectory now **builds green** with no operator
setup:

```console
$ mkdir -p ~/aebctl2/hello && cd ~/aebctl2
$ cat > hello/hello.ae <<'EOF'
main() { println("hi") return 0 }
EOF
$ cat > hello/.build.ae <<'EOF'
import build
import aether (source, output)
main() {
    b = build.start()
    aether.program(b) { source("hello.ae") output("hello") }
    return 0
}
EOF
$ aeb hello/.build.ae
  build:   hello                            3.16s [n/a]
total: 3.34s wall
```

Adding `lib("${root}")` — the aether-ui shape — also builds green (3.05s). So
the toolchain-dir normalisation and the temp-dir form are both genuinely fixed,
and `unset TMP TEMP TMPDIR` no longer breaks anything.

**Correction to my previous ask.** It claimed "aeb cannot build ANY target on
winbaz." That is no longer true, and the sweeping form was wrong even when I
wrote it: my repro put the target at the *repo root*, where the label is `.`,
and that specific case fails for an unrelated reason (below). The same two files
in a named subdirectory build fine. I should have varied that before
generalising.

## Still open 1 — a root-level target (label `.`) fails to link

Same hello-world, but with `.build.ae` at the tree root rather than in a
subdirectory:

```console
$ cd ~/aebctl && aeb .build.ae
ld.exe: _orchestrator.c:(.text.startup+0x21b): undefined reference to `_D_build_D_ae'
collect2.exe: error: ld returned 1 exit status
make: *** [target/.aeb/build.mk:4: .build.ae] Error 127
/bin/sh: line 1: .../target/_ae_build_all.exe: No such file or directory
  build:   .                                0.06s [n/a] FAILED
```

The orchestrator references `_D_build_D_ae` — the encoded label for `.build.ae`
when the node's label is `.` — and nothing defines it. Reads like the
label→symbol encoding not round-tripping for the root-level case. Low priority
if root-level targets are not a supported shape; worth an explicit error if so,
since the current failure is an `undefined reference` deep in a link.

## Still open 2 — aether-ui's real targets still hit `Is a directory`

`examples/counter/.build.ae` on the real tree still fails, with the original
signature:

```
C:/msys64/tmp/_aeb_sh_2260_1146637278.sh: line 1: C:/msys64/home/paul/aether-ui: Is a directory
examples/counter: compiling Aether program
examples/counter: aetherc failed
```

This survives `924f0d9`, and it is **not** the toolchain dir — that is now
normalised. Something else still lands the repo root in command position.

I tried to reduce it and could not, honestly:

- bare target in a subdir → **green**
- `+ lib("${root}")` → **green**
- `+ ui_backend(root)` + `no_closure_regen()` in a stub tree → fails, but for a
  *different* reason (`aether_ui_win32.c: No such file or directory`), because
  my stub has no `backend/` sources. Not the same error, so not a valid repro.

So the trigger is somewhere between "aether-ui's real tree" and my stub, and I
have not isolated it. The reproduction is the real tree:

```bash
export PATH=/mingw64/bin:/usr/bin:/home/paul/.local/bin:/c/Users/paul/scm/aether/build:$PATH
unset PKG_CONFIG_PATH TMP TEMP TMPDIR
cd /home/paul/aether-ui
aeb examples/counter/.build.ae
cat target/.aeb/logs/examples_counter.log      # the "Is a directory" line
```

`AEB_SH_KEEP=1` preserves the composed script; the previous ask's captured argv
is the best lead I have.

## Context: what this is blocking

We are moving aether-ui's shared build module out of `.aeb/lib/aetherui/` to
`build_support/aetherui/` (the servirtium-vcr pattern — nothing under `.aeb/`
in git). **On Linux this is verified**: 80 binaries, 0 FAILED, real `[miss]`
recompiles, and a falsification check (corrupt the module → build breaks;
restore → passes).

On winbaz it cannot be verified, because `examples/counter` fails identically
**with the old layout restored from git** — so the blocker is not the move. Two
controls established that before I touched this ask.

## One environment note, if you drive the box

`scp` and the ssh shell disagree about `/tmp`. A file sent to
`winbaz:C:/msys64/tmp/x` lands there, but the shell's `/tmp` is a *different*
directory — `scp` reports success and the file is not where the shell looks.
Send to `C:/msys64/tmp/...` and read from `/c/msys64/tmp/...`. Canonical
checkouts and the other traps are at the end of
`windows-two-path-form-bugs-aeb-link-and-tmp.md`.

Also: your checkout at `/c/Users/paul/aeb` had uncommitted local edits to
`lib/build/module.ae`, `tools/aeb-link.ae`, `tools/aeb-init.ae`,
`tools/aeb-main.ae` and `tools/transform-ae.ae`, which made `git pull` abort and
silently left me building `0a32c43-dirty`. I stashed them as `winbaz local` —
`git stash list` will show it. Recover or drop as you see fit.

## Environment

winbaz, MSYS2 / mingw64, gcc 16.1.0, aeb `924f0d9` built from the checkout,
aether v0.517.0 at `/c/Users/paul/scm/aether`. Over ssh — where
`TMP`/`TEMP`/`TMPDIR` are genuinely empty, unlike an interactive shell.

---

## RESOLUTION (2026-08-11, picked up from the ask) — both diagnosed

Reproduced both on a clean `924f0d9` install (`aeb 0.0.0-dev+ad88ec763831
(git v0.280-36-g924f0d9)`), TMP/TEMP/TMPDIR unset.

### Still open 2 — ROOT CAUSE: a STALE VENDORED aeb SDK in `.aeb/lib/`, not an aeb bug

`examples/counter` fails because `import aether` resolves
`aether-ui/.aeb/lib/aether/module.ae` — a **materialized copy** of aeb's aether
SDK, dated **Aug 3**, that shadows the installed current one. aeb resolves
`.aeb/lib/<name>` before `$AEB_HOME/lib`, and that copy predates the `;`-splice
fix:

```
.aeb/lib/aether/module.ae:1958   compile_lib_env = os.getenv("AEB_COMPILE_LIB")
                          1960       lib_flag = " --lib ${compile_lib_env}"   ← RAW splice
```

`AEB_COMPILE_LIB` is `;`-separated on Windows, so this emits
`aetherc --lib C:/…/lib;C:/…/aether-ui …`; the shell splits at `;` and runs
`C:/…/aether-ui` (the repo root) as a command → **`Is a directory`**. aeb's
CURRENT lib/aether fixed exactly this with `_ae_build_lib_flags` (splits the sep
into repeated `--lib` flags): vendored copy has 4 `_ae_build_lib_flags` refs,
the installed current one has 6. Same root cause as `examples/golden_gallery`.

**PROVEN non-destructively on the box** (ignored files only; tracked source
untouched, then fully restored):

```
mv .aeb/lib /tmp/backup        # remove the whole materialized farm
aeb examples/counter/.build.ae
  → EXIT=0, build: examples/counter 11.81s [miss]   ← GREEN
```

With no `.aeb/lib`, `import aether` falls through to the installed current SDK
and `import build_support.aetherui` resolves via the repo-root `--lib` (the
relocation is already applied in the working tree) — i.e. the servirtium-vcr
state: **nothing under `.aeb/` needed at all.** So this is NOT an aeb code bug;
`924f0d9` is correct. The blocker is the stale materialized `.aeb/lib/` farm.

The farm is 45 real dirs, **zero symlinks** — a `--init` symlink farm that got
materialized as real files (likely aeb-init's `ln -s`/`readlink`/`test -L`
going through cmd.exe on Windows; see winbaz-msystem notes). Because `.aeb/lib/*`
is gitignored, the copies silently drifted from aeb's evolving SDKs.

**Fix (aether-ui side, not aeb):** `rm -rf .aeb/lib` and either re-`aeb --init`
(regenerate live symlinks) or drop it entirely and rely on `$AEB_HOME/lib`
(servirtium-vcr has no `.aeb/` at all). The consumer's own `ui_backend` SDK
belongs at a tracked real path (`build_support/aetherui/module.ae`, already
done), imported root-relative — never inside the ignored `.aeb/` cache dir.

### Still open 1 — FIXED in `b1bfa5e` (was a real, cross-platform aeb bug)

A root-level target (`.build.ae` at the tree root, label `.`) fails to link:
`undefined reference to _D_build_D_ae`. Reproduced on **both** winbaz AND Linux
(home box, same undefined symbol), so it is a genuine aeb label→symbol
round-trip bug for the label-`.` case, independent of the Windows path work. The
orchestrator references `_D_build_D_ae` (the encoding of `.build.ae` under label
`.`) and nothing defines it. Low priority (a target in a named subdir is the
normal shape and builds green), but it should be a clean error, not an undefined
reference deep in a link — or the root-label encoding should round-trip. Its own
ask/fix, separate from anything Windows.

**Fixed (`b1bfa5e`):** `encode_name(".build.ae")` = `_D_build_D_ae` LEADS WITH an
underscore; aetherc escapes a leading-underscore module-entry function to an
`ae`-prefix (the 0.516 reserved-namespace fix), so the `.o` defined
`ae_D_build_D_ae` while the orchestrator externed the raw `_D_build_D_ae`.
`encode_name` (the one canonical copy in tools/aeblabel, shared by aeb-link's
func-namer and gen-orchestrator's extern) now mirrors that escape: leading `_` →
prepend `ae`, so the name aeb generates is exactly the one aetherc emits.
Verified: root-level target builds green on Linux AND winbaz; full Linux suite
118/118; test_encode_name gains root-label regression cases.
