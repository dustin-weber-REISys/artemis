# Artemis on EKS

Generic reference implementation for running Apache ActiveMQ Artemis on
existing Amazon EKS clusters through Argo CD and Helm.

The target design uses:

- one independent pair of synchronously replicated Artemis brokers on separate
  EBS volumes for each application environment;
- one three-member Apache ZooKeeper ensemble per EKS cluster by default for
  distributed activation locking;
- one shared open-source ArkMQ Broker Operator per EKS cluster;
- Vault Agent Injector for runtime secrets;
- nginx ingress and Keycloak OIDC for the Artemis/Hawtio console;
- Prometheus and CloudWatch observability; and
- environment overlays for `test`, `nonprod`, and `prod`.

Read [the implementation specification](docs/implementation-spec.md) before
changing the deployment model. The specification includes the legacy
compatibility baseline, environment sizing, failure semantics, and acceptance
tests.

For the concrete import sequence and the complete environment-input checklist,
read [the environment import and deployment walkthrough](docs/environment-import-walkthrough.md).

This repository contains generic names and placeholders only. Environment
specific hostnames, account identifiers, Vault paths, certificates, and image
registry locations must be supplied outside the shared chart defaults.

## Environment decision

Deploy one independent Artemis HA pair for each named application environment:

| EKS cluster | Application environments | HA pairs | Broker pods |
| --- | --- | ---: | ---: |
| `TEST` | `SKY`, `SKY2` | 2 | 4 |
| `Nonprod` | `smktest` (`EUT`), `TRN`, `TRN2`, `PT` | 4 | 8 |
| `Prod` | `PE`, `PP`, `DM`, `PR` | 4 | 8 |
| **Total** | **10** | **10** | **20** |

Every pair has the same promotion-grade topology: two competing Artemis
primaries, synchronous replication, separate EBS volumes, and a pair-unique
coordination identity. The pairs in an EKS cluster normally share its ArkMQ
operator and three-member ZooKeeper quorum. Vary capacity, retention, identity,
and alert thresholds by application environment while preserving the HA
semantics.

The same queue name may be declared in more than one application environment.
Queue names are local to an independent broker pair; journals, PVCs,
credentials, services, queue catalogs, and ZooKeeper coordination identities
are not shared.

For `PR`, dedicated broker node placement and a dedicated three-member
ZooKeeper ensemble are recommended to reduce the capacity and coordination
blast radius within the `Prod` EKS cluster. This remains an approved
configuration choice, not an implicit infrastructure change. If `PR` must
survive a whole-cluster control-plane, networking, capacity, or upgrade
failure, place it in a separate EKS cluster as the hard-isolation option.
`environments/sandbox` remains the only non-promotable, single-instance
composition.

## Migration decision

Preserve OpenWire first so existing ActiveMQ Classic 6.2.6 clients can move
without combining a broker migration and a client-protocol rewrite. AMQP 1.0
is enabled for new integrations and later modernization. STOMP, MQTT, and
WebSocket listeners remain compatibility options until the runtime protocol
inventory proves they can be removed.

## Repository map

- `charts/artemis-ha`: ArkMQ-managed, two-broker Artemis HA pair.
- `charts/zookeeper`: shared three-member coordination ensemble.
- `argocd`: operator, platform, and ten-workload ApplicationSets.
- `environments`: promotion overlays and the optional sandbox composition.
- `images/test-client`: deterministic OpenWire/AMQP validation client.
- `compose.yaml`: local standalone broker and optional validation smoke test.
- `tests`: compatibility inventory, load profile, and failure scenarios.
- `docs/runbooks`: install, failover, upgrade, backup, and incident guidance.

For local application development, see [the local Artemis development guide](docs/local-development.md).

## Local validation

```sh
make validate
make package
```

`make validate` lints and renders both charts and all promotion overlays,
checks Kubernetes schemas, validates each broker CR against the checksum-pinned
ArkMQ 2.2.0 CRD, renders the official operator chart with every operator
overlay, verifies the scenario catalog, validates `compose.yaml` when Docker
Compose is available, and runs the Java unit tests. The
operator manifest and chart can be redirected to internal artifact mirrors
with `ARKMQ_OPERATOR_MANIFEST_URL` and `ARKMQ_OPERATOR_CHART`; the expected
manifest digest remains mandatory.

### Without Make

`make` is only a convenience wrapper and is not required. From a
Bash-compatible shell, run the repository validation scripts directly:

```sh
./scripts/validate-repository.sh
./scripts/validate-operator-schema.sh
./scripts/validate-compose.sh --report reports/compose-validation.json
```

These scripts require the host validation tools described in
[the environment import and deployment walkthrough](docs/environment-import-walkthrough.md).
The Java unit tests and package build can instead use Maven in Docker, so host
Java and Maven are not required:

```sh
docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  maven:3.9.16-eclipse-temurin-17 \
  mvn -B -ntp -f images/test-client/pom.xml test

docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  maven:3.9.16-eclipse-temurin-17 \
  mvn -B -ntp -f images/test-client/pom.xml package
```

The local broker and smoke test can also be operated with Docker Compose
directly:

```sh
docker compose -f compose.yaml up -d --wait broker
docker compose -f compose.yaml ps
docker compose -f compose.yaml --profile smoke run --rm --build validation-smoke
docker compose -f compose.yaml down --remove-orphans
```

To remove the local broker's named volume and all retained messages, use the
destructive reset command:

```sh
docker compose -f compose.yaml down --remove-orphans --volumes
```

See [the local Artemis development guide](docs/local-development.md) for log,
port, credential, and persistence details.

Before deployment, replace the explicit placeholder cluster, namespace, ECR,
storage, Vault, ingress, Keycloak, and monitoring inputs described in
`docs/implementation-spec.md`. The destructive EKS scenarios default to
dry-run and require an explicit execution flag.
