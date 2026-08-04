# `aeb-link` gets the wrong `<aether-dir>` and resolves its tools relatively

**From:** the aether-ui line (2026-08-04) · **Where it bit:** FreeBSD 15
(`.204`), where it made `aeb` unable to build ANY target — the box had been
running four-day-old binaries without anyone noticing, because the matrix
silently fell back to a stale `build/` directory.

## Symptom

```
$ aeb apps/tumbling_cube
[telemetry]
  build:   apps/tumbling_cube               0.00s [n/a]
total: 0.01s wall
```

No binary, no error. The log says:

```
sh: /home/paul/aether-ui/target/_ae_build_all: not found
```

## Cause 1 — `aeb-main` passes the wrong `aether-dir` to `aeb-link`

`tools/aeb-link.ae:18` documents the contract:

> `<aether-dir>` : directory containing aetherc + libaether.a

`aeb-main` passes the install **prefix** (`$HOME/.local`) rather than the
directory containing `aetherc` (`$HOME/.local/bin`). Running `aeb-link` by
hand with the prefix reproduces it exactly:

```
sh: /home/paul/.local/aetherc: not found
aeb-link: libaether.a not found near /home/paul/.local
          — your Aether install looks incomplete
```

Passing `$HOME/.local/bin` instead, the same command builds the orchestrator
(303,400 bytes) and proceeds. Note `_resolve_libaether_dir` (~309) already
searches `${aether_dir}/../lib/aether/…`, which only makes sense if
`aether_dir` is the *bin* directory — so the resolver and the caller
disagree about the contract, and the resolver is the one matching the doc.

This is invisible on a `/usr/local` install, where `aetherc` sits directly
in the passed directory. It only bites a `PREFIX=$HOME/.local` install —
which is what every non-root box here uses.

## Cause 2 — `aeb-link` resolves its helper tools relative to `$PWD`

With the right `aether-dir`, the next failures are:

```
sh: ./tools/transform-ae: not found
sh: ./tools/gen-orchestrator: not found
```

`./tools/...` only resolves when the process happens to be running from
`$AEB_HOME`. Invoked from a repo (the normal case), it silently fails. My
workaround was `cd ~/.local/share/aeb && ./tools/aeb-link …`, which is not
something a caller should have to know. These should resolve against
`$AEB_HOME` (already passed in) or the tool's own directory.

## Cause 3 (aether, not aeb — noted for completeness)

Once linking works, the C stage dies with `sh: gcc: not found`. FreeBSD has
no gcc; the system compiler is clang. `CC=clang` is honoured by `ae build`
directly but **not** by the link step invoked through aeb, which spawns
`gcc` literally. Filed against aether as
`asks/install-sh-picks-bsd-make-on-freebsd.md`; worked around here with a
`~/.local/bin/gcc` shim exec'ing clang. With the shim, `aeb
apps/tumbling_cube` builds cleanly in 7s.

## Ask

1. Pass the directory containing `aetherc` as `<aether-dir>`, or change the
   contract in `aeb-link.ae:18` and `_resolve_libaether_dir` to accept a
   prefix — either way, make caller and callee agree.
2. Resolve `transform-ae` / `gen-orchestrator` against `$AEB_HOME` rather
   than `$PWD`.
3. Fail loudly on a missing orchestrator. `0.00s [n/a]` with no binary and
   no error is what let this box run stale binaries for four days: the
   matrix found an old `build/<app>` and reported green. A build that
   produces nothing should be an error, not a silent no-op.

## Environment

- FreeBSD 15.0-RELEASE-p10, clang 19.1.7, `gmake` present, no gcc
- ae/aetherc 0.478.0 installed to `PREFIX=$HOME/.local`
- aeb at `85e6743`, all 25 tools rebuilt with clang on this box
- Same tree builds cleanly on Linux (`aeb .all.ae` → 79 binaries) and macOS
