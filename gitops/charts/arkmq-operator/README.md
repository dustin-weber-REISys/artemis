# ArkMQ operator wrapper

This chart pins a repository-local enterprise patch of
`arkmq-org-broker-operator` as chart version `2.2.0-enterprise.4`, based on
upstream application version `2.2.0` originally published in the public Quay
OCI namespace at digest
`sha256:bf75b448cc62374cfca3f9ad7b405d76584e09e13034446b30b19c3ad36ad285`.
The target clusters require `app`, `contact`, `env`, and `fismaid` on the
operator Deployment and pod template, but the upstream chart does not expose a
common-label or pod-label value.

The wrapper defaults run two controller-manager replicas. Upstream
leader election keeps one replica active and one ready to take over the
Kubernetes Lease. Hostname and zone topology-spread constraints prefer separate
nodes and availability zones but use `ScheduleAnyway`, allowing the standby to
start when maintenance, autoscaling, or untolerated node-pool taints leave only
one eligible node. The shared values also tolerate exactly
`eid-platform/node-lifecycle=ondemand:NoSchedule`, matching the platform worker
pool used by the broker workloads. This is required for reconciliation: a
synced `ActiveMQArtemis` CR cannot produce a StatefulSet while every operator
replica is pending on that taint. The toleration does not select a node pool;
add a node selector separately if placement must be exclusive. The wrapper
also adds a PodDisruptionBudget that preserves at least one replica during
voluntary disruptions. Do not replace the exact toleration with a blanket
`Exists` toleration.

Earlier revisions rendered two-, four-, and eight-label selectors for the same
`activemq-artemis-controller-manager` Deployment. Kubernetes selectors are
immutable, so no single in-place selector can repair every installation. This
revision performs a one-time declarative replacement named
`activemq-artemis-controller-manager-v2`. Argo CD creates the replacement and,
because every operator Application enables automated pruning with
`PruneLast=true`, removes the obsolete Deployment only after the replacement is
healthy. The ServiceAccount, RBAC, and leader-election identity do not change,
so the replacement resumes reconciliation without a manual cluster delete.

The replacement Deployment and its PDB select only the stable `control-plane`
and `name` pair. Helm release and enterprise labels remain on Deployment and
pod metadata for ownership and admission policy, but are deliberately excluded
from `spec.selector`. Future metadata-label changes must remain outside that
selector.

The distinct vendored chart version is intentional. Each change to vendored
templates must increment the `enterprise.N` dependency version; otherwise Helm
or Argo CD dependency caches can serve a package with an older Deployment
identity or selector.

Upstream values belong under the `arkmq-org-broker-operator` key in this
chart's [`values.yaml`](values.yaml). Each environment's operator Application
sets `global.requiredLabels.env` and its private ECR repositories explicitly.
It also overrides the manager image to the mirrored `2.2.0` ECR tag. The
wrapper default records the upstream digest, but an upstream registry digest
must not be combined with a private repository unless the promotion record
confirms that the private registry preserved that exact manifest digest.
The Applications therefore select the immutable ECR `artemis.2.53.0` tags for
both related images used by the approved broker version. When the approved
broker version changes, its two related-image mappings must be updated together.
