# aeb vs. Ansible

Ansible configures machines by running tasks over SSH or local
connections. aeb builds source targets. The overlap is packaging,
inventory/config generation, and preflight checks before Ansible runs.

## Matching line items

| Ansible concept | aeb-shaped match |
|---|---|
| Inventory | Emit inventory from environment metadata |
| Vars | Emit vars files containing artifact versions, checksums, image digests |
| Roles | No direct match; roles remain Ansible's reuse unit |
| Playbooks | Run as explicit deploy/check targets, not hidden build steps |
| Handlers | No match in aeb; runtime convergence stays Ansible's job |
| Vault | Reference secret names/files; do not store secret values in `.ae` files |
| Check mode | Run `ansible-playbook --check` as a verification target |
| Idempotence | Ansible concern; aeb can run an idempotence check target |
| Facts | Consume selected fact output only as explicit generated metadata |

## Useful grammar

```aether
ansible.vars(b) {
    environment("prod")
    set("api_version").from_version()
    set("api_image_digest").from_artifact("apps/api/.dist.ae", "oci-digest")
    output("target/ansible/prod-vars.yml")
}

ansible.check(b) {
    inventory("infra/ansible/prod.ini")
    playbook("infra/ansible/site.yml")
    vars("target/ansible/prod-vars.yml")
    check_mode()
}
```

## Boundary

aeb can produce deployable facts and run Ansible checks. Ansible
should own host convergence, handlers, facts, SSH behavior, and
runtime configuration changes.
