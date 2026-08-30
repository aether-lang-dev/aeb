# aeb vs. SLSA, Sigstore, and SBOM Tooling

SLSA, Sigstore, in-toto, CycloneDX, and SPDX are supply-chain
integrity tools and formats. They answer questions about where an
artifact came from, what it contains, who signed it, and whether it
matches policy.

aeb is well placed to feed those systems because it already knows the
source target, dependency graph, command intent, outputs, and test
status.

## What aeb should emit

- SBOMs in CycloneDX or SPDX format.
- Provenance statements for `.dist.ae` outputs.
- Checksums for every named artifact.
- Signing hooks for jars, packages, binaries, and OCI images.
- Verification hooks before publish or deploy.
- Policy-check results in SARIF or JSON.

## What aeb should not own

- A certificate authority.
- A transparency log.
- A vulnerability database.
- Organization-wide policy storage.

Those belong to Sigstore, Rekor, dependency scanners, or policy
systems. aeb should produce accurate build facts and invoke/verify
external tools.

## Suggested grammar

```aether
supply.provenance(b) {
    subject("apps/api/.dist.ae")
    format("slsa")
}

supply.sbom(b) {
    subject("apps/api/.dist.ae")
    format("cyclonedx-json")
}

supply.sign(b) {
    subject("apps/api/.dist.ae")
    keyless()
}
```

Approval attestation lives in
[aeb-approval-hooks.md](/home/paul/scm/aetherBuild/docs/design/aeb-approval-hooks.md).

## Rule of thumb

aeb should make artifacts explainable and verifiable. It should not
become the whole supply-chain security platform.
