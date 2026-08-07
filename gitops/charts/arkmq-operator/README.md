# ArkMQ operator wrapper

This chart pins a repository-local copy of `arkmq-org-broker-operator` `2.2.0`,
originally published in the public Quay OCI namespace at digest
`sha256:bf75b448cc62374cfca3f9ad7b405d76584e09e13034446b30b19c3ad36ad285`.
The target clusters require `app`, `contact`, `env`, and `fismaid` on the
operator Deployment and pod template, but the upstream chart does not expose a
common-label or pod-label value.

The shared operator values run two controller-manager replicas. Upstream
leader election keeps one replica active and one ready to take over the
Kubernetes Lease. Hostname and zone topology-spread constraints prefer separate
nodes and availability zones but use `ScheduleAnyway`, allowing the standby to
start when maintenance, autoscaling, or untolerated node-pool taints leave only
one eligible node. The wrapper also adds a PodDisruptionBudget that preserves
at least one replica during voluntary disruptions. Add narrowly scoped upstream
`controllerManager.tolerations` only when the operator is intentionally assigned
to a tainted node pool; do not use a blanket `Exists` toleration.

The vendored patch adds the enterprise labels to resource metadata and the
operator pod template while leaving `Deployment.spec.selector` and the PDB
selector limited to the upstream release identity. This separation is
intentional: selectors are immutable, so putting ownership or environment
labels there prevents Argo CD from patching an existing Deployment when the
labels are introduced or corrected.

Application-specific upstream values belong under the
`arkmq-org-broker-operator` key. The shared values file is
[`../../operator-values.yaml`](../../operator-values.yaml); each environment's
operator Application sets `global.requiredLabels.env` explicitly.
