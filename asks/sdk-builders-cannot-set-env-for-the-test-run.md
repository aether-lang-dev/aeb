# Most SDK test builders cannot set an environment variable for the run

**From:** html-sanitizer (2026-08-23), migrating 21 language bindings from
hand-rolled `os.system` to idiomatic SDK builders.

## The shape

html-sanitizer is one Aether engine (`core/embed.ae` → a C ABI `.so`) plus 21
thin bindings. Fifteen of those bindings **load the `.so` at run time** —
ctypes (python), Fiddle (ruby), koffi (javascript), FFI (php, lua, dart),
Panama (java/kotlin/scala/groovy/clojure), NIF (erlang/elixir/gleam). Every
one resolves the engine from **`$HTMLSANITIZER_LIB`**, set to the path the
engine node published:

```
lib = build.dep_artifact(b, "core/.build.ae", "shared_lib")
```

The DAG part is already right, and is the thing aeb is good at. The problem is
purely getting that one value into the test process.

## What's missing

Of the SDK libs we need, only **`lib/go`** (`env_var`, module.ae:41) and
**`lib/aether`** (`env_var`, module.ae:71) can set an env var on the run.

`python`, `ruby`, `rust`, `dart`, `javascript`, `php`, `nim`, `zig`, `dotnet`,
`elixir`, `haskell`, `lua`, `gleam` have no equivalent. Their run commands are
built by pure helpers that take no env parameter — e.g.

```
pytest_cmd(py_bin: string, source_dir: string, root: string) {
    return "cd '${root}' && '${py_bin}' -m pytest '${source_dir}' -v"
}
```

`build.env(b, k, v)` exists but does **not** reach these builders — it stores
under `proc_env`, which only the *project* builders drain. `kotlin/.tests.ae`
in our repo documents discovering this the hard way and works around it with
`-Dhtmlsanitizer.lib=…` as a JVM system property; that trick is available only
because the JVM has system properties. python/ruby/php/lua have no equivalent.

## The ask

A uniform `env_var(ctx, "KEY=value")` setter across the SDK libs that run
something — matching the one `lib/go` already has, so there is a precedent to
copy rather than a new concept:

```
python.pytest(b) {
    env_var("HTMLSANITIZER_LIB=${lib}")
}
```

Alternatively, make `build.env(b, k, v)` reach SDK builders, which would fix
all of them at once and remove the `proc_env`-only surprise. We'd prefer this
one — it is the API a reader already expects to work.

## Why it matters beyond us

This is the generic "native library built by one node, loaded by a test in
another language" case. `../google-monorepo-sim` is the same pattern and gets
away without it because its consumers are JVM/Go, where aeb auto-wires
`-Djava.library.path` / `LD_LIBRARY_PATH` from the `ldlibdeps` artifact. As
soon as a binding resolves its native dep through an env var of its own naming
— which is what every scripting-language FFI does — there is no way to express
it.

## Workaround we are using meanwhile

`os.system` with the env var inline, i.e. exactly the hand-rolled invocation
the SDK builders exist to replace. It works, but it means 15 of 21 bindings
cannot adopt the SDK builders at all, and we lose what those builders provide
— toolchain vetoes, skip-vs-fail semantics, caching, consistent telemetry.
