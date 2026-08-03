# Environment composition

The ZooKeeper chart itself enforces the shared three-member quorum, persistent
volumes, disruption budget, zone and host scheduling, network policy, and
metrics defaults. The `test`, `nonprod`, and `prod` overlays contain stage-wide
infrastructure references, resource defaults, observability integration, and
the explicit image digest used for independent promotion. Pair-specific
Artemis identity and capacity live in [`argocd/topology`](../argocd/topology).

The test and nonprod Artemis overlays reuse the existing legacy Hawtio client
and realm in preprod Keycloak. The prod overlay reuses the existing legacy
Hawtio client and realm in production Keycloak for every production workload
namespace. ApplicationSets continue to derive each client's exact redirect URI
from its topology `managementHost`; every rendered URI must already be allowed
by the reused client. These overlays do not provision or modify Keycloak.

Local Docker Compose is the developer sandbox. There is no Kubernetes
ZooKeeper sandbox overlay or disabled-chart composition.

Before use, replace the `PLACEHOLDER_*` values through the environment or Argo
CD deployment configuration. Do not commit credentials, account IDs, real
cluster names, domains, or secret contents. If the legacy Keycloak issuer is
external to the cluster, also supply its approved TCP/443 CIDR through
`networkPolicy.extraEgress`; the `keycloak.namespace` and `podSelector` values
only authorize direct access to an in-cluster Keycloak pod.
