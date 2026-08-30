# aeb vs. Terraform, OpenTofu, and Pulumi

Terraform/OpenTofu and Pulumi manage infrastructure state. They
compare desired infrastructure with real infrastructure, produce a
plan, apply changes, and persist state for future diffs.

aeb builds source targets. It can produce deployable artifacts and
metadata, but it should not own cloud resource state.

## Where they overlap

aeb `.dist.ae` targets may produce inputs for infrastructure tools:

- OCI image references
- checksums
- package versions
- Helm values
- Terraform variable files
- deployment manifests
- SBOMs and attestations

That makes aeb a good producer for infrastructure workflows.

## Where they differ

Infrastructure tools need provider ecosystems, state locking,
drift detection, import, refresh, partial failure handling, and
resource lifecycle semantics. Those are not build-system concerns.

aeb should not implement `plan/apply` for cloud resources. It can
generate or validate inputs consumed by tools that already own that
problem.

## Rule of thumb

Use aeb to build and describe artifacts. Use Terraform/OpenTofu/Pulumi
to manage infrastructure state.

Good shape:

```text
aeb .dist.ae -> image digest + release metadata -> terraform apply
```

Bad shape:

```text
aeb becomes a cloud provider state engine
```
