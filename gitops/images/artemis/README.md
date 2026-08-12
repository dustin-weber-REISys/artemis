# Artemis image policy

The deployment uses the upstream operator-compatible broker and init images;
this directory intentionally contains no derived image. The Artemis chart sets
one supported `broker.version`; the pinned ArkMQ operator chart maps that
version to its broker and init images. The Argo CD bootstrap selects the two
private ECR repository locations and the Platform Release's approved digests.
Repository validation checks that the mapping renders private digest-qualified
images.

Private-registry promotion must preserve or re-approve the verified digest and
retain license, SBOM, scan, signature, and provenance evidence. Build a thin
non-root derivative only if runtime acceptance proves the pinned upstream image
lacks required lock-manager or filesystem behavior; update the chart and HA
ADR as part of that reviewed change. Never add credentials or environment
identifiers here.

The Platform Release records `ID` and `VERSION_ID` from `/etc/os-release`
separately for the broker runtime and broker-init images. Every promotion or
base-image rebuild must refresh those fields from the exact destination digest
and retain matching SBOM and vulnerability-scan evidence. Do not infer the
container OS from the application tag or assume the two images use the same
base.
