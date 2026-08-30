# aeb vs. Pulumi

Pulumi manages infrastructure resources with general-purpose
programming languages. aeb builds source-tree targets. The match is
not "aeb should become Pulumi"; the match is where aeb can produce or
check inputs that Pulumi consumes.

## Matching line items

| Pulumi concept | aeb-shaped match |
|---|---|
| Stack config | Emit config values from `.dist.ae`: image digest, package version, artifact URL |
| Stack outputs | Consume selected outputs as build/deploy inputs through generated metadata |
| Preview | Run `pulumi preview` as a check target, not as hidden build logic |
| Update | Invoke from CI after aeb produces artifacts; aeb should not own state |
| Providers | No match in aeb; provider lifecycle stays Pulumi's job |
| Secrets | Reference CI/Pulumi secrets by name; do not store secret values in `.ae` files |
| Policy as Code | Run policy checks before publish/deploy; emit pass/fail evidence |
| Multi-stack environments | Generate per-environment artifact metadata for Pulumi stacks |

## Useful grammar

```aether
pulumi.config(b) {
    stack("prod")
    set("imageDigest").from_artifact("apps/api/.dist.ae", "oci-digest")
    set("version").from_version()
    output("target/pulumi/prod.auto.json")
}

pulumi.preview(b) {
    stack("prod")
    workdir("infra/pulumi")
    config("target/pulumi/prod.auto.json")
}
```

## Boundary

aeb can generate Pulumi config and run preview checks. Pulumi should
own state, providers, refresh, update, import, drift, and rollback.
