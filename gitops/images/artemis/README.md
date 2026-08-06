# Artemis image policy

The deployment uses the upstream operator-compatible broker and init images;
this directory intentionally contains no derived image. The Artemis chart sets
one supported `broker.version`; the pinned ArkMQ operator chart maps that
version to its immutable broker and init digests. The Argo CD bootstrap only
overrides the two private ECR repository locations. Repository validation
checks that the mapping renders private digest-qualified images.

Private-registry promotion must preserve or re-approve the verified digest and
retain license, SBOM, scan, signature, and provenance evidence. Build a thin
non-root derivative only if runtime acceptance proves the pinned upstream image
lacks required lock-manager or filesystem behavior; update the chart and HA
ADR as part of that reviewed change. Never add credentials or environment
identifiers here.
