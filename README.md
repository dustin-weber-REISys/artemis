# Artemis on EKS

Generic GitOps baseline for running Apache ActiveMQ Artemis on existing Amazon
EKS clusters with Argo CD, Helm, the ArkMQ Broker Operator, and ZooKeeper.

The repository models an independent, persistent Artemis HA pair for each
workload. Pairs in an EKS cluster normally share an operator and ZooKeeper
ensemble, but not journals, volumes, services, credentials, queue catalogs, or
coordination identities. The generated workload topology is authoritative in
[`argocd/applications/artemis-workloads-applicationset.yaml`](argocd/applications/artemis-workloads-applicationset.yaml).

This is not an AWS account bootstrap. Replace every placeholder through the
approved environment integration process before sync; never commit credentials
or other secret values.

## Start here

- [`docs/implementation-spec.md`](docs/implementation-spec.md): design
  rationale, safety contract, ownership boundaries, and promotion gates.
- [`docs/environment-import-walkthrough.md`](docs/environment-import-walkthrough.md):
  prerequisites, external-system handoffs, bootstrap order, and known
  pre-production gaps.
- [`docs/adr-operator-ha.md`](docs/adr-operator-ha.md): why the operator-managed
  competing-primary design was selected and what must be proven at runtime.
- [`docs/adr-zookeeper-topology.md`](docs/adr-zookeeper-topology.md): shared
  coordination rationale and isolation trade-offs.
- [`docs/runbooks`](docs/runbooks): installation, failure, incident, upgrade,
  compatibility, and recovery procedures.

Current deployable values, supported versions, ports, and defaults live in the
charts and their schemas:

- [`charts/artemis-ha/values.yaml`](charts/artemis-ha/values.yaml) and
  [`charts/artemis-ha/values.schema.json`](charts/artemis-ha/values.schema.json)
- [`charts/zookeeper/values.yaml`](charts/zookeeper/values.yaml) and
  [`charts/zookeeper/values.schema.json`](charts/zookeeper/values.schema.json)
- [`environments`](environments) for promotion overlays
- [`tests/e2e/scenarios.yaml`](tests/e2e/scenarios.yaml) for the acceptance
  scenario catalog

## Validate

From the repository root:

```sh
make validate
make package
```

`make validate` is the canonical repository check. Its implementation and
required tools are authoritative in the [`Makefile`](Makefile) and
[`scripts`](scripts). Some checks require network access to the configured
operator artifact source; environment variables supported by those scripts
may redirect downloads to approved internal mirrors.

## Develop locally

Docker Compose provides a durable standalone broker for application wiring; it
does not reproduce EKS HA:

```sh
make local-up
make local-smoke
make local-status
make local-logs
make local-down
```

`make local-reset` additionally removes the local named volume and retained
messages. See [`docs/local-development.md`](docs/local-development.md) for the
security, persistence, and scope limitations. The authoritative local image,
ports, credentials, and overrides are in [`compose.yaml`](compose.yaml) and
[`.env.example`](.env.example).
