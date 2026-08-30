# Target parameters — `-P name=value`, declared per node, veto'd before exec

Status: **design (2026-08-30).** Chosen approach: **Option 4 (sidecar)** — the
node declares its parameters in a static block; aeb extracts that schema at
build time into a sidecar next to the node binary; at exec time aeb reads the
sidecar to validate `-P` args (unknown name / wrong type → hard error) *before*
running the node, and injects the resolved values for the node to read.

## The problem

aeb has no way to pass ad-hoc options to a `.<type>.ae` target. Everything
routes through environment variables (`FOO=x aeb foo/.build.ae`), which is the
same ergonomics as Maven's `-Dfoo=bar`: a global untyped namespace where a typo
(`--shaaaaards`) does *nothing*, silently. The whole ecosystem is migrating away
from this — Bazel deprecated `--define` in favour of typed, declared build
settings; cargo features, just/rake recipe params, and Bazel build settings are
all *declared, per-target, validated* inputs. This brings that to aeb, in aeb's
own grain (the filename is the route; the node declares what it accepts; exit
code is truth).

## Why not the obvious alternatives

- **Runtime-only `param_str(...)` calls in the body** can't veto `--shaaaaards`
  before exec: to know the valid names aeb would have to *run the node* (unsafe —
  the body shells out), and a `param()` behind an `if` isn't even reachable
  without running that branch. This is exactly Maven's silent-typo failure mode.
- **Re-grep the `.ae` on every invocation** (Option 1) works but re-parses source
  at every use. Option 4 parses once, at build time, when the node is already
  being compiled.

## The declaration (static, extractable)

A `params { … }` block at the top of the node, declaring name, type, default,
and help. It MUST be static (a top-level block, not `param()` calls scattered
behind `if`s) so the build-time extractor can read it without executing the node:

```aether
aeb(cap) {
    params {
        str("release", "17", "target JDK release")
        bool("fast", false, "skip the slow integration pass")
        int("shards", 1, "parallel test shards")
    }
    bldr.build() {
        java.javac() { source_ver(param("release")) }
        if param_bool("fast") { ... }
    }
}
```

Types (minimum viable set): `str`, `bool`, `int`. Room to grow to `enum("mode",
["fast","slow"], "slow", "...")` later — an enum is the highest-value addition
after the base three because it validates the *value*, not just the type.

The body reads a resolved value with `param("release")` (string) / `param_int(
"shards")` / `param_bool("fast")`. These read from the injected value map (see
below); the default from the declaration applies when `-P` didn't set it.

## The flow (extract at build, consume at exec)

1. **Build-time extraction (second parse).** When aeb compiles the node,
   `tools/extract-deps.ae` (which already does a needle-scan second parse for
   `dep("`, `scan("`, `prereq("`) gains a pass that reads the `params { … }`
   block and emits a schema sidecar:

   `target/<type>/<dir>/.params.json`
   ```json
   { "release": {"type":"str",  "default":"17", "help":"target JDK release"},
     "fast":    {"type":"bool", "default":false, "help":"skip the slow integration pass"},
     "shards":  {"type":"int",  "default":1,     "help":"parallel test shards"} }
   ```
   The sidecar lives beside the node's other per-node files (`.timestamp`,
   artifacts) under the `filename-is-the-route` layout, so its path is derivable
   from the target name exactly like every other node artifact.

2. **Exec-time validation (the veto).** `aeb-cli` already resolves the target
   `.ae` and its `target/<type>/<dir>/` before exec. The `-P` handling slots in
   right there:
   - parse `-P name=value` (repeatable) from argv;
   - read `.params.json` for the resolved target;
   - **unknown name** (`--shaaaaards`) → `aeb: unknown param 'shaaaaards' for
     java/.build.ae (did you mean 'shards'?)`, exit non-zero, node never runs;
   - **wrong type** (`-P shards=abc` where declared int) → `aeb: param 'shards'
     expects int, got 'abc'`, exit non-zero;
   - **valid** → merge over the declared defaults into the injected value map.
   - **`--help <target>`** prints the params table (name/type/default/help) read
     straight from `.params.json` — no node execution.

3. **Injection + runtime read.** The resolved values reach the node the same way
   other per-node context does (an injected map / an `AEB_PARAM_*` env carrier,
   TBD in build). `param("x")` / `param_int` / `param_bool` read it, falling back
   to the declared default.

## Staleness

`.params.json` is derived from the `.ae` source, so it must be regenerated when
the `params{}` block changes. Cheapest correct rule: the extractor rewrites it
whenever it (re)processes the node — i.e. the sidecar is a build output keyed to
the node like any other, and a `--help`/`-P` invocation that finds no sidecar
(node never built) either triggers the cheap parse-only extraction or reports
"run the target once so its params are known." The parse-only path is preferred
(cheap: it's a needle-scan of one file, no compile).

## What this deliberately is NOT

- **Not a global `-D` soup.** Every param belongs to a *named node* and is
  declared there; there is no cross-target ambient namespace.
- **Not `--` passthrough.** Forwarding argv to a spawned program (`cargo run --
  args`) is a separate, orthogonal concern; `-P` parameterises the *build*, not
  the thing the build runs. A `--` passthrough can be added later without
  touching this.
- **Not a binary section (yet).** The sidecar is fully aeb-doable today and
  portable. Emitting a `__aeb_params` section into the node binary (self-
  describing artifact, `readelf`-dumpable) is a nice later addition but needs
  Aether-compiler support (a section-attributed C global in codegen) — out of
  scope for the first cut.

## Touch points (the build)

1. **`tools/extract-deps.ae`** — add the `params{}` needle pass + `.params.json`
   emission. Pure-ish string scan, mirrors the `dep(`/`scan(` passes; unit-test
   it like `test_extract_deps_scan`.
2. **`lib/bldr/module.ae`** (or a new `lib/param`) — the `params{}` block DSL
   (`str`/`bool`/`int` setters into a schema map) + the runtime `param()`/
   `param_int`/`param_bool` readers over the injected values.
3. **`tools/aebcli/module.ae`** — parse `-P name=value` in the argv grammar
   (alongside the existing flag table) and thread it as a directive.
4. **`tools/aeb-cli.ae`** — after target resolution: load `.params.json`,
   validate `-P` (unknown/typo/type), emit the error-or-inject, and handle
   `--help <target>`.
5. **Tests** — extractor schema emission; CLI veto cases (unknown name → error,
   wrong type → error, valid → injected, default when omitted); `--help` output.

Each is small and independently testable; the veto (touch points 1+4) is the
load-bearing half and can land first, with the richer type set / enum following.
