# ArkMQ operator wrapper

This chart pins `arkmq-org-broker-operator` `2.2.0` from the public Quay OCI
namespace and overrides its globally named label helpers. The upstream chart
does not expose a common-label value, while the target clusters require `app`,
`contact`, `env`, and `fismaid` on the operator Deployment.

The shared operator values run two controller-manager replicas. Upstream
leader election keeps one replica active and one ready to take over the
Kubernetes Lease. Required hostname and zone topology-spread constraints keep
the replicas out of the same node and availability zone, and the wrapper adds
a PodDisruptionBudget that preserves at least one replica during voluntary
disruptions.

The upstream Deployment builds its pod-template labels from its selector-label
helper. Consequently, the wrapper adds the enterprise labels to the Deployment
selector as well as the Deployment and pod metadata. Treat these values as
stable release identity: changing one on an existing installation requires the
operator Deployment to be replaced rather than patched in place.

Application-specific upstream values belong under the
`arkmq-org-broker-operator` key. The shared values file is
[`../../operator-values.yaml`](../../operator-values.yaml); each environment's
operator Application sets `global.requiredLabels.env` explicitly.
