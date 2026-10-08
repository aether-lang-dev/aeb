# REPLY: c.program and an aether_source with `main()` — fixed in aether, not here

Answering sae's ask (`asks/c-program-aether-source-main-entry.md`, 2026-10-07).

**Status: RESOLVED upstream in aether**: merged in
https://github.com/aether-lang-dev/aether/pull/2511 (the commit "codegen: a
library build of a program carries a weak C main()") and released in aether
0.791.0 (2026-10-08). Nothing changes in aeb; sae has deleted its
src/sae_entry.c and raised its floor to 0.791.0.

## Where the fix went, and why there

The ask proposed that c.program generate the C entry when an
`aether_source` defines `main()`. That would close the gap for aeb only: every
other tool that links an `--emit=lib` / `--emit=obj` object into an executable
(a Makefile, a bare `cc app.o $(ae cflags --libs)`, CMake, a Cargo build
script) would still need the same hand-written three lines.

So aether now emits them itself. A library-family build (`--emit=lib`, `obj`,
`staticlib`, `csrc`) of a program with `main()` defines, beside
`aether_main` / `aether_main_exit`, the executable's entry as a **weak**
symbol:

```c
__attribute__((weak)) int main(int argc, char** argv) {
    int rc = aether_main(argc, argv);
    aether_main_exit();
    return rc;
}
```

- A c.program (or anything else) that links the object into an executable gets
  `main` and the program's exit code with no extra source.
- A program that still brings its own C `main()` keeps it: a strong definition
  beats a weak one, so the "only when main is otherwise undefined" condition in
  the ask holds automatically, with no flag.
- A shared library's `main` is never where a process starts (aether-ui's
  Android activity and the dlopen host in aether's `emit_lib_keeps_main` test
  are unaffected).
- Not emitted for wasm (emscripten runs a module's `main` on load) or for a
  compiler without weak definitions; `-DAETHER_NO_LIB_MAIN` turns it off.

## Verified

- aether `tests/integration/emit_lib_keeps_main` check 9: the `--emit=obj`
  object links with plain `cc` and no C `main()` into a program that exits 42
  with its actors drained, and a host `main()` linked beside it still wins. On
  origin/main (0.789.0) the first link fails with `_main` undefined.
- sae with `src/sae_entry.c` deleted and its `.build.ae` line removed: links
  (`weak external _main` in the binary), and lower (38/38), spec_nav (45
  passing), `check_page_veto.sh` and `check_layers.sh` pass. Against origin/main
  the same tree fails with `Undefined symbols ... "_main"`.

## For sae

Once an aether release carries this, delete `src/sae_entry.c` and its
`sources("src/sae_entry.c")` line, and the `pins` floor moves to that release
(the change that needs the new behaviour).
