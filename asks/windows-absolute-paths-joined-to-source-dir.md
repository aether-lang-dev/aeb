# Windows: absolute `extra_source` paths get joined to source_dir anyway

**From:** the aether-ui line (2026-08-03) · **Where it bit:** winbaz
(Windows 11 / MSYS2), building `apps/frames_demo` — and by extension every
aether-ui app, so the whole Windows spec matrix.

## Symptom

```
cc1.exe: fatal error: C:/Users/paul/aether-ui/apps/frames_demo/C:/Users/paul/aether-ui/backend/aether_ui_win32.c: Invalid argument
compilation terminated.
cc1.exe: fatal error: C:/Users/paul/aether-ui/apps/frames_demo/C:/Users/paul/aether-ui/backend/aether_ui_test_server.c: Invalid argument
compilation terminated.
```

Two absolute paths concatenated: the target's source_dir, then the absolute
path the builder actually asked for.

## Cause

`lib/aether/module.ae` documents the intended contract at ~line 213:

> Relative paths are resolved against source_dir at gcc time (consistent with
> `regen(...)`). Absolute paths pass through.

and repeats it for `include_dir` (~289), `extra_source` (~262), and the glob
expansion (~432). The passthrough test evidently recognises only POSIX
absolute paths (a leading `/`), so a Windows absolute path — `C:/...`,
drive letter + colon — is classified as relative and joined to source_dir.

aether-ui's builder deliberately uses absolute paths, and says so:

```
// The backend C/ObjC/headers live under backend/, addressed absolutely via root.
builder ui_backend(root: string) {
    ...
    extra_source("${root}/backend/aether_ui_win32.c")
    extra_source("${root}/backend/aether_ui_test_server.c")
```

On Linux and macOS `root` starts with `/`, hits the passthrough, and works.
On Windows `root` is `C:/Users/paul/aether-ui`, misses it, and gcc gets a
path that cannot exist.

## Ask

Make the absolute-path test platform-aware wherever it is applied
(`extra_source`, `include_dir`, `extra_object`/`link` paths, and the glob
expansion — the doc comments say all four share "the same rule"). A path is
absolute if **any** of:

- it starts with `/` (POSIX, and MSYS-style `/c/...`),
- it starts with `\\` (UNC), or
- its second and third characters are `:` and a slash — `C:/` or `C:\` —
  i.e. `length >= 3 && char_at(1) == ':' && (char_at(2) == '/' || char_at(2) == '\\')`.

A single helper used by all four call sites would keep them from drifting.

## Why this is worth fixing rather than working around

The obvious workaround — have callers pass relative paths — is wrong here.
`aether-ui`'s apps live at `apps/<name>/` while the backend C lives at
`backend/`, so a relative path would be `../../backend/aether_ui_win32.c`,
which breaks the moment an app nests differently. The whole reason the
builder takes `root` is to be independent of where the target sits.

It also silently costs a platform: aether-ui builds on Linux, macOS and
FreeBSD but not Windows, and the failure looks like a compiler error rather
than a build-system path bug, so it reads as "the Windows backend is broken"
when the backend is fine.

## Confirmation that the join is the cause

Patching aether-ui's `apps/frames_demo/.build.ae` to pass a RELATIVE root
(`ui_backend("../..")` instead of `ui_backend(root)`) changes the failure
from

    cc1.exe: fatal error: <source_dir>/C:/Users/paul/.../aether_ui_win32.c: Invalid argument

to a plain `ld` link error — i.e. the C sources are now found and compiled.
So the path handling is the bug; the backend sources and the compiler are
fine. (The relative form is not a usable fix — see above — it just isolates
the cause.)

## Environment

- Windows 11 + MSYS2, gcc 16.1.0 (mingw64), ae 0.473.0
- aeb at `85e6743` (fresh clone, 22/22 build tools compiled cleanly)
- Reproduce: any aether-ui app, e.g.
  `cd ~/aether-ui && aeb apps/frames_demo`
- The same tree builds clean on Linux (ae 0.473) and macOS (ae 0.473).
