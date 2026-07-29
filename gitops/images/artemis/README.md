# Artemis image policy

The deployment uses the upstream operator-compatible broker and init images;
this directory intentionally contains no derived image. Current tags and
digests are authoritative in
[`charts/artemis-ha/values.yaml`](../../charts/artemis-ha/values.yaml), with
supported operands constrained by
[`values.schema.json`](../../charts/artemis-ha/values.schema.json).

Private-registry promotion must preserve or re-approve the verified digest and
retain license, SBOM, scan, signature, and provenance evidence. Build a thin
non-root derivative only if runtime acceptance proves the pinned upstream image
lacks required lock-manager or filesystem behavior; update the chart and HA
ADR as part of that reviewed change. Never add credentials or environment
identifiers here.
