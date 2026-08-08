# ArkMQ operator wrapper

This chart pins a repository-local copy of `arkmq-org-broker-operator` `2.2.0`,
originally published in the public Quay OCI namespace at digest
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

The first enterprise-labelled installation stored the Helm release labels and
the four required enterprise labels in `Deployment.spec.selector`. Because
that selector is immutable, the vendored patch intentionally reproduces that
eight-label legacy selector so Argo CD can update the existing Deployment in
place. The pod template carries the same labels. The wrapper PDB uses only the
stable `control-plane` and `name` pair because it does not share the
Deployment's immutable-selector compatibility requirement. Treat release name,
environment, `app`, `contact`, and `fismaid` as immutable for an installed
operator; changing one requires a planned Deployment replacement. Any future
required metadata labels must remain outside this explicitly enumerated legacy
selector.

Upstream values belong under the `arkmq-org-broker-operator` key in this
chart's [`values.yaml`](values.yaml). Each environment's operator Application
sets `global.requiredLabels.env` and its private ECR repositories explicitly.
