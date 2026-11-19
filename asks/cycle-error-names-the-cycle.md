# A dependency-cycle error should show the cycle

**From:** a review of David Nelson's Casper (`../casper2`), 2026-11-19
**Status:** open, not started. A small fix.

## What happens today

Three nodes, `a → b → c → a`:

```
$ aeb a/.build.ae
error: circular dependency involving a/.build.ae
aeb: topo-sort produced no build order for a non-empty graph.
     The error it printed above (e.g. a circular dependency) is the cause.
```

(Reproduced 2026-11-19.) It names one node on the cycle and nothing else. With
three nodes you can work it out; in a large tree you have to grep `dep(` lines
by hand to find which edge closes the loop, and that edge is the one to delete.

The message comes from `dfs_visit` in `tools/topo-sort.ae`, which finds a node
already marked `visiting` and prints just that node.

## What Casper does

casper2 refuses the edge at the moment it is added
(`Target.DependsOn` → `TransitivelyDependsOn`, `source/Core/Target.cs`), so
the error is tied to the exact edge that closes the cycle. aeb extracts edges
textually and sorts afterwards, so it can't refuse at add time, but it can
report the same information.

## Ask

When `dfs_visit` finds a `visiting` node, print the path from that node
around to itself, one edge per line, with the file that declares each edge:

```
error: dependency cycle:
  a/.build.ae  →  b/.build.ae
  b/.build.ae  →  c/.build.ae
  c/.build.ae  →  a/.build.ae   (closes the cycle)
```

The DFS already holds the path implicitly in its recursion. Keep an explicit
stack list beside `visited_map` (push on `visiting`, pop on `done`), and on
detection print the stack from the first occurrence of the node to the end.

Two notes:

- The `AEB_SCHED=native` scheduler has its own stall message
  (`tools/aeb-driver.ae`, "dependency cycle or unknown dep"). It is only
  reached if topo-sort let a cycle through, so leave it, but it may be
  worth making it say which labels were never placed.
- Exit status stays 1, and the message stays on stderr via `io.stderr_write`
  (no shell redirect, per the Windows note in that function).

## Acceptance

- The three-node case above prints all three edges and exits 1.
- A self-edge (`a` depends on `a`) prints one line.
- A cycle reached through an acyclic prefix (`x → a → b → a`) prints only
  `a → b → a`, not `x`.
- An itest, or a case added to an existing graph itest, pins the output.
