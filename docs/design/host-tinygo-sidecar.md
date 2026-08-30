# Host-TinyGo: the sidecar-`.so` builder shape

Status: IMPLEMENTED + NUC-validated GREEN (2026-06-05). aeb-side + aether-side
split. Companion to [two-aeb-duality.md](two-aeb-duality.md) and
[guest-languages.md](guest-languages.md).

> **What shipped vs. this design (read first):**
> - **Built with standard `go`, NOT `tinygo`.** TinyGo's `-buildmode=c-shared`
>   is wasm-only ("buildmode c-shared is only supported on wasm at the moment");
>   native sidecars use `CGO_ENABLED=1 go build -buildmode=c-shared`. The bridge
>   dlopens the .so at runtime and doesn't care which compiler made it. The
>   `aether.tinygo_lib` verb + `contrib.host.tinygo` loader keep the name.
> - **The tinygo_lib node lives in its OWN subdir** (`hosttinygo/greet/`): two
>   builder nodes can't share a module dir (aeb keys the module on the directory).
> - **`link_flags = "-lffi"`** is required in the consuming aether.toml — the
>   tinygo bridge .a uses libffi and aether's import auto-link doesn't add it yet.
> - aeb runs `ae build` from the module source dir so that aether.toml is read
>   (was a latent aeb bug; fixed in `_shell_out_ae_build`).
> Validated on the real Bazzite NUC: `hello from tinygo, hosted by aether` +
> `Add(2,40)=42 Answer()=42` (real Go fns called in-process on the host).

## Why tinygo is different from the six interpreter bridges

python/ruby/perl/lua/tcl/duktape all share one shape: you hand the bridge a
**source string** and it `dlopen`s the host's system interpreter to eval it
(`python.run("…")`). The artifact that ships is the single aeb-compiled binary;
the host lib is a *distro* dependency the bridge finds at runtime via
`AETHER_<LANG>_SONAME`.

`contrib.host.tinygo` is the inverse, and it's the interesting one:

- There is **no system "libtinygo."** Instead, the user writes a `.go` file, and
  **TinyGo compiles it to a `c-shared` `.so`** (`tinygo build -buildmode=c-shared
  -o libgreet.so greet.go`).
- Aether then `tinygo.load("./libgreet.so")` at runtime and calls the *exported
  Go functions directly* (`tinygo.call_int_int_int(h, "Add", 2, 40)`), in the
  same address space — no IPC, no subprocess. API is `load` / `call_*` /
  `unload`, not `run` / `finalize`.

So **two artifacts must travel together** to the host: (1) the aeb-compiled
Aether binary, and (2) the user's TinyGo-built sidecar `.so`. The Aether binary
`dlopen`s the sidecar by path at runtime, so the `.so` must sit beside it on the
host.

The bridge itself (`contrib/host/tinygo/{module.ae,aether_host_tinygo.c,.h}`)
**already exists and has an integration test** in the aether repo. What's missing
is the *build orchestration* — and it splits cleanly across the two repos.

## The duality, applied to a user-compiled artifact

Decision (Paul, 2026-06-04): **TinyGo compiles the `.go` → `.so` IN the container,
Phase 1.** This matches the six-bridge model exactly — *all* compilation in the
container, *all* execution on the host — and keeps the host TinyGo-free.

```
Phase 1 (in aeb-toolchain-tinygo:slim, --compile-only):
  - tinygo build -buildmode=c-shared -o target/.../libXXX.so user.go   ← TinyGo step
  - ae build the Aether .ae → the orchestrator + the program binary
  both land on the host via the :Z mount.

Phase 2 (on host, --execute-only):
  - run the Aether binary; it tinygo.load()s the sidecar libXXX.so
    (which is right there on the mount, next to it). No TinyGo on the host.
```

## aeb-side: the `aether.tinygo_lib` builder verb (full integration)

Decision (Paul): not just a walking skeleton — a **general builder verb** any
project can use to declare a Go sidecar, wired into the DAG.

New builder in `lib/aether/module.ae`, modeled on `program`/`program_test`:

```
aether.tinygo_lib(b) {
    go_source("greet.go")        // the user's .go (relative to module dir)
    output("libgreet.so")        // sidecar name the .ae will tinygo.load()
}
```

Mechanics (mirroring the existing builders):
- **Setters** `go_source(file)` / `output(name)` write ctx map keys (same shape
  as `source()`/`output()` at module.ae:21).
- **Compile phase** (gated on `build._compile_enabled()`, exactly like
  program_test at module.ae:1955): shell out
  `tinygo build -buildmode=c-shared -o <target_dir>/<output> <source_dir>/<go_source>`
  via `os.system`. Under `aeb-ctr` this runs in the container (TinyGo present);
  the `.so` lands on the host mount. Honors the same `AEB_COMPILE_CONTAINER`
  delegation seam the other builders use (module.ae:974) so a non-aeb-ctr host
  can still delegate.
- **Execute phase** (`build._execute_enabled()`): nothing — a lib has no run
  step. (It's a dependency of a `program`/`program_test` node that loads it.)
- **DAG wiring**: the `.so` is a declared output; a downstream `program_test`
  node that `dep()`s the tinygo_lib gets the `.so` path resolved
  (`_dep_target_dir` in lib/build) so its `.ae` can `tinygo.load(thatpath)`.
  This is what "full integration" buys over a one-off skeleton: the sidecar is a
  first-class graph node, cache-keyed on the `.go` content, rebuilt only when the
  `.go` changes.

Phase-gate note: `tinygo_lib` is compile-only by nature, so it's naturally inert
under `--execute-only` and active under `--compile-only` — no special casing.

## aether-side: `aether-build --with=tinygo` (the install layer)

TinyGo is **not** an apt package, so `with_dev_pkg()`'s simple name→pkg table
doesn't fit. It needs a custom install layer in the generated Containerfile that
fetches the TinyGo release from GitHub (a `.deb` or the tarball), similar in
shape to whatever `--with=java` does for the JDK. Sibling owns this. Specifics:

- Add `tinygo` to the `--with=` known set (and the "unknown language" list).
- Because it's not a one-liner apt install, the per-lang layer for tinygo is a
  small script: download the pinned TinyGo release for the image arch, install
  it, put `tinygo` on PATH. (Go itself comes along or is a prerequisite — TinyGo
  needs a Go toolchain; the layer should ensure both.)
- `make contrib MODULES=tinygo` must build `libaether_host_tinygo.a` (the bridge
  .a). The bridge .c uses `aether_dl_*` (std.dl wrappers) — per the sibling it's
  already dlopen-shaped, nothing to rewrite; it just needs to be in the
  MODULES-buildable set in `contrib_build.sh` (it currently is NOT — see survey).
- Resulting image: `aether-builder-tinygo:slim`, then aeb layers on top exactly
  as for the six (`--build-arg AETHER_BUILDER_IMAGE=aether-builder-tinygo:slim`).

No `AETHER_TINYGO_SONAME` needed — the sidecar `.so` is loaded by explicit PATH
(the user's `tinygo.load("./libXXX.so")`), not by soname discovery. That's the
other way tinygo differs from the six.

## The readiness target (walking skeleton, falls out of the builder)

`hosted-language-headers/readiness/hosttinygo/`:
- `greet.go` — copy of the bridge's example (Answer/Add/Negate/Greet).
- `hosttinygo.ae` — `import contrib.host.tinygo`; `tinygo.load("./libgreet.so")`;
  call `Add(2,40)`, `Answer()`; print `hello from tinygo, hosted by aether`
  (+ the computed values to prove real cross-language calls, not just a banner).
- `.build.ae` — declares the `tinygo_lib` (greet.go → libgreet.so) AND a
  `program_test` that deps it. Phase 1 builds both in-container; Phase 2 runs the
  Aether binary on the host, which loads the sidecar.
- `aether.toml` — empty (no soname; import-driven bridge .a auto-link).

Capstone: `AEB_CTR_IMAGE=aeb-toolchain-tinygo:slim aeb-ctr hosttinygo/.build.ae`
→ `hello from tinygo, hosted by aether` + `Add(2,40)=42` + `Answer()=42`,
validated on the NUC. Same bar as the six.

## Split of work

| Piece | Side | Status |
|---|---|---|
| bridge `.c`/`.h`/`module.ae` | aether | ✅ exists + integration test |
| `--with=tinygo` install layer (fetch TinyGo + Go) | aether | ⬜ sibling |
| `tinygo` in `contrib_build.sh` MODULES set | aether | ⬜ sibling |
| `aether.tinygo_lib` builder verb + DAG wiring | aeb | ⬜ this work |
| `hosttinygo/` readiness target | aeb (headers repo) | ⬜ this work |
| NUC end-to-end validation | aeb | ⬜ after both land |

## Open questions for the sibling

1. Does `--with=tinygo` also need to install a full **Go** toolchain (TinyGo
   depends on `go`), or does the TinyGo release bundle enough? Affects the layer
   size and the install script.
2. Pin: which TinyGo version should the image bake? (We'll pass it like
   `AETHER_REF` or a dedicated `TINYGO_VERSION` build-arg.)
3. Is the bridge `.a` build (`make contrib MODULES=tinygo`) actually wired, or
   does `contrib_build.sh` need a `build_module tinygo …` line added (it's absent
   from the MODULES set today)?
