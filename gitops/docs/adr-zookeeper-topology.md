# ADR: Shared ZooKeeper topology with per-broker Curator namespaces

- Status: Accepted baseline
- Date: 2026-07-28
- Decision owners: Platform Engineering

## Context

Each Artemis HA pair needs a distributed activation lock, while each EKS
cluster hosts multiple independent pairs. Coordination can be shared to reduce
operational overhead only if pair identities remain isolated and quorum failure
cannot permit dual activation.

## Decision

Use one independent three-voter ZooKeeper ensemble per EKS cluster by default.
Every Artemis pair connects to that ensemble with:

1. one coordination ID shared only by its two peers; and
2. one Curator namespace never reused by another pair.

The Curator namespace is a ZooKeeper path, not a Kubernetes namespace. Sharing
the ensemble does not share broker journals, persistent volumes, services,
credentials, policies, addresses, or queues.

ZooKeeper members use separate persistent volumes and placement intended to
preserve quorum across a member or zone loss. Network access is restricted to
approved brokers, monitoring, and required platform services. Current image,
storage, security, probe, policy, and monitoring behavior is authoritative in
[`kustomize/zookeeper`](../kustomize/zookeeper); generated service names and
workload connections are authoritative in
[`argocd/bootstrap`](../argocd/bootstrap) and
[`argocd/topology`](../argocd/catalogs).

The operator, ZooKeeper, and broker layers must be bootstrapped in dependency
order with health gates. Sync-wave annotations communicate intent but do not,
by themselves, guarantee that separately generated Applications wait for one
another.

## Dedicated-ensemble option

A workload may use a separate overlay of the same ZooKeeper base when
coordination blast radius or upgrade cadence justifies three additional pods,
volumes, policies, and an independent maintenance lifecycle. Its Artemis
configuration must point to that ensemble and retain a unique coordination ID
and Curator namespace.

This is an approved architecture option, not a currently implemented
`ensembleMode` values switch. Enabling it requires explicit environment and
Argo composition changes, review of the generated endpoint and policies, and
the same destructive acceptance suite as the shared topology.

Dedicated ZooKeeper and broker nodes still share the EKS control plane,
networking, and cluster-wide capacity. Independence from those failures
requires a separate EKS cluster with its own operator, ensemble, integrations,
and Argo destination. That is an infrastructure decision outside the default
composition.

## Consequences

The default gives each EKS cluster one predictable coordination dependency and
allows one voter loss while retaining quorum. Unique paths prevent unrelated
pairs from contending for the same lock.

The trade-off is a shared coordination failure domain: quorum loss may prevent
safe activation for every pair using the ensemble, though it must never allow
split brain. A dedicated ensemble narrows that coupling at the cost of
capacity, monitoring, upgrades, and recovery work.

## Validation and operational constraints

Before production, test member loss, quorum loss, broker-to-ZooKeeper
isolation, node drain, pod rescheduling, and Argo reconciliation on the exact
artifacts. Acceptance requires exactly one active broker during every isolation
case and no dual activation without ZooKeeper quorum.

Session and connection timeouts must be tuned from measured GC and network
behavior. The configured values live in the Kustomize base and environment overlays;
do not reduce them merely to make failure detection appear faster.

No credentials, certificates, account identifiers, real cluster names, or
service domains belong in this ADR or shared defaults.
