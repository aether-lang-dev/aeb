# aeb vs. Argo CD, Flux, Helm, and Kustomize

Argo CD and Flux are GitOps controllers. They continuously compare a
cluster with Git and reconcile drift. Helm and Kustomize package or
render Kubernetes configuration.

aeb is not a cluster reconciler. It can build artifacts and generate
deployment inputs, but it should not watch clusters or own rollout
state.

## What aeb should produce

- OCI image digests, not just tags.
- Helm chart packages or values files.
- Kustomize overlays.
- Kubernetes manifests generated from `.dist.ae` metadata.
- SBOMs, provenance, and signatures.
- Release manifests tying source commit to artifact digest.

## What GitOps tools should own

- Cluster reconciliation.
- Drift detection.
- Rollback and sync history.
- Progressive rollout integration.
- Environment-specific policy.
- Long-running controllers.

## Deployment grammar boundary

aeb can declare deployable outputs:

```aether
deploy.manifest(b) {
    image("registry/acme/api")
    digest_from("apps/api/.dist.ae")
    environment("staging")
}
```

But applying that manifest should remain the job of Argo, Flux,
Helm, Kustomize, or kubectl in a CI/CD pipeline.

## Rule of thumb

aeb should produce deployable truth. GitOps tools should converge
environments to that truth.
