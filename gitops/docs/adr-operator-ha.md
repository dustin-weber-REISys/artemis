# ADR: Artemis HA through the ArkMQ Broker Operator

- Status: Accepted for chart implementation; runtime HA acceptance remains a
  promotion gate
- Date: 2026-07-28
- Decision owners: Platform Engineering

## Context

The deployment needs two persistent Artemis peers with coordinated replication,
ZooKeeper-backed activation locking, active-only client routing, and one
operator-managed lifecycle. Replication participation in a send response is
not proof that the passive PVC completed an independent `fsync`; the
acknowledged-send claim also depends on the active broker's explicitly pinned
journal/data sync settings. The operator has no typed field representing the
complete competing-primary lock-manager policy, so the design must either use
its supported broker-property extension or replace operator reconciliation
with repository-owned StatefulSets.

## Decision

Use one operator-managed `ActiveMQArtemis` resource per HA pair. The chart
keeps exactly two persistent peers and supplies the replication-primary
lock-manager property tree through the operator-supported `brokerProperties`
extension. Both peers share a pair-unique coordination ID and ZooKeeper
connection while retaining separate volumes.

The operator continues to own the generated StatefulSet, PVC lifecycle, and
peer discovery. The chart owns stable protocol and management services,
console ingress, security/policy resources, and an authenticated readiness
check intended to select only the active broker. Startup and liveness do not
treat normal passive state as failure.

This is the smallest operator-compatible customization. A repository-owned
StatefulSet is a fallback only after evidence shows the operator cannot
preserve the required configuration or lifecycle.

## Version and schema evidence

At acceptance, the initial implementation specification named an Artemis
candidate newer than the selected operator supported. The chart resolved that
conflict by selecting an operator-supported operand and constraining accepted
versions to the upstream matrix.

Current operator, operand, image, and digest values are deliberately not copied
into this ADR. They are authoritative in:

- [`charts/artemis-ha/values.yaml`](../charts/artemis-ha/values.yaml);
- [`charts/artemis-ha/values.schema.json`](../charts/artemis-ha/values.schema.json);
- [`kustomize/arkmq-operator`](../kustomize/arkmq-operator); and
- the environment-local operator Applications under
  [`argocd/bootstrap`](../argocd/bootstrap).

Repository validation checks the rendered broker custom resource against the
pinned operator schema. Updating the operator or operand requires matrix
evidence, artifact review, chart/schema changes, and the full runtime acceptance
suite; it must not be accomplished by relaxing schema validation.

Primary technical evidence:

- [ArkMQ operator version matrix](https://github.com/arkmq-org/activemq-artemis-operator/blob/v2.2.0/version/version.go)
- [ArkMQ `ActiveMQArtemis` API types](https://github.com/arkmq-org/activemq-artemis-operator/blob/v2.2.0/api/v1beta1/activemqartemis_types.go)
- [ArkMQ operator CRD](https://github.com/arkmq-org/activemq-artemis-operator/blob/v2.2.0/config/crd/bases/broker.amq.io_activemqartemises.yaml)
- [ArkMQ broker-property configuration](https://github.com/arkmq-org/activemq-artemis-operator/blob/v2.2.0/docs/help/operator.md#configuring-brokerproperties)
- [Apache Artemis HA](https://artemis.apache.org/components/artemis/documentation/latest/ha)

## Limitations and required acceptance

The operator does not type-check the lock-manager property tree or prove that
the selected image contains the Curator implementation. It also does not make
rendered YAML proof of split-brain safety. The chart therefore constrains the
shape, exposes no separate automatic-failback override, and delegates any
controlled role reversal to the runbook after synchronization.

Runtime acceptance on the exact mirrored artifacts must prove:

- the required lock-manager classes load and the broker reports no rejected
  properties;
- exactly one peer becomes active through broker, pod, node, zone, replication,
  and ZooKeeper isolation cases;
- the passive peer is excluded from client service while its process remains
  healthy;
- acknowledged durable message accounting and the recovery target pass;
- the recovered peer synchronizes before a controlled role reversal; and
- the selected metrics and logs expose activation and replication evidence.

The upstream image is preferred. A thin derivative is allowed only when runtime
evidence demonstrates a missing required class or filesystem behavior. It must
preserve the reviewed upstream base, contain no secrets, run non-root, and
repeat license, SBOM, scan, signature, digest, and acceptance review.

Vault injection is not equivalent to broker authentication integration. The
operator may generate or consume Kubernetes Secrets, while the injector writes
pod-local files. The environment must provide and test an approved bridge
without placing secret values in Git or manifests.

Hawtio OIDC configuration authenticates the browser but does not complete
Artemis management authorization. Principal mapping, scoped management grants,
and both UI and direct-Jolokia enforcement remain production gates.

## Consequences

The design retains operator ownership of broker lifecycle and keeps the HA
policy reviewable in the custom resource. It also makes real-cluster
destructive testing mandatory: local rendering can verify topology and property
shape, but not durability, activation safety, client routing, authorization, or
credential rotation.
