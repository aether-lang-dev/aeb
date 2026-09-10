# `aeb --graph mermaid` — colouring the DAG by the last build's outcome

`aeb --graph mermaid` emits the build-file DAG as a Mermaid `graph TD`. On its
own that shows the *shape* of the graph — which is useful, but static: it reads
identically whether or not anything ever ran. When a build **has** run in the
tree, the mermaid output now overlays that run's per-node outcome onto the same
graph, so it answers a sharper question:

> what did *this* `aeb <target>` (or `--since <ref>`) actually touch, and how
> did each node go — invoked vs uninvoked, passed vs failed?

## What the colours mean

Each node is given a Mermaid class, and the block carries the matching
`classDef`s:

The graph is the **full parsed DAG** — every dot-prefixed `.ae` node found by
scanning, every `build.dep(...)` edge, i.e. all the *possible* deps collected
from parsing. The colours then say which of those the last run actually executed:

| Class | Colour | Meaning |
|---|---|---|
| `:::ok` | green | executed in the last run, exited 0 (this includes a cache-**hit** — the node ran, its SDK just skipped the work) |
| `:::fail` | red | executed, exited non-zero |
| `:::uninvoked` | dimmed grey | in the parsed tree but **not executed** by the last run |

So it's a single graph showing the **executed paths** (green/red) against the
**muted possible-deps that were only parsed, not run** (grey).

The grey nodes are **not a detached list** — they stay in the same DAG with all
their `build.dep` edges drawn, to and from the executed nodes. So the muted part
is still a *dependency graph*: you can trace what an un-run node would pull in,
and see how it hangs off the executed core, at the same glance. Colour is the
only thing that changes; topology is the full parsed graph either way.

**What the 3 states deliberately do NOT split** (kept simple on purpose):

- **grey folds two not-executed reasons** — a node genuinely *out of scope*
  (outside the `aeb <target>` / `--since` selection) and a selected node that
  was *skipped because a dependency failed* both read as `:::uninvoked`. The
  common case — "not in this invocation" — is what grey communicates; the
  dep-failed-skip is rarer and its cause is visible from the red node upstream.
- **green folds rebuilt vs cache-hit** — a node that did real work and one that
  cache-hit both read `:::ok` (both *ran* as processes). "Did it rebuild or hit
  the cache" is a `[hit]`/`[miss]` question answered by the `[telemetry]` block,
  not the graph.

Both distinctions are answerable from the telemetry JSON, and could be threaded
into the graph later; today's colouring intentionally stays a 3-state
executed-vs-parsed overlay rather than a 5-state one.

Example, after building `app` (which deps `lib`) while `tests` was out of scope:

```mermaid
graph TD
    classDef ok fill:#c6f6d5,stroke:#276749,color:#1a202c
    classDef fail fill:#fed7d7,stroke:#9b2c2c,color:#1a202c
    classDef uninvoked fill:#edf2f7,stroke:#a0aec0,color:#a0aec0
    app__build_ae["app/.build.ae"]:::ok
    lib__build_ae["lib/.build.ae"]:::ok
    tests__tests_ae["tests/.tests.ae"]:::uninvoked
    app__build_ae --> lib__build_ae
    tests__tests_ae --> app__build_ae
```

## Using it

```sh
aeb app/.build.ae            # (or: aeb --since main) — do a build first
aeb --graph mermaid > dag.md # colours by that build; renders inline on GitHub
```

## Behaviour that's easy to trip on

- **The colour is the LAST build, not this command.** `--graph` is a query — it
  reads the DAG and exits, it doesn't build. So the colours reflect whatever run
  most recently left markers in the tree. Re-run the build to refresh them.
- **Cold `--graph` (never built here) → plain, uncoloured graph.** No markers,
  no styling. Fully backward-compatible with the pre-colouring output.
- **Both formats are coloured.** mermaid via `:::ok/fail/uninvoked` classes;
  DOT via `[style=filled, fillcolor=...]` (green/red, and grey + dimmed
  font/border for uninvoked) — so `aeb --graph … | dot -Tsvg` produces a
  coloured SVG/PNG, same executed-vs-parsed overlay as the inline mermaid. Same
  rc-dir signal drives both.

## Where the data comes from

The per-node outcome is read from the driver's markers under
`target/.aeb/rc/` — one `<san>.rc` file per node aeb ran (`0` = ok, non-zero =
fail; **absent** = the node wasn't part of the run). `aeb-main` passes that
directory to `aeb-graph` as an optional argument when it exists; `mermaid_render`
classes each node from it. The node→marker filename mapping mirrors the driver's
`_san()` so a build-file path resolves to the same marker file it wrote. See
[nodes-as-subprocesses.md](nodes-as-subprocesses.md) for those markers.

## The deliberate limit — it colours a file-level DAG, it doesn't deepen it

aeb's DAG is **file-level**: nodes are dot-prefixed `.ae` build files, edges are
grepped `build.dep(...)` lines (see
[filename-is-the-route.md](filename-is-the-route.md)). The colouring overlays
the run onto that static shape; it does **not** graph control flow *inside* a
build body. There is deliberately no "which branch of the build script fired"
data — `dep(...)` is a runtime no-op used only for graph extraction, and a
node's body is arbitrary Aether aeb doesn't introspect. So "invoked vs
uninvoked" is answerable at node granularity (did this node run?), and "why did
it run" is answerable from the graph edges + `--since`, but intra-node execution
tracing is out of scope by design, not by omission.
