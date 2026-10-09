# ae compiler: inside a `builder` body, a local or parameter named like a module function resolves to the FUNCTION

**Status:** open. **From:** aeb, 2026-10-09 (moving aeb's floor to 0.801.0).
**Related:** `setter-mangle-collides-with-function-name.md` (a different
name-resolution collision in the same builder machinery).

## What happens

In a plain function, a parameter or local shadows a same-named top-level
function of the module, as expected. In a `builder` body it does not: the name
resolves to the module function (`<module>_<name>`), so the function's ADDRESS
is used where the local's value was meant. 0.801.0 (and every release back to
at least 0.741.0) rejects this only when the name is string-interpolated (E0200
"it is a function, so `${m_x}` renders its ADDRESS"); a comparison or an
argument compiles with at most a C warning, or a C error on a clang that makes
`-Wint-conversion` fatal.

## Minimal repro (0.801.0, also 0.791.0)

```
// lib/mm/module.ae
hello(_ctx: ptr, s: string) { println("setter ${s}") }
echo(w: string) { println("echo [${w}]") }
go(hello: string) { echo(hello) }               // fine: prints the param
builder bgo(hello: string): int {               // param resolves to mm_hello
    echo(hello)                                 // C: echo(mm_hello) -> -Wincompatible-pointer-types
    return 0
}
builder bgo2(x: string): int {
    hello = x                                   // W1001 "unused variable 'hello'"
    println("${hello}")                         // E0200: `${mm_hello}` renders its ADDRESS
    return 0
}
// main.ae: import mm; main() { mm.bgo("a") { } ; mm.bgo2("b") { } }
```

## The three aeb bugs it hid (all fixed in aeb by renaming)

- `java.java_main(main_class)`: the parameter collided with the `main_class()`
  setter, so the run command and messages named the setter's address. Every
  .build.ae calling `java.java_main` has failed to compile (E0200) since the
  setter landed; 0.801 now also rejects the module for importers that never
  call it.
- `bldr.install_launcher`: local `with_path` vs the `with_path()` setter;
  `if with_path == 1` compared the setter's address with 1, so `with_path()`
  never put BINDIR on the wrapper's PATH.
- `fetch.git`: local `depth` vs the `depth()` setter; `git_clone_cmd(..., depth)`
  passed the setter's address as the int depth. A C error under macOS clang
  (`-Wint-conversion`), a truncated-address `--depth` under gcc.

## Ask

Make builder bodies scope parameters and locals like plain functions do (a
local or parameter shadows a module function of the same name). Failing that,
make the collision a compile error at the declaration, not only at an
interpolation site: the silent cases are the dangerous ones.
