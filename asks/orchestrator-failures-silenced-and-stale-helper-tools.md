# Orchestrator compile/link failures are silenced, and lazily-built helper tools survive upgrades

**From:** the aether-ui line (2026-08-21) · **Where it bit:** macvm — every
`aeb .all.ae` fan-out failed wholesale for days while looking enough like a
build that a 90-suite spec matrix ran against stale binaries and reported
plausible numbers.

Two defects that compound; the second is why the first stayed invisible.

## 1. The orchestrator's failure is the quietest thing in the log

`tools/aeb-link.ae` compiles the fan-out orchestrator with its stderr
discarded:

```
oc_cmd = string.concat(oc_cmd, " 2>/dev/null")     // aetherc orchestrator compile
```

and the subsequent gcc link's failure, while printed, is interleaved into
the middle of a ~700-line plan echo where nothing marks it as fatal. When
the orchestrator does not appear, make then runs every node's recipe
against a binary that does not exist:

```
/bin/sh: <root>/target/_ae_build_all: No such file or directory
make: *** [examples_disclosure_demo_.build.ae] Error 127   (× 90)
```

That is the same one-root-failure-presents-as-90-broken-apps shape as the
dotted-root ask — and it took `AEB_LINK_TRACE=1` plus grepping a 700-line
log to find the real error, which was:

```
Undefined symbols for architecture x86_64:
  "__D_all_D_ae", referenced from: _main in _orchestrator-71abe7.o
```

**Ask 1:** the orchestrator compile and link are the two commands a fan-out
cannot survive losing — un-silence them, and when `out_bin` does not exist
after the link step, say so ONCE, loudly, and stop before make fans the
127s out. (Related: aeb-link has no skip logic — it recompiles every
per-file unit and the orchestrator on every invocation, so there is no
cache-staleness excuse for the silence; the compile that failed is always
this run's compile.)

## 2. Lazy-built helper tools are never invalidated

The `__D_all_D_ae` above is the PRE-b1bfa5e symbol — on a box whose aeb
repo was at cc7fec2. The mechanism: `aeb-link` lazy-builds its helpers
only on absence —

```
if file.exists(gen_orchestrator) == 0 { ... build it ... }
```

— so a compiled `gen-orchestrator` from before the encode_name fix
survives any source update that does not delete it. On macvm the
`$AEB_HOME/tools/gen-orchestrator.ae` deployed source ITSELF was also an
older shape (local inlined `encode_name`, not the aeblabel import), i.e.
the payload refresh and the repo update had drifted apart — the repo said
"fixed", the installed toolchain still emitted the broken symbol, and the
fixture-clean verification (fresh AEB_HOME → fresh helpers) passed while
the real box failed.

**Ask 2:** make helper-tool freshness part of install/upgrade — either
rebuild `transform-ae`/`gen-orchestrator` unconditionally at install time,
or key the lazy build on source mtime/hash rather than binary existence.
A toolchain whose components can be individually stale reproduces the
whole "version skew wearing a costume" family: dotted-root (aeb version
skew), rubiks_cube (aether /usr/local skew), and now this (payload vs repo
skew) are all the same bug wearing three coats.

**Resolution that worked:** `AEB_REF=v0.282 install.sh` (the fresh release
install rebuilds everything) — after which the same fan-out builds all 90
targets. So nothing here blocks aether-ui; it is about the next box that
drifts.
