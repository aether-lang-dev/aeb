# aeb vs. GitHub Actions, GitLab CI, and Buildkite

GitHub Actions, GitLab CI, and Buildkite are CI orchestrators. They
schedule jobs, allocate runners, expose secrets, handle approvals,
upload artifacts, and render build status.

aeb is a build graph tool. It decides what source targets exist, what
depends on what, what is affected by a change, and what artifacts each
target produces.

## What aeb should provide

- `--print-affected` and `--since` target sets.
- Deterministic sharding: `--shard 2/8`.
- Matrix metadata for OS/toolchain/package variants.
- Structured telemetry and test reports.
- Artifact manifests with names, paths, checksums, and retention hints.
- Approval check evidence for external systems of record.
- Trigger/export files for CI systems to consume.
- CI annotations in formats those systems understand.

## What CI should keep owning

- Runner fleets and queues.
- Secrets storage.
- Human approval UI.
- Cron/VCS event delivery.
- Long-term build history.
- Job cancellation and concurrency groups.
- Organization permissions.

## Export shape

aeb should emit CI-native files, not become a CI server:

```text
aeb graph -> aeb emit ci --provider github-actions
aeb graph -> aeb emit ci --provider gitlab
aeb graph -> aeb emit ci --provider buildkite
```

The CI file can be generated. The graph should still live in the
source tree.

## Rule of thumb

aeb decides what to build. CI decides where, when, and under whose
authority it runs.
