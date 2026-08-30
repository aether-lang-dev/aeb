# aeb vs. psake, Cake, FAKE, and Task Runners

psake, Cake, FAKE, Invoke-Build, Rake, Make, and similar tools are
task runners. They let teams script build steps in a familiar host
language: PowerShell, C#, F#, Ruby, shell, or another general-purpose
runtime.

aeb is a source-tree build graph. A target is a dot-prefixed `.ae`
file, dependencies are graph edges, and language SDKs provide typed
build verbs.

The useful comparison is not "which scripting language is nicer." The
useful comparison is which task-runner features should become typed
aeb builders or hooks.

## Matching line items

| Task-runner feature | aeb-shaped match |
|---|---|
| Named tasks | Dot-prefixed `.ae` targets |
| Task dependencies | `build.dep(...)` graph edges |
| Setup/teardown | Builder lifecycle hooks |
| Failure hooks | `on_failure { ... }` style hooks |
| Criteria/conditions | Minimal `criteria()` or env predicate setters |
| Build versioning | Git-derived version builder shared across SDKs |
| Package/publish | `.dist.ae` publish builders for Maven/npm/NuGet/PyPI/OCI |
| Code signing | Signing builders attached to package outputs |
| CI detection | Small `build.is_ci()`, `build.branch()`, `build.is_pr()` helpers |
| Test reports | Structured JUnit/TRX/JSON/SARIF artifacts |
| Tool bootstrapping | Toolchain validation or pinned tool resolution |
| Arbitrary scripts | Explicit escape hatch, not the primary build API |

## What aeb should learn

Cake and FAKE are strong at release glue: version calculation,
packaging, signing, publishing, release notes, and CI-specific output.
Those are real gaps for aeb's `.dist.ae` layer.

psake and Invoke-Build are strong at simple operational tasks in
Windows-heavy environments. They make setup/teardown, conditions, and
PowerShell integration cheap. aeb should cover the same workflows with
typed hooks where possible and command hooks where necessary.

## What aeb should avoid

Task runners tend to become imperative scripts:

```text
clean -> restore -> build -> test -> pack -> publish
```

That shape is convenient, but it hides the module graph. aeb should
not replace its graph with a root script that manually orders the
world.

The aeb version should stay target-local. Today, that looks like:

```aether
java.junit5(b) {
    test_timeout("120")
}

bash.test(b) {
    script("integration_test.sh")
    on_failure("scripts/capture-test-diagnostics.sh")
}
```

`on_failure(...)` takes a single shell command (string), not a block — it fires once if any `script(...)` exits non-zero.

The shape we'd want for release flow is the same idea, applied to a `.dist.ae` target. Publish/sign/version-from-git verbs are not yet shipping (`shade()` builds fat jars; the dist-side publish step is roadmap), but the intended shape is target-local:

```aether
// sketch — verbs not implemented yet
nuget.publish(b) {
    package("libs/core/.dist.ae")
    version_from_git()
    sign()
    feed("internal")
}
```

## Boundary

Good:

- Typed builders for common lifecycle, versioning, signing, publish,
  and reporting flows.
- Small command hooks for project-specific glue.
- CI output adapters and structured artifacts.
- Conditions that stay simple and inspectable.

Bad:

- A general imperative pipeline language.
- Hidden dependency edges inside helper scripts.
- Repo-specific frameworks that must be evaluated to understand one
  target.
- Making shell/PowerShell snippets the normal build API.

## Rule of thumb

Import the mature release-engineering features from psake, Cake, FAKE,
and similar tools. Do not import their script-first structure as aeb's
core model.

aeb's graph should decide what exists and what depends on what. Hooks
and task-runner-style builders should decorate that graph, not replace
it.
