# ArkMQ operator Helm chart with Kustomize

Research date: 2026-08-11  
Question: Can Artemis use an ArkMQ controller/operator base Helm chart and
apply Kustomize on top, and would that simplify maintenance and upgrades?

## Short answer

Yes, for this repository's community Apache ActiveMQ Artemis platform. ArkMQ
publishes the `arkmq-org-broker-operator` chart as an OCI artifact at
`oci://quay.io/arkmq-org/helm-charts/arkmq-org-broker-operator`, and keeps the
chart source in the operator repository. The chart installs the operator
controller and its CRDs; broker instances remain `ActiveMQArtemis` custom
resources. ArkMQ documents both the OCI install command and version pinning.
([ArkMQ quick start](https://arkmq.org/docs/getting-started/quick-start/#install-the-operator-from-helm-charts),
[upstream chart source](https://github.com/arkmq-org/arkmq-org-broker-operator/tree/main/helm-charts/arkmq-org-broker-operator))

This is an ArkMQ community chart, not a documented Red Hat-supported AMQ Broker
Helm distribution. Red Hat AMQ Broker 7.13 documents two supported installation
paths for its Operator: Red Hat's downloaded CLI installation archive and
OperatorHub/OLM. It does not document the ArkMQ OCI chart as a Red Hat AMQ
installation method. If Red Hat product support is a requirement, the
installation mechanism and image/operator combination should follow the Red
Hat subscription guidance or be confirmed with Red Hat support.
([Red Hat AMQ Broker 7.13 deployment guide](https://docs.redhat.com/en/documentation/red_hat_amq_broker/7.13/html-single/deploying_amq_broker_on_openshift/))

## Repository finding

The proposed design is already present:

- [`kustomize/arkmq-operator/base/kustomization.yaml`](../../kustomize/arkmq-operator/base/kustomization.yaml)
  declares the upstream OCI chart, pins version `2.2.0`, supplies a common
  values file, and includes the CRDs.
- [`kustomize/arkmq-operator/base/values.yaml`](../../kustomize/arkmq-operator/base/values.yaml)
  contains chart-native configuration such as scope, leader election,
  scheduling, and related-image repositories.
- The environment overlays apply only environment identity and approved private
  image mappings.
- [`releases/current.yaml`](../../releases/current.yaml) records the chart
  version, OCI digest, downloaded artifact checksum, operator image digest,
  container OS identities, and the operator/operand versions.
- [`scripts/prepare-upgrade.sh`](../../scripts/prepare-upgrade.sh) stages an
  operator version change and validates it before writing, while
  [`kustomize/arkmq-operator/tests/test.sh`](../../kustomize/arkmq-operator/tests/test.sh)
  checks the rendered object identities, RBAC, images, placement, labels, CRDs,
  and environment-specific output.

Kustomize explicitly supports this composition: `helmCharts` runs `helm pull`
and `helm template` to generate YAML as a base, after which transformers and
overlays modify that YAML. This is render-time Helm inflation, not a
cluster-side Helm release.
([Kustomize Helm chart example](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/chart.md))

## Maintenance and upgrade assessment

This pattern should be easier to maintain than copying the operator manifests
or forking the upstream chart:

- Upstream owns the controller Deployment, service account, RBAC, and CRD
  templates; the repository owns only explicit policy and environment deltas.
- A chart upgrade becomes a small version/provenance change followed by a full
  render diff. This makes upstream additions and removals visible without
  manually rebasing a copied manifest tree.
- Common behavior stays in one base while overlays remain small, which reduces
  environment drift.
- Pinning the chart and validating rendered resources makes upgrades deliberate
  and repeatable.

It does not make upgrades automatic or risk-free:

- Kustomize calls `helm template`; it does not create Helm release state,
  revision history, or use `helm upgrade`/`helm rollback`. Argo CD remains the
  lifecycle owner.
- A new chart can rename generated objects, selectors, values, RBAC, or CRDs and
  thereby invalidate Kustomize patches. Every version bump still needs rendered
  diffs, schema checks, CRD review, and operator/operand compatibility testing.
- Chart values should be preferred where the chart exposes the required knob;
  patches should be reserved for policy that the chart cannot express. Fewer
  object-identity patches mean less upgrade friction.
- Helm inflation must be explicitly enabled. Argo CD documents either a custom
  plugin or global `kustomize.buildOptions: --enable-helm`; the repository
  currently assumes that setting.
  ([Argo CD Kustomize documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/#kustomizing-helm-charts))
- Kustomize's own production guidance warns against depending on uncontrolled
  remote configuration at render time. Keep the exact chart pinned and
  verified, and use the approved local/mirrored artifact path when provenance,
  availability, or offline rendering matters. Kustomize also notes that it does
  not perform chart cache/version management.
  ([Kustomize chart guidance](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/chart.md#best-practice))
- CRDs require special attention. Kustomize's `includeCRDs` option defaults to
  false, so this base must continue setting it explicitly, and CRD compatibility
  must be reviewed before the controller is upgraded.
  ([Kustomize `HelmChart` API](https://github.com/kubernetes-sigs/kustomize/blob/master/api/types/helmchartargs.go))

## Recommendation

Keep the current unmodified ArkMQ Helm chart as the Kustomize base. It is the
right maintenance boundary for this open-source EKS/GitOps architecture, and
the repository already has the essential controls: exact version and digest
pins, thin overlays, fail-closed related-image mappings, offline artifact
verification, render tests, and a staged upgrade workflow.

For each operator upgrade:

1. Obtain and verify the exact chart artifact, release manifest, operator image,
   and supported broker-version matrix.
2. Change the central release record and chart version together.
3. Render all environments and review the complete object diff, especially
   CRDs, RBAC, selectors, names, and related-image environment variables.
4. Run repository validation and operator/operand compatibility tests before
   promotion; upgrade the operator and broker as separate observed changes.

If the target changes from community Artemis on Kubernetes/EKS to supported
Red Hat AMQ Broker on OpenShift, revisit this decision. In that case OLM is the
Red Hat-documented lifecycle mechanism, including channel-based micro updates;
minor-version updates remain manual even with OLM.
([Red Hat AMQ Broker Operator installation and upgrade guidance](https://docs.redhat.com/en/documentation/red_hat_amq_broker/7.13/html-single/deploying_amq_broker_on_openshift/))
