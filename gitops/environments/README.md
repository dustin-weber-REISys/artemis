# Environment composition

The ZooKeeper Kustomize base enforces the shared three-member quorum,
persistent volumes, disruption budget, zone and host scheduling, network
policy, and metrics defaults. Its `test`, `nonprod`, and `prod` overlays under
[`kustomize/zookeeper`](../kustomize/zookeeper) own ZooKeeper sizing and
cluster integration references. This directory now contains only Artemis
chart values. Workload Cell identity and sizing live in
[`argocd/topology`](../argocd/topology), while pair-owned messaging policy lives
under [`workloads`](../workloads). Environment-wide listener, destination, and
authorization map entries may be placed here when they genuinely apply to
every cell; later Workload Cell maps deep-merge pair-specific additions.

Image locations and release pins do not belong in environment overlays.
The Argo CD bootstraps use one nonprod and one prod ECR base placeholder; test
and nonprod share the nonprod location. Repository-owned deployment bases and
the pinned ArkMQ operator release define the version-to-image mapping. The
[operator](../kustomize/arkmq-operator) and
[ZooKeeper](../kustomize/zookeeper) Kustomize overlays pin their final private
image references. Each cluster promotes those pins by selecting an approved
revision.

The test and nonprod Artemis overlays reuse the existing legacy Hawtio client
and realm in preprod Keycloak. The prod overlay reuses the existing legacy
Hawtio client and realm in production Keycloak for every production workload
namespace. ApplicationSets continue to derive each client's exact redirect URI
from its catalog `managementHost`; every rendered URI must already be allowed
by the reused client. These overlays do not provision or modify Keycloak.

Local Docker Compose is the developer sandbox. There is no Kubernetes
ZooKeeper sandbox overlay or disabled-chart composition.

Before use, replace the `PLACEHOLDER_*` values through the environment or Argo
CD deployment configuration. Do not commit credentials, account IDs, real
cluster names, domains, or secret contents. If the legacy Keycloak issuer is
external to the cluster, also supply its approved TCP/443 CIDR through
`networkPolicy.extraEgress`; the `keycloak.namespace` and `podSelector` values
only authorize direct access to an in-cluster Keycloak pod.
