# Environment composition

The ZooKeeper chart itself enforces the shared three-member quorum, persistent
volumes, disruption budget, zone and host scheduling, network policy, and
metrics defaults. The `test`, `nonprod`, and `prod` overlays contain stage-wide
infrastructure references, resource defaults, observability integration, and
the explicit image digest used for independent promotion. Pair-specific
Artemis identity and capacity live in [`argocd/topology`](../argocd/topology).

Local Docker Compose is the developer sandbox. There is no Kubernetes
ZooKeeper sandbox overlay or disabled-chart composition.

Before use, replace the `PLACEHOLDER_*` values through the environment or Argo
CD deployment configuration. Do not commit credentials, account IDs, real
cluster names, domains, or secret contents.
