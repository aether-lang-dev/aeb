# REPLY: aeb's `lib/` no longer shadows a program's packages

Answering hosted-language-headers' ask `asks/aeb-lib-shadows-guest-language-bridges.md`
(2026-11-20).

**Status: RESOLVED in aeb** (the commit that adds this file; released in the
next aeb after v0.348). Nothing changes in aether or in hosted-language-headers,
whose `readiness/run.sh` can build hostpy, hostlua and hostruby as aeb nodes
again.

## Cause

`tools/aeb-link.ae` exported `AEB_COMPILE_LIB` as `<aeb>/lib:<project root>`, and
`lib/aether/module.ae` turned it into repeated `--lib` flags on every
`aether.program` and `aether.program_test` compile: on the `ae build` shell-out
path and on the standalone `aetherc` path (the one a node with `extra_source` or
`no_closure_regen` takes). A `--lib` entry is searched before an installed
package, and aeb's `lib/` holds builder modules named `lua`, `python`, `ruby`,
`go` and `java`, which are also the names of the bridges in
`aether-guest-languages`. `import lua` in a program found the builder module, and
`lua.run` was undefined. The path was put there for a reason (a program that
imports an aeb SDK module could not find it otherwise), but aeb's modules are
for build files, and a program is the user's.

## The fix

A program node is compiled with what `ae build` would give that project: the
project root (so a root-relative import still resolves), the node's own `lib()`
directories, and the project's installed packages. aeb's `lib/` is not on the
path unasked. `aeb-link` now exports `AEB_PROGRAM_LIB` holding the project root
alone, and `AEB_COMPILE_LIB` is gone (the orchestrator itself is still compiled
with `<aeb>/lib` and the root, because it is generated from build files that
import aeb's SDK). No compatibility shim: nothing else read the old variable.

A program that does import an aeb SDK module says so with `lib("${root}/lib")`,
which `aether.program` already supported. The nodes that needed it, found by
grepping the aeb tree and every family checkout for a non-build-file `.ae`
source that imports a name in aeb's `lib/`:

- `tools/agent/.dist.ae` (`aeb-agent` imports `agent` and `veto`)
- `tools/keygen/.dist.ae` (`aeb-keygen` imports `agent`)
- `tools/lease/.dist.ae` (`aeb-lease` imports `agent`)

There are no others. The program nodes under `tests/telemetry-json-smoke/` and
`itests/` import nothing from aeb's `lib/`; `tools/aeb-main.ae` and the other
tools are built by `make` with their own `--lib`, not as aeb nodes; the family
repos' build-file modules (`build_support/aetherui`, `mqjssources`, ...) import
`aether` and `c` as build modules, which is the intended use. `aeci` has its own
`veto` and `cache` modules in its own `lib/` and is built with `ae`.

## Test

`itests/program-imports-package-not-sdk.sh`, no network, in CI. A fixture package
with `modules = "lua"` and a `lua/module.ae` that has `run` and `finalize` is
wired in with `[patch]`, as `ae add` or `--override` would wire a real one. In
one `aeb` run: an `aether.program_test` that does `import lua` and calls
`lua.run` passes; a build file that does `import lua` (aeb's builder) and runs
`lua.test()` runs; a program that imports `agent` with `lib()` builds; the same
program without `lib()` is refused with `unresolved import 'agent'`. On the
previous main the first, the fourth and the combined run failed (the `E0301` of
the ask) and the last built.

## Other collisions

aeb's `lib/` module names (`aether agent angular approval bash bldr brew c cache
clojure container copy cpp crystal d dart dotnet elixir erlang fetch gleam go
groovy haskell janet java javascript jest julia kotlin lfe lua maven meta
moonbit mvngraph nim pharo php pnpm provision python ruby rust sandbox scala
swift ts veto veto_trace_os webhook webpack zig`) against:

- **The guest-language package's modules** (`lua python duktape js tcl perl ruby
  quickjs tinygo go java factor racket rhombus`): `lua`, `python`, `ruby`, `go`
  and `java` collide, which is what this ask is about. No other module of the
  package collides.
- **Aether's `std`**: `sandbox` has the same last name as `std.sandbox`. They are
  different imports (`import sandbox` is aeb's profile module, `import
  std.sandbox` the stdlib's), so nothing resolves wrongly, but a source file that
  imports both binds the prefix `sandbox` twice; none does.
- **Aether's `contrib`** (`avcodec d3d12 host i18n jq metal parsers png quickjs
  sqlite templating tinyweb vulkan`): no collision.
- **Every `aether.toml` with a `modules` key in the family checkouts**: only the
  guest-language package collides.

The reverse direction, a project module shadowing aeb's SDK inside a build file,
stays as before: a build file is compiled with `<aeb>/lib` first and the project
root after, so aeb's SDK wins there, and the project root now comes first for a
program, so a program's own module wins there. That is the order each reader
should see.

Another SDK for a language that a package also bridges can appear later, so the
rule is "aeb's `lib/` is for build files", not a renaming of either side.
