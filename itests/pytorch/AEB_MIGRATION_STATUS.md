# PyTorch → aeb Migration — Status

Upstream: https://github.com/pytorch/pytorch (shallow `--depth 1` clone).
Pinned only by the snapshot in `fetch-upstream.sh`; this is a moving
target by design — the value isn't reproducible bit-for-bit but
demonstrating that aeb's graph shape can express PyTorch's codegen-
heavy build without GLOB_RECURSE or phantom CMake targets.

## Not a test of record

This is a **fringe experiment**, not part of aeb's canonical test
surface. Cloning the aeb repo and running `tests/run.sh` exercises
every grammar addition (including `python.codegen` and its eight
setters — see `tests/test_python_codegen_cmd.ae`) without fetching a
single byte of upstream pytorch. The overlay files in this directory
are an end-to-end demonstration against a real-world codebase;
useful for shaking out integration bugs, but if `itests/pytorch/`
disappeared tomorrow the grammar guarantees would still be intact
under `tests/`.

If you're a cloner-and-builder, you do **not** need to run
`itests/fetch-upstream.sh`. The itests are optional, slow, and
network-dependent; the tests are mandatory, fast, and offline.

## Why PyTorch is interesting

PyTorch tried to migrate to Buck (the `BUCK.oss` files in the tree
are the receipt) and abandoned the WIP PR. The hard problem isn't
"depth-first build" — CMake's configure phase walks `add_subdirectory`
into `aten/`, `c10/`, `caffe2/`, `torch/` to collect targets and then
Ninja schedules the whole DAG in parallel. So the build itself is
graph-shaped already.

The actual sore points are:

1. **Codegen with hand-maintained DEPENDS lists.** `torchgen.gen`
   reads `aten/src/ATen/native/native_functions.yaml` + tags.yaml +
   templates and emits hundreds of `.cpp/.h` files. CMake can't infer
   a Python script's input set, so the rule's `DEPENDS` block is
   typed by hand — miss a file, get silent staleness; add one, get
   forced re-configure. See `cmake/Codegen.cmake` line 234 for the
   pattern.

2. **GLOB_RECURSE CONFIGURE_DEPENDS backstop.** `cmake/Codegen.cmake`
   line 77: `file(GLOB_RECURSE all_python ".../torchgen/*.py")`. Any
   touch in `torchgen/` forces a full configure pass — fast but
   re-walks the entire graph because CMake can't tell what changed.

3. **Cross-directory phantom targets.** Codegen outputs live in
   `${CMAKE_BINARY_DIR}/aten/src/ATen/` but are consumed by build
   targets defined in `caffe2/CMakeLists.txt`. CMake's target/
   directory scoping requires synthetic intermediate targets
   (`generate-torch-sources` is the canonical example) to thread
   outputs across.

4. **No native remote cache.** CCache helps with .cpp→.o, but the
   codegen step itself isn't cache-keyed by input content; it's
   keyed by mtime + the hand-maintained DEPENDS. Same input set
   between two builds → run codegen twice.

The aeb shape addresses (1) and (2) directly with explicit
`codegen_input` / `codegen_output` declarations (no glob); (3) with
file-to-file build.dep() edges across module boundaries; (4) with
the content-addressed cache (Maven, Java, aether SDKs already
consume it; codegen integration is a follow-up).

## Scope of this migration

**Not** a full PyTorch build. Pytorch end-to-end is 30+ minutes of
C++ compile per clean build on fast hardware; third-party deps
include CUDA, ROCm, OpenCV, gloo, NCCL, oneDNN, fbgemm, kineto,
sleef, ideep, tensorpipe, fmt, foxi, FlatBuffers, ONNX, …
Reproducing the world isn't the point.

The migration aims to:

- Express the codegen step (torchgen.gen → ATen generated sources)
  as a canonical aeb `.codegen.ae` file. Explicit inputs, declared
  outputs, mtime-driven staleness, no glob.
- Express `c10`'s smallest leaf module (`c10/util`) as a `.build.ae`
  with explicit `.cpp` file listing. Attempt to compile at least one
  TU with the host C++ toolchain.
- Stake the cross-module DAG edges with `build.dep()` lines so the
  ATen codegen step is upstream of any C++ target that consumes
  its outputs.
- Document the missing pieces (CUDA, third_party, full ATen build)
  so a future pass has a runway.

## Layout (overlay onto upstream)

```
itests/pytorch/                  (cloned by fetch-upstream.sh; ignored)
├── AEB_MIGRATION_STATUS.md      (this file — tracked)
├── torchgen/.whl.ae             (declare torchgen Python package — tracked)
├── aten/src/ATen/.codegen.ae    (torchgen.gen invocation — tracked)
├── c10/util/.build.ae           (c10/util C++ compile try — tracked)
└── … (everything else is upstream and gitignored)
```

The top-level `itests/.gitignore` pins every upstream path explicitly
so new aeb files we add are visible to git, and upstream source
churn doesn't pollute our diff.

## Status

| Step                            | aeb file                          | State              | Notes                                                                                              |
|---------------------------------|-----------------------------------|--------------------|----------------------------------------------------------------------------------------------------|
| torchgen as installable wheel   | `torchgen/.whl.ae`                | Declared           | `python.wheel_vendored` form; consumer venvs `pip install torchgen` from the in-tree source.       |
| ATen codegen via `torchgen.gen` | `aten/src/ATen/.codegen.ae`       | Declared, runnable | Drives `torchgen.gen --source-path ... --install_dir target/aten/...`. Output set is a sample.     |
| c10/util C++ compile            | `c10/util/.build.ae`              | Declared           | Targets the host C++ compiler with `-std=c++20 -I../..` and a `c10/util/*.cpp` glob. Will likely   |
|                                 |                                   |                    | fail without `c10/macros/cmake_macros.h` (generated by upstream CMake). Documented as TODO.        |
| ATen library (.so) build        | —                                 | Not started        | Needs the full third_party world (sleef, fmt, fbgemm, …) plus the codegen output enumerated.        |
| Caffe2 / libtorch / libtorch_python | —                              | Not started        | Cross-language Python↔C++ artifact handoff via aeb's existing shared_library_deps_including_transitive contract. |
| CUDA / ROCm / XPU               | —                                 | Not started        | Out of scope for this pass.                                                                         |
| `pytest` for the Python side    | —                                 | Not started        | `python.pytest(b)` already exists in lib/python; would need a `.tests.ae` per test module.          |

## What `python.codegen` adds to lib/python

A new builder lands alongside this migration:

```aether
python.codegen_driver(b, "torchgen.gen")           // python -m
python.codegen_input(b, ".../native_functions.yaml")
python.codegen_input(b, ".../tags.yaml")
python.codegen_input_dir(b, "torchgen")            // tool source — explicit, not glob
python.codegen_input_dir(b, "aten/src/ATen/templates")
python.codegen_arg(b, "--source-path=aten/src/ATen")
python.codegen_arg(b, "--install_dir=target/aten/src/ATen")
python.codegen_output(b, "target/aten/src/ATen/Functions.cpp")
python.codegen_output(b, "target/aten/src/ATen/Functions.h")
// … repeat for the rest of the generated output set
python.codegen(b)
```

Semantics:

- Skip when every declared output exists AND is newer than every
  declared input (mtime-driven, same model as `aether.regen`).
- Run the python command; fail the build if any declared output is
  missing afterwards (catches the silent-partial-generation bug
  CMake's `add_custom_command` doesn't).
- Write a `python_codegen_outputs` build artifact — newline-joined
  absolute paths — that downstream `.build.ae` consumers can read
  via the standard `build.dep` + artifact-read contract.

Caching is mtime-only for the MVP; a follow-up wires `lib/cache`
hash-by-input-content for cross-machine sharing.

## How to drive a partial build

From the aeb repo root:

```bash
# Once: fetch the upstream snapshot
./itests/fetch-upstream.sh

# Run the codegen step (needs PyYAML in a venv or system Python):
cd itests/pytorch
aeb aten/src/ATen/.codegen.ae

# Try the c10/util compile (likely fails on missing cmake_macros.h):
aeb c10/util/.build.ae
```

Failures here are diagnostic, not regressions — they reveal the
next-largest gap (`c10/macros/cmake_macros.h` is a CMake-`configure_file`
output; aeb's analogue would be a small generator step or a checked-in
shim header).
