# aeb documentation

Design records, guides, forward-looking plans, and positioning comparisons for
**aeb** (the Aether build tool). Organised into four areas:

- **[design/](#design)** — how aeb works: the architecture and reference docs.
- **[guides/](#guides)** — how to do a thing: setup, bootstrap, migration.
- **[plans/](#plans)** — where aeb is going: directions, proposals, TODOs.
- **[comparisons/](#comparisons)** — aeb vs. other tools (positioning).

**New here?** Start with the core-model docs, in order:
[design/filename-is-the-route.md](design/filename-is-the-route.md) →
[design/label-is-the-addressing-contract.md](design/label-is-the-addressing-contract.md) →
[design/two-aeb-duality.md](design/two-aeb-duality.md) →
[design/nodes-as-subprocesses.md](design/nodes-as-subprocesses.md) →
[design/capability-entrypoint.md](design/capability-entrypoint.md). Then to run
it: [guides/bootstrap-from-source.md](guides/bootstrap-from-source.md).

---

## design

Architecture and reference — how aeb actually works.

**Core model** (read these first)
- [filename-is-the-route.md](design/filename-is-the-route.md) — `target/<type>/<dir>`: the build-file name IS the route; no inference layer.
- [label-is-the-addressing-contract.md](design/label-is-the-addressing-contract.md) — why routing must be label/filename-derivable.
- [two-aeb-duality.md](design/two-aeb-duality.md) — host-aeb orchestrates; the aeb-under-test is a normal target.
- [nodes-as-subprocesses.md](design/nodes-as-subprocesses.md) — each node runs as its own child process; exit code + disk markers are the verdict.
- [capability-entrypoint.md](design/capability-entrypoint.md) — `aeb(cap)` as the capability entrypoint.
- [inline-build-steps.md](design/inline-build-steps.md) — dropping into raw Aether; SDK builders for common patterns, inline escape hatch for bespoke.

**Toolchains & languages**
- [toolchain-selection-and-locks.md](design/toolchain-selection-and-locks.md) — toolchain selection + generated self-validating locks.
- [guest-languages.md](design/guest-languages.md) — running a guest language inside a build.
- [host-tinygo-sidecar.md](design/host-tinygo-sidecar.md) — the sidecar-`.so` builder shape (TinyGo).
- [gentoo-style-src-deps.md](design/gentoo-style-src-deps.md) — Gentoo-style source-dependency graphs.

**Containment, security, provisioning**
- [build-veto-and-sandbox.md](design/build-veto-and-sandbox.md) — vetting and layer-3 containment (the grant model).
- [containment-and-the-control-plane.md](design/containment-and-the-control-plane.md) — aeb's container grammar as a control-plane instance.
- [container-lifecycle.md](design/container-lifecycle.md) — container lifecycle in one inline-Aether step.
- [build-prerequisites-and-provisioning.md](design/build-prerequisites-and-provisioning.md) — `prereq()` / preflight / provisioning.
- [aeb-approval-hooks.md](design/aeb-approval-hooks.md) — approval hooks and attestations.

**Remote agents & policy**
- [agent-lifecycle.md](design/agent-lifecycle.md) — aeb-agent build lifecycle (fetch → check → build → return).
- [agent-container-ladder.md](design/agent-container-ladder.md) — agent-driven container builds, the ladder.
- [agent-provisioning-modes.md](design/agent-provisioning-modes.md) — per-slot tree provisioning modes.
- [run-policy-class-and-cloud-leverage.md](design/run-policy-class-and-cloud-leverage.md) — run policy class, cloud leverage, job fan-out.
- [webhook-triggers.md](design/webhook-triggers.md) — outbound webhook triggers.
- [presubmit-target-sets.md](design/presubmit-target-sets.md) — `.presubmit.ae` named target sets.

## guides

How to do a thing.

- [bootstrap-from-source.md](guides/bootstrap-from-source.md) — bootstrapping aeb from source.
- [aeb-host-vm-or-container-setup.md](guides/aeb-host-vm-or-container-setup.md) — setting up a host / VM / container for aeb duties.
- [aeb-agent-operating.md](guides/aeb-agent-operating.md) — operating aeb-agent (running a remote build agent).
- [maven-migration-guide.md](guides/maven-migration-guide.md) — migrating a Maven project to aeb.
- [nx-migration-guide.md](guides/nx-migration-guide.md) — migrating an Nx monorepo to aeb.
- [windows-cross-platform-notes.md](guides/windows-cross-platform-notes.md) — Windows cross-platform notes.

## plans

Forward-looking: directions, proposals, and TODOs (not necessarily implemented).

- [directions.md](plans/directions.md) — where aeb can grow, and the limits.
- [target-parameters.md](plans/target-parameters.md) — `-P name=value`, declared per-node params (design).
- [distributed-cache-plan.md](plans/distributed-cache-plan.md) — distributed cache direction & policy.
- [lifecycle-plan.md](plans/lifecycle-plan.md) — lifecycle, teardown policy, a queryable build-state machine.
- [aether-runtime-needs.md](plans/aether-runtime-needs.md) — Aether-language enhancements aeb wants.
- [aether-maven-resolver-todo.md](plans/aether-maven-resolver-todo.md) — TODO: a pure-Aether Maven coordinate resolver.
- [restabuild-directions.md](plans/restabuild-directions.md) — aeb vs. Restabuild, and "ci mode".

## comparisons

aeb positioned against other tools. Read when placing aeb in the landscape.

- [aeb-vs-bazel.md](comparisons/aeb-vs-bazel.md) — Bazel.
- [aeb-vs-gradle.md](comparisons/aeb-vs-gradle.md) — Gradle.
- [aeb-vs-starlark.md](comparisons/aeb-vs-starlark.md) — Starlark.
- [aeb-vs-nix.md](comparisons/aeb-vs-nix.md) — Nix (flakes, derivations, the store).
- [aeb-vs-moon-moonbit.md](comparisons/aeb-vs-moon-moonbit.md) — moon (MoonBit's build system).
- [aeb-vs-earthly-dagger.md](comparisons/aeb-vs-earthly-dagger.md) — Earthly and Dagger.
- [aeb-vs-jenkins.md](comparisons/aeb-vs-jenkins.md) — Jenkins (and the Jenkinsfile).
- [aeb-vs-github-actions-gitlab-buildkite.md](comparisons/aeb-vs-github-actions-gitlab-buildkite.md) — GitHub Actions, GitLab CI, Buildkite.
- [aeb-vs-snap-ci-and-the-wake-on-commit-flow.md](comparisons/aeb-vs-snap-ci-and-the-wake-on-commit-flow.md) — Snap CI and the wake-on-commit flow.
- [aeb-vs-psake-cake-task-runners.md](comparisons/aeb-vs-psake-cake-task-runners.md) — psake, Cake, FAKE, task runners.
- [aeb-vs-docker-compose.md](comparisons/aeb-vs-docker-compose.md) — Docker and Docker Compose.
- [aeb-vs-argo-flux-helm.md](comparisons/aeb-vs-argo-flux-helm.md) — Argo CD, Flux, Helm, Kustomize.
- [aeb-vs-ansible.md](comparisons/aeb-vs-ansible.md) — Ansible.
- [aeb-vs-terraform-pulumi.md](comparisons/aeb-vs-terraform-pulumi.md) — Terraform, OpenTofu, and Pulumi (the combined write-up).
  - [aeb-vs-terraform.md](comparisons/aeb-vs-terraform.md) · [aeb-vs-pulumi.md](comparisons/aeb-vs-pulumi.md) — the individual deep-dives.
- [aeb-vs-slsa-sigstore-sbom.md](comparisons/aeb-vs-slsa-sigstore-sbom.md) — SLSA, Sigstore, SBOM tooling.

---

*Examples live in [examples/](examples/). This index is grouped by doc type;
each entry links to the file and gives its one-line thesis.*
