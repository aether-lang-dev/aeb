# Outbound webhook triggers

aeb can invoke a URL when a pipeline (or a single target) finishes —
so a build/test/deploy run can hand off to whatever comes next: a
deploy system, an n8n / Zapier flow, a GitHub `repository_dispatch`,
another pipeline. aeb is the *producer* side of a webhook-centric
automation system; it pings a listener and does not care what the
listener does. Direction is outbound only — aeb never serves or
listens.

The capability is core and language-agnostic: it works the same
whether the pipeline builds Java, Rust, or nothing at all.

## The `webhook.fire` builder

A webhook is one builder, `webhook.fire(b) { ... }`, called inside a
`.ae` file's `main()` like any other builder. There is no special
filename — the webhook fires because a file calls `webhook.fire`,
never because of what the file is named.

```aether
import build
import webhook
import webhook (url, on, header)

main() {
    b = build.start()
    webhook.fire(b) {
        url("https://hooks.example/deploy?sha={{commit}}&br={{branch}}")
        header("Authorization", "Bearer {{env:DEPLOY_TOKEN}}")
        on("ci")
        on("branch:main")
    }
}
```

Note the two `import webhook` lines: the first brings the
`webhook.fire` builder verb, the second (`import webhook (url, on,
header)`) brings the bare setter names used inside the block. This
two-import rule applies to every aeb SDK.

### Two placements

**In-target** — put the `webhook.fire(b)` block inside an existing
`.build.ae` / `.tests.ae` / `.dist.ae`, next to that target's own
builders. It fires when that target finishes:

```aether
// app/.dist.ae
main() {
    b = build.start()
    brew.formula(b) { ... }
    webhook.fire(b) {
        url("https://hooks.example/packaged?sha={{commit}}")
        on("ci")
    }
}
```

**Dedicated file** — a `.ae` file whose `main()` only declares
dependencies and a webhook. Because it `build.dep()`s on the targets
it should follow, the topo-sort places it last — an end-of-pipeline
ping. Name the file whatever you like:

```aether
// deploy/.notify.ae
main() {
    b = build.start()
    build.dep(b, "app/.tests.ae")
    build.dep(b, "app/.dist.ae")
    webhook.fire(b) {
        url("https://hooks.example/pipeline-done?repo={{repo}}")
    }
}
```

A dedicated webhook file is a normal DAG node. Like any aeb target,
if it shares a directory with another build file the usual `:tag`
disambiguation applies — so the simplest thing is to give it its own
directory.

## Setters

| Setter | Purpose |
|--------|---------|
| `url(STR)` | Target URL. Required. Supports `{{...}}` interpolation. |
| `on(STR)` | A gate predicate; repeatable. Every `on(...)` must pass for the webhook to fire (AND). Optional — no `on()` means always fire. |
| `method(STR)` | `"POST"` (default) or `"GET"`. POST sends an empty body — a bare ping; the signal rides in the URL. |
| `header(KEY, VAL)` | A request header; repeatable. `VAL` supports `{{...}}` interpolation — this is the auth path (`Bearer {{env:TOKEN}}`). |

## `on()` gate predicates

The gate is evaluated when the webhook is about to fire. If any
predicate fails the HTTP call is skipped and a `webhook skipped`
line is printed. A leading `!` negates any predicate.

| Predicate | Fires when |
|-----------|------------|
| `on("ci")` | running under any CI |
| `on("local")` | not under CI |
| `on("branch:main")` | current branch equals `main` |
| `on("branch:rel-*")` | current branch glob-matches `rel-*` |
| `on("!branch:wip-*")` | current branch does not match `wip-*` |
| `on("github")` | detected CI system is GitHub Actions |
| `on("!jenkins")` | detected CI system is not Jenkins |

There is no `on("success")` / `on("failure")`. aeb aborts the run on
the first failed target, so a webhook node — in-target or dedicated
— is only ever *reached* when everything before it succeeded. The
webhook is structurally always on a success path.

## `{{...}}` context interpolation

`url()` and `header()` values substitute `{{name}}` tokens from
aeb's runtime context. Values interpolated into a URL are
URL-encoded; values interpolated into a header are inserted verbatim.

| Token | Value |
|-------|-------|
| `{{branch}}` | current VCS branch |
| `{{commit}}` / `{{commit_short}}` | current commit hash (full / 7-char) |
| `{{repo}}` | repository root directory name |
| `{{ci}}` | detected CI system, or `local` |
| `{{target}}` | the target the webhook is attached to |
| `{{env:NAME}}` | the environment variable `NAME` |

The token syntax is `{{...}}`, not `${...}`: Aether's own string
interpolation consumes `${...}` at parse time, so a literal
`url("...${branch}")` would never reach the webhook SDK. `{{...}}`
passes through untouched and is substituted by aeb at fire time.

## CI detection

`on("ci")` / `on("github")` / `{{ci}}` rely on CI-system detection.
aeb probes the well-known environment variables — `GITHUB_ACTIONS`,
`GITLAB_CI`, `JENKINS_URL`, `CIRCLECI`, `TRAVIS`, `BUILDKITE`, and
the generic `CI` — and reports the specific system, generic `ci`, or
`local` when none match.

## Failure behaviour

The HTTP call uses a native client with a timeout. A webhook
listener that is down or unreachable logs a warning — it does **not**
fail the build. A down notification endpoint should never redden an
otherwise-green build.

## Design notes

The full design rationale, the decisions taken, and what is
deliberately out of v1 (JSON payload bodies, retries, inbound
webhooks) are in `asks/webhook-outbound-trigger.md`.
