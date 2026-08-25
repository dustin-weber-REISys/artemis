# Artemis

This repository contains the deployable and testable definition of the Artemis
messaging platform. Start with the
[repository guide](docs/repository-guide.md) before changing configuration; it
maps common changes to their authoritative files and explains the value-layer
precedence.

## Execution boundary

This checkout is an offline/test copy. The real Artemis deployment, AWS
credentials, and Kubernetes access exist only on the authorized work computer.
Do not run AWS SSO, `kubectl`, Argo synchronization, deployment, or other live
infrastructure operations from this workspace, even if local context entries
or expired credentials are present.

Use this checkout to edit and validate repository artifacts. Run commands that
collect live cluster evidence only on the work computer, then bring sanitized
output back here for diagnosis and repository-owned fixes.

## Start here

- [Repository structure and change guide](docs/repository-guide.md): where each
  kind of change belongs and what to validate.
- [GitOps documentation index](gitops/docs/README.md): current design,
  integration, migration, operations, proposals, and research documents.
- [Platform language](CONTEXT.md): canonical domain terms.
- [GitOps area guide](gitops/README.md): deployment composition and rendering.
- [Local development](local/README.md) and
  [performance validation](performance/README.md): non-production test paths.

## Repository areas

| Path | Responsibility |
| --- | --- |
| [`gitops/`](gitops) | EKS/Argo CD composition, the Artemis chart, operator and ZooKeeper Kustomize modules, environment topology, release data, tests, and operational guides. |
| [`local/`](local) | Standalone Docker Compose broker for application development and smoke testing. It does not reproduce EKS high availability. |
| [`performance/`](performance) | Deterministic JMS client, load profiles, and failure-test harness. |
| [`docs/`](docs) | Repository-wide contributor and agent guidance. |
| [`jobs/`](jobs) and [`resources/`](resources) | Jenkins seed and pipeline assets for the deferred Helm-to-ECR artifact workflow. |
| [`scripts/`](scripts) | Repository-wide validation entry points. |
| `reports/` | Generated validation output; do not edit it as source configuration. |

## Local development

Start, test, and stop the standalone broker from the repository root:

```sh
make local-up
make local-smoke
make local-down
```

Use `make local-reset` only when the retained local broker volume should be
deleted. See [`local/README.md`](local/README.md) for persistence and security
limitations.

## GitOps validation

Run focused checks while editing:

```sh
make validate-docs
make validate-topology
make test-topology
make validate-charts
make validate-zookeeper-kustomize
```

Operator rendering needs the approved upstream chart package when the
workstation cannot reach the pinned public OCI source:

```sh
ARKMQ_UPSTREAM_CHART=/path/to/arkmq-org-broker-operator.tgz \
  make validate-operator-kustomize
```

Release CI must use the artifact-backed gate rather than treating an offline
`NOT_RUN` result as sufficient:

```sh
ARKMQ_UPSTREAM_CHART=/path/to/arkmq-org-broker-operator.tgz \
  make release-gate
```

## Performance validation

Run a profile against the local broker:

```sh
make performance-local PROFILE=burst
```

An explicitly supplied deployed endpoint can be tested only from an authorized
workstation:

```sh
PERF_URL='amqps://broker.example.invalid:5671' \
PERF_USERNAME="$ARTEMIS_TEST_USER" \
PERF_PASSWORD="$ARTEMIS_TEST_PASSWORD" \
  make performance-deployed PROFILE=sustained
```

The acknowledged-message failover harness is destructive and remains plan-only
unless all context, cluster, and namespace confirmations are supplied. Review
[`performance/README.md`](performance/README.md) before using it.

## Validate the repository

```sh
make validate
```

This runs documentation checks, cross-area invariants, GitOps and Helm checks,
local Compose validation, and validation-client tests. Some checks require
network access to their configured artifact sources. Run `make help` for the
complete command list.
