# aeb-agent dogfood build (`tools/agent/.dist.ae`) is broken — AEB_COMPILE_LIB not threaded

**Found:** 2026-06-13, verifying the agent×container thread on oldnuc (ae 0.247)
and reproduced on the dev box (ae 0.244). **Pre-existing — NOT a regression from
the Windows/Axis-2 work or from 0.247.** The agent has only ever been built via
explicit `ae build tools/aeb-agent.ae --lib lib --lib tools -o <bin>` (what
winbaz + the dev box used); the *documented dogfood path* never worked.

## Symptom

`aeb tools/agent/.install.ae` (which deps `.dist.ae`) fails:

```
dist:tools/agent: ae build failed — aether program build failed
aetherc returned 1 for: .../tools/agent/../aeb-agent.ae
error[E0301]: Undefined function '_parse_tokens'   (from `import agent`)
error[E0301]: Undefined function 'build._sh'        (from `import build`)
...   (every imported symbol from agent / veto / build)
```

The failing command (from the dist log) has **NO `--lib` at all**:

```
aetherc  .../tools/agent/../aeb-agent.ae  .../bin/aeb-agent.c
```

So aeb-agent's imports (`agent`, `veto`, `build` from `lib/`) resolve to
nothing.

## Root cause (isolated)

`tools/agent/.dist.ae` is a single `aether.program` node:

```aether
aether.program(b) { source("../aeb-agent.ae")  output("aeb-agent") }
```

`aether.program`'s manual aetherc path (`lib/aether/module.ae:~1742`) threads the
SDK search path from **`AEB_COMPILE_LIB`** (set by `tools/aeb-link` as
`<aeb_lib>:<repo_root>`) onto the standalone compile:

```aether
compile_lib_env = os.getenv("AEB_COMPILE_LIB")
if string.length(compile_lib_env) > 0 { lib_flag = " --lib ${compile_lib_env}" }
ac_cmd = "${aetherc}${lib_flag} ${src_path} ${c_path}"
```

But for the dist node, `AEB_COMPILE_LIB` is **empty in the builder process**, so
`lib_flag` stays "" and aetherc gets no `--lib`. The `agent`/`veto`/`build`
modules DO exist (e.g. `$AEB_HOME/lib/agent`, `…/lib/veto`) — they're just never
put on the search path. Setting `AEB_COMPILE_LIB` in the *outer* env doesn't help
(aeb-link `setenv`s its own computed value, and evidently it's empty/unset by the
time the dist node's aether.program runs — the `--noexe`/dist path differs from a
normal per-node compile where the env IS set).

## Why it matters

The factpack (`agent_and_container_threads.md` §1.4) states the contract: *"If
aeb builds the agent, aeb installs it"* via `aeb tools/agent/.install.ae`. That
contract is currently false — the dogfood install can't build the agent. The
opt-in install only works if you bypass the dogfood and run
`ae build tools/aeb-agent.ae --lib lib --lib tools -o ...` by hand.

## Candidate fixes (for whoever takes lib/aether — possibly me next)

1. **Give `aether.program` an explicit lib-root setter** — e.g. `lib_root("lib")`
   / `lib_root("tools")` in the builder DSL, appended to the aetherc `--lib`
   chain. `.dist.ae` then declares what it imports. Most explicit; no env
   reliance. (Mirrors `c.aether_caps` / `include_dir` precedent.)
2. **Fix the env threading** so `AEB_COMPILE_LIB` is set for the dist-node
   aether.program the same way it is for a normal per-node compile (find why it's
   empty on the dist path specifically).
3. **`.dist.ae` workaround**: if neither, the install doc should say the dogfood
   needs `AEB_COMPILE_LIB` exported — but that's a smell; prefer (1).

Repro (any box): `cd <aeb checkout> && aeb tools/agent/.dist.ae` → the E0301s
above. Confirms: explicit `ae build tools/aeb-agent.ae --lib lib --lib tools -o
/tmp/x` succeeds (proving it's purely the lib-search-path threading, not the
agent source).
