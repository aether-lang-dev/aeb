# `aeb --changed-paths-from` exits 0 on a compile failure (falsely green)

**Found:** 2026-09-21, implementing aeb#11 (--watch validate-then-swap).
**Type:** bug (exit-code propagation). Not blocking #11 — the last-good guarantee
holds regardless — but it's the falsely-green class, so worth a real fix.

## Symptom

A `.build.ae` that no longer compiles, rebuilt via the watch path:

```
aeb --changed-paths-from <file>
```

prints the aetherc error and `aborting: 1 error(s) found`, but **exits 0**:

```
error[E0100]: Expected statement in block
  --> .../target/_aeb/app__D_build_D_ae.ae:18:118
aborting: 1 error(s) found
[telemetry]
...
$ echo $?
0
```

A plain `aeb <target>` on the **same** broken node exits **1**. So it is specific
to the `--changed-paths-from` (narrowed / affected-set) path.

## Reproduce

```sh
mkdir -p repro/app && cd repro
cat > app/main.ae <<'EOF'
main() { println("v1") }
EOF
cat > app/.build.ae <<'EOF'
import bldr
import aether
import aether (source, output)
aeb(cap) { bldr.build() { aether.program() { source("main.ae") output("app") } } }
EOF
aeb app/.build.ae                 # good build, exits 0

# break it:
cat > app/.build.ae <<'EOF'
import bldr
import aether
import aether (source, output)
aeb(cap) { bldr.build() { aether.program() { source("main.ae") output("app") INVALID(( } } }
EOF
printf 'app/.build.ae\n' > c.txt
aeb --changed-paths-from c.txt ; echo "rc=$?"    # prints E0100, rc=0  (BUG)
aeb app/.build.ae               ; echo "rc=$?"    # prints E0100, rc=1  (correct)
```

## Suspected cause

The final build exec propagates its code (`tools/aeb-main.ae` ~line 1470,
`rc = bldr._sh(aeb-link …); exit(rc)`), and the compile happens INSIDE aeb-link.
So aeb-link is returning 0 despite a per-node compile error on the
`--changed-paths-from` path. Likely the affected-set narrowing rewrites the
sorted/edges set such that the broken node is scanned (its error surfaces in the
extract/edges phase, which is why the message prints) but is NOT in the narrowed
build set aeb-link actually compiles+links — so aeb-link links a set that happens
to succeed while the broken file was never (re)compiled by the build step. The
edges/extract phase should either fail the run when a scanned build file does not
parse, or the narrowing must include a changed-but-broken node so its failure
reaches `exit(rc)`.

## Impact

- Falsely-green CI class: a watch/affected rebuild reports success on a build
  file that no longer compiles. Same family as the presubmit `| tee`-ate-the-rc
  bug and the node-nonzero-return-not-propagated one.
- For --watch specifically: `aeb-watch` cannot rely on the exit code to know a
  rebuild failed. Worked around there (2026-09-21) by ALSO grepping the output
  for `error[E…]` / `aborting: N error` — see `tools/aeb-watch` run_rebuild. That
  workaround should be removed once the rc is correct.

## Fix direction

Make the extract/edges/compile phase for `--changed-paths-from` (and `--since`
/`--affected`) fail the run (non-zero) when a scanned build file does not parse,
so `exit(rc)` reflects it — matching the plain `aeb <target>` path.
