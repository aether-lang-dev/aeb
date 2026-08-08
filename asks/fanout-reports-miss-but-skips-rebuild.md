# `.all.ae` fan-out reports `[miss]` in 0.03s and leaves a stale binary

**From:** the aether-ui line (2026-08-08) · **Where it bit:** the Linux box,
`aeb .all.ae` over ~79 targets — 8 apps kept binaries three days older than a
header they depend on, and the four-platform spec matrix then measured them.

## Symptom

`ui/module.ae` was committed at 14:59. `aeb .all.ae` ran at **16:02**, an hour
later, and reported:

```
  build:   apps/sketchpad                   0.03s [miss]
  build:   apps/falling_blocks              0.01s [miss]
  build:   apps/rubiks_cube                 0.01s [miss]
  build:   apps/tumbling_cube               0.02s [miss]
```

No errors, exit 0. But the binaries did not move — a spec run immediately
afterwards flagged eight of them:

```
  WARN sketchpad: binary older than sources — measuring a STALE build.
       ui/module.ae
       ui/frames.ae
```

Those apps import `ui`, so `ui/module.ae` is a real dependency, and it had
changed before the build started.

## It is not "aeb never rebuilds on dependency change"

That was my first reading and it is **wrong** — worth stating so nobody
chases it. Both of these work correctly:

- **Single target.** `touch ui/module.ae && aeb apps/tumbling_cube/.build.ae`
  → `6.71s [miss]`, fresh binary. Dependency tracking is fine here.
- **The same fan-out, re-run.** `touch ui/module.ae && aeb .all.ae` →
  `apps/sketchpad 16.25s [miss]`, `apps/font_picker 23.21s [miss]`, all
  binaries newer than the source afterwards.

The 16:02 run was also doing real work overall — 79 targets, individual
builds up to 39.04s, 102.91s wall. Only 19 came back sub-0.1s. So the
fan-out is not globally broken; a **subset** of targets was wrongly judged
up to date in one run and correctly rebuilt in another, from the same tree.

That intermittency is the actual report. Same command, same sources, same
box, ~25 minutes apart, opposite outcomes.

## Why it is worse than a plain miss

`[miss]` reads as "cache miss — building". A human scanning 79 lines of
telemetry sees `[miss]` and concludes work happened. If a skipped target
reported `[skip]`, `[stale]`, or anything distinguishable, this would have
been caught in the log rather than an hour later by an unrelated
spec-harness warning.

Suggestion, in preference order:

1. Fix the dependency comparison so it does not intermittently judge a
   changed transitive dependency as up to date under fan-out.
2. Failing that, make the marker honest: `[miss]` should mean the target was
   rebuilt. A sub-0.1s `[miss]` on a target that normally takes 16s is a
   contradiction the telemetry should not be able to express.

## Impact

The spec matrix runs whatever binary it finds and does not rebuild, so a
stale artifact is measured as if current. On this line it produced
double-digit phantom failures on three of four platforms in one afternoon —
including 11 "failures" in `frames` that looked exactly like a win32
geometry regression (frames at half size) and were entirely a four-day-old
binary. aether-ui now warns when a suite's binary predates its sources
(`tests/spec_matrix.sh`), which is how this was found at all, but that is a
downstream mitigation, not a fix.

## Repro sketch

```sh
cd aether-ui
touch ui/module.ae          # a dependency of many apps
aeb .all.ae                 # inspect: any sub-0.1s [miss]?
# then, for any target that reported one:
stat -c '%y %n' ui/module.ae target/build/apps/<app>/bin/<app>
# binary older than the source => it was skipped while reporting [miss]
```

Note it did **not** reproduce on the immediate re-run, so this likely needs
either the full ~79-target fan-out or some ordering/parallelism condition to
show up. Timings and log excerpts above are from the run that did.

## Related

- `asks/aeb-multi-target-and-failure-exit-code-bugs.md` — other fan-out
  behaviour where per-target outcomes are not faithfully reported.
- `asks/windows-absolute-paths-joined-to-source-dir.md` and
  `asks/aeb-link-wrong-aether-dir-and-relative-tools.md` — the two earlier
  asks from this same aether-ui line.
