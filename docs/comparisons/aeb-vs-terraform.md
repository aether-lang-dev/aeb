# aeb vs. Terraform / OpenTofu

Terraform and OpenTofu manage infrastructure state through providers,
plans, applies, and state files. aeb builds source-tree targets. The
useful overlap is narrow: aeb can produce inputs for Terraform and
check Terraform plans.

## Matching line items

| Terraform/OpenTofu concept | aeb-shaped match |
|---|---|
| Variables | Emit `.tfvars.json` from build outputs and metadata |
| Outputs | Read selected outputs into generated metadata for later targets |
| Plan | `terraform plan` as a check target with saved plan artifact |
| Apply | CI invokes apply after approval; aeb should not own it |
| Providers | No match in aeb; provider install/lifecycle remains Terraform's job |
| State backend | No match in aeb; state locking and storage remain Terraform's job |
| Workspaces | Map environment names to emitted variable files |
| Modules | aeb can package/render module inputs, but not replace module semantics |
| Policy checks | Run `terraform validate`, `tflint`, `conftest`, or plan policy checks |

## Useful grammar

```aether
terraform.vars(b) {
    environment("prod")
    set("image_digest").from_artifact("apps/api/.dist.ae", "oci-digest")
    set("release_version").from_version()
    output("target/terraform/prod.tfvars.json")
}

terraform.plan(b) {
    workdir("infra/terraform")
    vars("target/terraform/prod.tfvars.json")
    output_plan("target/terraform/prod.plan")
}
```

## Boundary

aeb can build artifacts, emit variables, and run validation/plan
checks. Terraform/OpenTofu should own state, provider operations,
resource drift, and `apply`.
