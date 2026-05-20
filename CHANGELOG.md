# Changelog

## Unreleased

### Added

- **`lib/python`: `python.codegen` builder** for codegen-driver
  scripts (PyTorch's `torchgen.gen`, gRPC's `protoc-gen-py`, sqlalchemy
  migrations). DSL closure with explicit input declaration
  (`codegen_input` / `codegen_input_dir`), declared outputs
  (`codegen_output` — verified after the run), arg list
  (`codegen_arg`), and module-form / script-form drivers
  (`codegen_driver` / `codegen_script`). Skips when every declared
  output is newer than every declared input (mtime-driven, same
  shape as `aether.regen`). Fails the build if any declared output
  is missing after the run — catches CMake's silent-partial-
  generation trap. Pure command builder
  (`python_codegen_cmd`) covered by 6 assertions in
  `tests/test_python_codegen_cmd.ae`.

- **PyTorch integration test scaffolding** (`itests/pytorch/`,
  documented in `itests/pytorch/AEB_MIGRATION_STATUS.md`). Three
  overlay files on top of an upstream shallow clone:

  - `aten/src/ATen/.codegen.ae` — drives `python -m torchgen.gen`
    over `native_functions.yaml` + `tags.yaml` + templates with
    explicit `codegen_input` declarations. Replaces upstream's
    `cmake/Codegen.cmake` `add_custom_command` block plus the
    `file(GLOB_RECURSE all_python "torchgen/*.py")` CONFIGURE_DEPENDS
    backstop. Verified end-to-end: torchgen runs (15s), produces 102
    real C++ source/header files, second invocation is a 40ms
    mtime-skip.

  - `c10/util/.build.ae` — explicit 39-file source list (out of 42
    upstream `.cpp` files) compiled by `c.compile` with `g++
    -std=c++20`. Demonstrates the no-glob contract: upstream
    `file(GLOB C10_SRCS CONFIGURE_DEPENDS *.cpp …)` would silently
    rope in `env.cpp` / `signal_handler.cpp` / `tempfile.cpp` which
    pull in `<fmt/format.h>` that isn't wired yet. The explicit list
    makes those 3 omissions a visible TODO instead of a build
    failure. Produces 39 ELF `.o` objects.

  - `torchgen/.whl.ae` — declares torchgen as an installable Python
    package via `python.wheel_registry`, so downstream `.build.ae`
    consumers can `build.dep` on it.

  Plus `itests/.gitignore` adjustments to allow `.codegen.ae` and
  `*.whl.ae` overlay files through the gitignore allowlist.

- **`lib/aether`: extern link-failure diagnostic hint** (Option B from
  `asks/transitive-regen-extern-followup.md`). When gcc fails with
  `undefined reference to <sym>` during a manual aether.program link,
  aeb now scans every `module_generated.c` under the workspace root,
  groups any symbols that resolve to sibling Aether modules, and emits
  a `regen_with("<path>", "<caps>")` hint line per defining sibling.
  Symbols that don't resolve to a project module (libc, runtime libs)
  produce no hint — true C externs aren't false-flagged. Covered by
  `tests/test_aether_extern_diagnostics.ae`.
