# extract-deps' scan() needle missed the Shape-A sweep — scan-roots fan out to ZERO, exit 0

**From:** the aether-ui line (2026-08-27) · **Where it bit:** the first
post-sweep fan-out on all three aether-ui boxes: `aeb .all.ae` reported
`aeb: 1 all`, built NOTHING, and exited 0 — a matrix of ~80 NO BINARY
rows was the first visible symptom, two hops from the cause.

## The gap

`tools/extract-deps.ae` pass 1 was updated to the b-free spelling
(`needle = "dep(\""`, line ~351) but pass 2 still greps the OLD form:

```
scan_needle = "scan(b, \""        // line ~393
```

A Shape-A root's `scan("examples/**/.build.ae")` never matches, so the
static extractor finds no children, the topo graph is just the all-node,
and the run "succeeds". The runtime `bldr.scan()` doc says the two paths
"produce the same set" — after the sweep they produce DIFFERENT sets for
every scan() call, and the static one wins the scheduling.

aether-ui is evidently the only scan-root among the six swept repos,
which is why the sweep's own verification didn't catch it.

## Asks

1. Update the pass-2 needle to the Shape-A spelling (`scan(\"`), keeping
   the old one too for unconverted repos — mirroring however dep( handles
   both.
2. The deeper false-success: a fan-out ROOT whose extraction yields zero
   build children is essentially never intentional — `scan()`'s runtime
   half already makes zero matches "a hard error — typo protection", but
   the STATIC path has no such guard, and it is the scheduling path.
   `aeb: 1 all` + exit 0 should instead be at minimum a loud warning
   ("root declares scan() but extraction found 0 nodes — extractor/
   runtime divergence?").

## Workaround in place

aether-ui's .all.ae carries a marked EXTRACTOR-COMPAT comment feeding
pass 2 the same globs (`f6003d2`) — remove it when the needle lands.
Verified: `aeb: 105 build + 1 all` again on ae 0.590/aeb 3326633.

---

## RESOLVED (verified 2026-08-30)

Already fixed: `tools/extract-deps.ae:411` is `scan_needle = "scan(\""` (the
Shape-A spelling), so pass-2 scan-root expansion matches converted nodes.
`tests/test_extract_deps_scan.ae` covers `scan("**/.tests.ae")` expansion.
The aether-ui `.all.ae` EXTRACTOR-COMPAT workaround can be removed. The
deeper ask (loud warning when a scan-root extracts to 0 nodes) is NOT yet
done — left open as a separate hardening item.
