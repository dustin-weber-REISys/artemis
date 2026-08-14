# Artemis image policy

The deployment uses the upstream operator-compatible broker and init images;
this directory intentionally contains no derived image. The Artemis chart sets
one supported `broker.version`; the pinned ArkMQ operator chart maps that
version to its broker and init images. The Argo CD bootstrap selects the two
private ECR repository locations and the Platform Release's approved tags.
Repository validation checks that the mapping renders the selected private,
tagged images.

Private-registry promotion must use unique tags in immutable ECR repositories
and retain license, SBOM, scan, signature, and provenance evidence. Build a thin
non-root derivative only if runtime acceptance proves the pinned upstream image
lacks required lock-manager or filesystem behavior; update the chart and HA
ADR as part of that reviewed change. Never add credentials or environment
identifiers here.

The Platform Release records separate tags for the broker runtime and
broker-init images. Every base-image rebuild receives a new immutable tag and
matching SBOM and vulnerability-scan evidence in the artifact system.
