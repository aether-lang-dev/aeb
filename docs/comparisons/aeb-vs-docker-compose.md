# aeb vs. Docker and Docker Compose

Docker builds and runs containers. Docker Compose describes a local
multi-container application. aeb's matching surface is image
production, image metadata, and test/development environments that use
those images.

## Matching line items

| Docker / Compose concept | aeb-shaped match |
|---|---|
| Dockerfile build | `.dist.ae` image target through the container SDK |
| Image tag | Generated from version/commit metadata |
| Image digest | Named artifact consumed by deploy/provision targets |
| Build args | DSL setters on image builders |
| Multi-stage builds | Container SDK feature, or generated Dockerfile content |
| Compose services | Generate a compose file for local integration tests/dev loops |
| Compose profiles | Map to test phases or environment names |
| Volumes | Fixture/test environment concern, not a build artifact |
| Networks | Fixture/test environment concern |
| Healthchecks | Useful for fixture readiness before tests |
| Push/pull | Publish/check targets around OCI registry operations |

## Useful grammar

```aether
container.image(b) {
    name("registry/acme/api")
    tag_from_version()
    copy_artifact("apps/api/.dist.ae", "app.jar", "/app/app.jar")
    artifact("oci-digest", "target/image.digest")
}

compose.file(b) {
    service("api") {
        image_from("apps/api/.dist.ae", "oci-image")
        healthcheck("curl -f http://localhost:8080/health")
    }
    output("target/compose/integration.yml")
}
```

## Boundary

aeb should build images and generate compose fixtures. Docker/Compose
should run containers. Long-lived orchestration belongs to Kubernetes,
Nomad, systemd, or another runtime.
