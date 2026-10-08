# c.program: an `aether_source` whose program has `main()` links with no entry

**Status:** open. **From:** sae (`sae-it-aint-so`), 2026-10-07.
**Related:** aether #2489 (`--emit=lib` keeps a program's `main()` as
`aether_main` / `aether_main_exit`, released in 0.789.0).

## The gap

`c.program` compiles each `aether_source(...)` with `aetherc --emit=lib`
(`lib/c/module.ae`, the `emit_cmd` lines) and links the objects with the
program's C sources. Until 0.789.0 `--emit=lib` dropped a program's `main()`,
so a c.program whose entry was Aether had to supply a C `main()` that called
some named Aether function (sae's `src/sae_rom.c` did:
`main() { return sae_main(argv[1], argv[2], argv[0]); }`), skipping the
executable prologue (args, Capsicum, scheduler) entirely.

From 0.789.0 the program's `main()` survives `--emit=lib` as

```c
int  aether_main(int argc, char** argv);
void aether_main_exit(void);
```

but c.program still emits no C `main()`, so a c.program whose `.ae` defines
`main()` fails to link:

```
Undefined symbols for architecture arm64:
  "_main", referenced from: <initial-undefines>
```

## Repro

sae at the 2026-10-07 working tree (main() moved into `src/sae_host.ae`,
`src/sae_rom.c` keeping only `sae_stdout`), with `src/sae_entry.c` removed from
`.build.ae`: `./build.sh` against Aether 0.789.0 (the `../aether` dev tree).

## Ask

When a c.program's aether_source defines `main()` (the generated C has
`int aether_main(int argc, char** argv)`; or the catalog says so) and no
other source provides `main`, c.program adds the executable's entry, exactly
what aether's `docs/emit-lib.md` ("A program's `main()`") says an executable
amounts to:

```c
int main(int argc, char** argv) {
    int rc = aether_main(argc, argv);
    aether_main_exit();
    return rc;
}
```

(a generated TU under the node's build dir). A program that still brings its
own C `main()` keeps working: only add it when `main` is otherwise undefined,
or when a `c.program` flag opts in.

## Local workaround in the meantime

sae's `src/sae_entry.c` is that `main()`, labelled as a workaround pointing
here, listed in `.build.ae` for the desktop build only (the Android build is a
library its activity loads and needs no `main`). Delete it when c.program
does this itself.
