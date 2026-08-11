# Windows: two path-form bugs — `aeb-link` misses `_to_native_path`, and the temp-dir fallback writes native but execs POSIX

**From:** the aether-ui line (2026-08-11) · **Where it bit:** winbaz
(Windows 11 / MSYS2 MINGW64), `aeb examples/golden_gallery/.build.ae`

Split out of `windows-pkg-config-substitution-runs-in-cmd.md`, which is
**resolved** — every symptom it described is gone as of `0a32c43`. These two are
what remains after that, and they are different bugs with a shared shape: a path
in the wrong form for whoever consumes it.

Measured with aether **v0.517.0** (satisfies the new 0.516.0 pin) and aeb built
from the checkout (`make install`, banner
`aeb 0.0.0-dev+405128502adf (git v0.280-35-g0a32c43)`).

## What is already fixed — so this ask is not about any of it

In a fully clean shell (`unset PKG_CONFIG_PATH TMP TEMP TMPDIR`):

```
fallback warning : 0        # was firing every build
unexpected EOF   : 0        # the original symptom of the other ask
Is a directory   : 0
undefined refs   : 0        # was 69
cmd.exe vol-label: 0
```

No operator setup required. `5711c1f`'s Windows parity claim holds for
everything the previous ask covered.

The target still FAILS, for the two reasons below. Both are now plainly visible
because the node log is written fresh every run.

---

## Bug 1 — `tools/aeb-link.ae` never normalises the toolchain dir

This is the `windows-fanout-aetherc-invoked-as-directory.md` bug, finally with a
captured command line rather than a guess.

`AEB_SH_KEEP=1` preserves the composed script. The argv contains seven native
paths and one MSYS-only path:

```
.../aeb-link.exe C:/msys64/home/paul/aether-ui/target/_aeb/_sorted.txt \
                 C:/msys64/home/paul/aether-ui/target/_aeb \
                 C:/msys64/home/paul/aether-ui/.aeb/lib \
                 /c/Users/paul/scm/aether/build \      <-- NOT normalised
                 ae \
                 C:/msys64/home/paul/aether-ui/target/_ae_build_all \
                 C:/msys64/home/paul/aether-ui
```

and the build dies with:

```
C:/msys64/tmp/_aeb_sh_4004_2066312509.sh: line 1: C:/msys64/home/paul/aether-ui: Is a directory
examples/golden_gallery: aetherc failed
```

`lib/build/module.ae:1366` normalises this correctly —
`_to_native_path(_dirname(string.trim(raw)))` — and the comment block at
1375-1392 is an accurate account of exactly why it must. But:

```console
$ grep -c "_to_native_path" tools/aeb-link.ae
0
```

`aeb-link` is a separate binary with its own path handling and no copy of the
helper, so the toolchain dir reaches it raw. **Same `lib`-vs-`tools`
duplication as the pkg-config fix**, which had to land in both files; this one
landed in only one.

Not workaroundable from outside aeb: `command -v ae` returns the POSIX form
regardless of what form the PATH entry takes. Verified by putting
`$(cygpath -m /c/Users/paul/scm/aether/build)` on PATH — `command -v ae` still
yielded `/c/Users/paul/scm/aether/build/ae` and `dirname` still gave `/c/...`.

**Suggested fix:** apply the same normalisation in `tools/aeb-link.ae` at the
point the toolchain dir is received, or normalise before composing the argv in
whatever hands it over — whichever keeps the single-chokepoint property the
`lib` comment argues for.

---

## Bug 2 — the `cygpath -m` temp-dir fallback writes native but execs POSIX

With `TMP`/`TEMP`/`TMPDIR` all unset, the node log fills with:

```
sh: /tmp/_aeb_sh_2796_350778245.sh: No such file or directory
sh: /tmp/_aeb_sh_2796_1618946253.sh: No such file or directory
sh: /tmp/_aeb_sh_2796_1099867325.sh: No such file or directory
examples/golden_gallery: libaether.a not found near . — your Aether install looks incomplete
```

The script is **written** to `C:/msys64/tmp/...` (the `cygpath -m /tmp` fallback
in `_sh_script_path`) but **invoked** as `/tmp/...`. The two sides of the same
operation disagree about path form.

Isolation: setting `TMP=/tmp` takes those three errors to **0** and changes the
failure to Bug 1 above. So this is specifically the `cygpath -m` branch, not the
temp mechanism in general.

### Correction to the honesty note in `_sh_script_path`

That note (added with `a0fd182`, retracting an earlier claim) now says MSYS
"keeps TMP=/tmp populated even across an explicit `env -u TMP`", so the branch
does not fire on winbaz. Measured here it does fire, because in an
**ssh-driven** MSYS shell all three variables are genuinely empty:

```console
$ unset TMP TEMP TMPDIR
$ echo "TMP=[$TMP] TEMP=[$TEMP] TMPDIR=[$TMPDIR]"
TMP=[] TEMP=[] TMPDIR=[]
```

Interactive MSYS shells populate `TMP`; ssh-driven ones do not. That is very
likely where the two measurements diverged — and it matters beyond this bug,
because every Windows result depends on which kind of shell produced it.

Worth noting the note is otherwise right: `io.write_file("/tmp/x")` does
succeed, so the original theory it retracts was indeed wrong. The branch is not
harmless, though — it is currently the top failure.

**Suggested fix:** make the write form and the exec form the same string. If the
native form is needed for `io.write_file`, hand `sh` that same native form
(`sh` accepts `C:/msys64/tmp/...` — the Bug 1 trace above shows `sh` running a
script by exactly that path).

---

## Verification recipe

Touches nothing outside `target/`; safe against the live aether-ui tree.

```bash
export PATH=/mingw64/bin:/usr/bin:/home/paul/.local/bin:/c/Users/paul/scm/aether/build:$PATH
unset PKG_CONFIG_PATH TMP TEMP TMPDIR
cd /home/paul/aether-ui
aeb examples/golden_gallery/.build.ae
cat target/.aeb/logs/examples_golden_gallery.log     # Bug 2

export TMP=/tmp TEMP=/tmp AEB_SH_KEEP=1
aeb examples/golden_gallery/.build.ae
cat target/.aeb/logs/examples_golden_gallery.log     # Bug 1
ls -t /tmp/_aeb_sh_*.sh | head                       # the composed argv
```

`apps/tumbling_cube/.build.ae` is a second target with the same shape.

## Canonical checkouts on winbaz

So this can be driven on the box directly rather than through notes:

| Repo | POSIX path | Windows path | State |
| --- | --- | --- | --- |
| aether | `/c/Users/paul/scm/aether` | `C:\Users\paul\scm\aether` | v0.517.0, **built** |
| aeb | `/c/Users/paul/aeb` | `C:\Users\paul\aeb` | `0a32c43` |
| aether-ui | `/home/paul/aether-ui` | `C:\msys64\home\paul\aether-ui` | live tree — build only, do not modify |

**The two homes are different filesystems.** MSYS `/home/paul` is
`C:\msys64\home\paul`, *not* `C:\Users\paul`. aether and aeb live under the
Windows home; aether-ui lives under the MSYS home. Writing to
`C:/Users/paul/aether-ui/` appears to succeed and silently leaves the real tree
untouched — it cost a full round of false results here.

Two more traps on that box:

- **`/home/paul/aether` is a second, unbuilt aether checkout** (v0.514.0, no
  `build/`). Not the one to use; a `find` will offer it.
- **`ae`/`aetherc` are not on the login PATH.** `/c/Users/paul/.aether/bin` is
  on it but does not exist. `/c/Users/paul/scm/aether/build` must be added
  explicitly, or aeb reports `'ae' is not on PATH`.
- **`install.sh` does not build the working tree** — it downloads a GitHub
  tarball for `$REF`. Use `make install PREFIX="$HOME/.local"
  AETHER=/c/Users/paul/scm/aether/build/ae`, then check `aeb --version` matches
  HEAD. (The warning added in `a0fd182` now says this at run time.)
- **`strings <binary> | grep -c "<literal>"` is NOT a reliable check** for
  whether a fix is in an Aether-built binary — it returns 0 for binaries that
  demonstrably contain the code. Use behaviour (`AEB_SH_TRACE=1` and count
  trace lines) or the `aeb --version` git-describe instead.

## Environment

winbaz, MSYS2 / mingw64, gcc 16.1.0, aeb `0a32c43` built from the checkout,
aether v0.517.0 at `/c/Users/paul/scm/aether`. Reached over ssh (which is why
`TMP` is empty — see Bug 2).
