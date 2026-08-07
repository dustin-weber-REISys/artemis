# ArkMQ operator wrapper

This chart pins `arkmq-org-broker-operator` `2.2.0` from the public Quay OCI
namespace and overrides its globally named label helpers. The upstream chart
does not expose a common-label value, while the target clusters require `app`,
`contact`, `env`, and `fismaid` on the operator Deployment.

The shared operator values run two controller-manager replicas. Upstream
leader election keeps one replica active and one ready to take over the
Kubernetes Lease. Hostname and zone topology-spread constraints prefer separate
nodes and availability zones but use `ScheduleAnyway`, allowing the standby to
start when maintenance, autoscaling, or untolerated node-pool taints leave only
one eligible node. The wrapper also adds a PodDisruptionBudget that preserves
at least one replica during voluntary disruptions. Add narrowly scoped upstream
`controllerManager.tolerations` only when the operator is intentionally assigned
to a tainted node pool; do not use a blanket `Exists` toleration.

The upstream Deployment builds its pod-template labels from its selector-label
helper. Consequently, the wrapper adds the enterprise labels to the Deployment
selector as well as the Deployment and pod metadata. Treat these values as
stable release identity: changing one on an existing installation requires the
operator Deployment to be replaced rather than patched in place.

Application-specific upstream values belong under the
`arkmq-org-broker-operator` key. The shared values file is
[`../../operator-values.yaml`](../../operator-values.yaml); each environment's
operator Application sets `global.requiredLabels.env` explicitly.
