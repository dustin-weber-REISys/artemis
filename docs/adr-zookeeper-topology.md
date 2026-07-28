# ADR: Shared ZooKeeper topology with per-broker Curator namespaces

- Status: Accepted baseline
- Date: 2026-07-28
- Decision owners: Platform Engineering

## Context

Each EKS cluster hosts the ArkMQ operator, a ZooKeeper coordination service,
and three Artemis workload namespaces. An Artemis HA pair needs a distributed
lock so that only one broker can become active. The coordination identity must
be isolated per pair even when several pairs use one ZooKeeper ensemble.

The repository must remain generic. Cluster names, namespaces, ECR locations,
Vault paths, domains, and account identifiers are supplied by deployment
configuration and are represented here only by `PLACEHOLDER_*` values.

## Decision

Use one independent three-member Apache ZooKeeper 3.9.5 ensemble per EKS
cluster in `PLACEHOLDER_PLATFORM_NAMESPACE` by default. The repository-owned
chart provides:

- one StatefulSet with three pods and one persistent `ReadWriteOnce` gp3-
  compatible PVC per pod;
- a headless peer-discovery Service and a separate client Service;
- required zone spread and host anti-affinity;
- a one-member `maxUnavailable` PodDisruptionBudget;
- probes that accept leader, follower, or standalone ZooKeeper modes without
  restarting passive or follower members;
- restricted four-letter commands, disabled admin server, Prometheus metrics,
  default-deny NetworkPolicies, and non-root security settings; and
- an image reference built from the official `apache/zookeeper:3.9.5` source,
  mirrored to ECR and pinned by digest.

Every Artemis HA pair uses the shared client Service but receives two unique
coordination values:

1. The pair's two brokers use the same `coordination.id`, so they compete for
   one activation lock.
2. The pair uses a unique Curator namespace, for example
   `/artemis/PLACEHOLDER_ENVIRONMENT/PLACEHOLDER_WORKLOAD_KEY`.

The namespace is an opaque coordination path, not a Kubernetes namespace. It
must never be reused by another HA pair in the same ensemble. ZooKeeper
sharing does not share broker journals, EBS volumes, credentials, queue data,
or broker services.

Argo CD applies resources in waves: operator CRDs and deployment at `-20`,
the shared ZooKeeper ensemble at `-10`, and Artemis workloads at `0`. The
operator chart is consumed from a mirrored ECR OCI repository at a pinned
version, while ZooKeeper and workload values are promoted through Git with
the exact image digest retained across test, nonprod, and prod.

## Dedicated-ensemble override

A workload may use a dedicated ensemble when its coordination failure blast
radius, upgrade cadence, or isolation requirement justifies the additional
three pods and PVCs. The workload overlay must explicitly set:

```yaml
coordination:
  zookeeper:
    ensembleMode: dedicated
    dedicatedEnsemble:
      enabled: true
    serviceName: PLACEHOLDER_DEDICATED_ZOOKEEPER_SERVICE
    serviceNamespace: PLACEHOLDER_DEDICATED_ZOOKEEPER_NAMESPACE
    curatorNamespace: /artemis/PLACEHOLDER_ENVIRONMENT/PLACEHOLDER_WORKLOAD_KEY
```

The dedicated ensemble is deployed as a separate release of the same chart,
with its own ECR image digest, values, PVCs, PDB, NetworkPolicies, and
three-zone placement. The Artemis Application then points to that release's
client Service. `curatorNamespace` remains unique even though the ensemble is
dedicated; this keeps the coordination identity explicit and makes a later
move back to the shared ensemble safe.

The override is not enabled by any promotion profile. It is an explicit
per-workload composition and requires the same destructive validation as the
shared topology.

## Consequences

Positive consequences:

- Each EKS cluster has one predictable coordination dependency to operate and
  monitor.
- Unique Curator namespaces prevent unrelated HA pairs from contending for a
  lock path.
- Three voters tolerate one member loss while preserving quorum.
- The dedicated option is available without modifying chart templates or
  weakening the promotion topology.

Trade-offs:

- A shared ensemble is a cluster-level failure domain for coordination. Loss
  of quorum prevents safe broker activation, although it must not permit split
  brain.
- All three members require zone capacity and persistent storage.
- A dedicated ensemble consumes more resources and adds another coordination
  dependency to monitor and upgrade.

## Validation and operational constraints

Before production promotion, test at least one member loss, quorum loss,
broker-to-ZooKeeper network isolation, node drain, pod rescheduling, and an
Argo CD resync. Acceptance requires exactly one active broker in every
isolation case and no dual activation when ZooKeeper quorum is unavailable.

The initial session timeout is 18 seconds through the chart's configurable
`maxSessionTimeout` value. Tune it from measured GC pauses and network
behavior; do not reduce it solely to make a failure detector appear faster.

No credentials, certificates, cluster identifiers, account identifiers, or
real service domains belong in this ADR or in the shared chart defaults.
