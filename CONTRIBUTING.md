# Contributing to aeb

Thanks for wanting to improve aeb. This is the short, human-facing
guide. The deep material — how to author a language SDK, the design
principles for what belongs in core, the recurring footguns — lives in
[`LLM.md`](LLM.md), which is written for an assistant picking up
mid-task but reads fine for people too. Read it before adding or
changing an SDK.

## Versioning

aeb does **not** follow semantic versioning yet. There's no stable
public-API promise; the surface is still moving. Don't worry about
version bumps in a contribution — just describe the change in
[`CHANGELOG.md`](CHANGELOG.md) under `## Unreleased`.

Versions are `v0.NNN` (sequential: `v0.001`, `v0.002`, …). These are
**pinnable markers, not sem-ver compatibility promises** — a higher
number just means "later," nothing about API stability. GitHub serves a
source tarball per tag (`…/archive/refs/tags/v0.NNN.tar.gz`), so a
downstream repo can pin its aeb to an exact, human-ordered ref
(`AEB_REF=v0.042`) instead of an anonymous commit SHA.

**Tagging is deliberate, and a maintainer does it.** Pushing to `main`
runs CI and nothing else — it does not create a version. Pushing a `v*`
tag is what cuts a release:

```bash
git tag v0.281 && git push origin v0.281     # -> release.yml publishes
```

(Until 2026-08-01 every push to `main` was auto-tagged and auto-released,
which produced a release per commit — seven in two working days — and
conflated "a commit happened" with "a version exists". Contributions
still need no version bump: just describe the change under
`## Unreleased`.)

## Who can push, and how

- **Paul and Nic** commit and push directly to `main`.
- **Everyone else**: please open a pull request. Keep it focused —
  one logical change per PR; we squash.

## Donating LLM-written code

A lot of aeb's code is written with an LLM in the loop, and that's
welcome. If your contribution was produced by an LLM, please do one
extra thing: **ask your LLM to reverse-engineer a single prompt that
could one-shot the same contribution**, and paste that prompt into the
PR description.

Why: it's the most useful artifact you can hand us. It states the
intent and constraints in one place, lets us (or our own assistants)
re-derive or extend the work, and doubles as a regression spec —
"running this prompt against the current tree should reproduce
something equivalent." A good prompt is worth more than a long diff
explanation.

## Tests

We like tests at **all** sizes — small, medium, and larger — and want
all three:

- **Small** — pure command-string builders. Every command that gets
  `os.system`'d should be assembled by a pure `*_cmd(...)` helper, and
  exercised by a `tests/test_*_cmd.ae` that asserts the exact string.
  This is the load-bearing regression surface; new SDK work should grow
  it. Run with `./tests/run.sh` (a pattern arg filters:
  `./tests/run.sh test_ruby_cmd`).
- **Medium** — builder/grammar behaviour: setter accumulation,
  staleness/skip logic, artifact wiring. Also under `tests/`.
- **Larger** — end-to-end smokes and the real-world conversions under
  `itests/`.

**You do NOT need to run all of `itests/` before donating.** The
itests fetch large upstream repos (`itests/fetch-upstream.sh`), need
many language toolchains installed, and are deliberately
partially-passing scaffolding — not a green-gate. `./tests/run.sh`
(fast, offline, no toolchains beyond `ae`) is the bar that matters for
a contribution; run the one or two itests relevant to your change if
you can, and say so in the PR. Don't treat "all itests green" as a
prerequisite — it isn't one even for us.

## Before you open the PR

- `./tests/run.sh` is green.
- If you touched the user-visible surface, the README and/or relevant
  `docs/` page is updated.
- A `## Unreleased` entry in `CHANGELOG.md`.
- Commit messages capture the **trade-off** ("going with X, not Y,
  because Z"), not just the diff — past commit bodies are aeb's design
  archive.
- If your change was LLM-assisted, the reverse-engineered one-shot
  prompt is in the PR description (see above).

## Where things live

- `lib/<lang>/module.ae` — language SDKs. `lib/bash/module.ae` is the
  simplest complete example to copy from.
- `tools/` — the runtime (trampoline, scan, extract-deps, topo-sort,
  link, orchestrator).
- `tests/` — the canonical, offline test surface.
- `itests/` — real-world conversions (optional, partially-passing).
- `docs/` — design notes, comparisons, and worked examples.
- `LLM.md` — SDK-authoring patterns, design principles, footguns.
- `TODO.md` — roadmap and known gaps.
