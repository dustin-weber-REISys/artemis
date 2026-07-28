# Artemis on EKS

Generic reference implementation for running Apache ActiveMQ Artemis on
existing Amazon EKS clusters through Argo CD and Helm.

The target design uses:

- two synchronously replicated Artemis brokers on separate EBS volumes;
- a three-member Apache ZooKeeper ensemble for distributed activation locking;
- the open-source ArkMQ Broker Operator;
- Vault Agent Injector for runtime secrets;
- nginx ingress and Keycloak OIDC for the Artemis/Hawtio console;
- Prometheus and CloudWatch observability; and
- environment overlays for `test`, `nonprod`, and `prod`.

Read [the implementation specification](docs/implementation-spec.md) before
changing the deployment model. The specification includes the legacy
compatibility baseline, environment sizing, failure semantics, and acceptance
tests.

This repository contains generic names and placeholders only. Environment
specific hostnames, account identifiers, Vault paths, certificates, and image
registry locations must be supplied outside the shared chart defaults.

## Environment decision

Keep `test`, `nonprod`, and `prod` architecturally identical: two competing
Artemis primaries, synchronous replication, separate EBS volumes, and a
three-member ZooKeeper quorum spread across availability zones. Vary capacity,
retention, and alert thresholds only. This lets test exercise failover,
operator upgrades, storage behavior, and rollback before the same artifacts
are promoted. `environments/sandbox` is the only non-promotable,
single-instance composition.

## Migration decision

Preserve OpenWire first so existing ActiveMQ Classic 6.2.6 clients can move
without combining a broker migration and a client-protocol rewrite. AMQP 1.0
is enabled for new integrations and later modernization. STOMP, MQTT, and
WebSocket listeners remain compatibility options until the runtime protocol
inventory proves they can be removed.

## Repository map

- `charts/artemis-ha`: ArkMQ-managed, two-broker Artemis HA pair.
- `charts/zookeeper`: shared three-member coordination ensemble.
- `argocd`: operator, platform, and nine-workload ApplicationSets.
- `environments`: promotion overlays and the optional sandbox composition.
- `images/test-client`: deterministic OpenWire/AMQP validation client.
- `tests`: compatibility inventory, load profile, and failure scenarios.
- `docs/runbooks`: install, failover, upgrade, backup, and incident guidance.

## Local validation

```sh
make validate
make package
```

`make validate` lints and renders both charts and all promotion overlays,
checks Kubernetes schemas, validates each broker CR against the checksum-pinned
ArkMQ 2.2.0 CRD, renders the official operator chart with every operator
overlay, verifies the scenario catalog, and runs the Java unit tests. The
operator manifest and chart can be redirected to internal artifact mirrors
with `ARKMQ_OPERATOR_MANIFEST_URL` and `ARKMQ_OPERATOR_CHART`; the expected
manifest digest remains mandatory.

Before deployment, replace the explicit placeholder cluster, namespace, ECR,
storage, Vault, ingress, Keycloak, and monitoring inputs described in
`docs/implementation-spec.md`. The destructive EKS scenarios default to
dry-run and require an explicit execution flag.
