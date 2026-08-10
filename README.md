# Artemis

This repository is organized into three operational areas. Each area has its
own README and Makefile; the root Makefile provides stable shortcuts across
them.

## Execution boundary

This checkout is an offline/test copy. The real Artemis deployment, AWS
credentials, and Kubernetes access exist only on the authorized work computer.
Do not run AWS SSO, `kubectl`, Argo synchronization, deployment, or other live
infrastructure operations from this workspace, even if local context entries
or expired credentials are present.

Use this checkout to edit and validate repository artifacts. Run commands that
collect live cluster evidence only on the work computer, then bring the
sanitized output back here for diagnosis and repository-owned fixes.

## Areas

### [`local`](local)

A standalone, durable Artemis broker for application development and smoke
testing with Docker Compose. It does not reproduce the EKS high-availability
design.

```sh
make local-up
make local-smoke
make local-down
```

### [`gitops`](gitops)

The deployable EKS baseline: standalone per-cluster Argo CD bootstraps, Helm
charts, environment overlays, topology, acceptance scenarios, runbooks, and
their validation scripts.

```sh
make validate-topology
make test-topology
make validate-charts
```

### [`performance`](performance)

The deterministic JMS validation client and reusable load profiles. A profile
can target the local Compose broker or an explicitly supplied deployed broker.

```sh
make performance-local PROFILE=burst

PERF_URL='amqps://broker.example.invalid:5671' \
PERF_USERNAME="$ARTEMIS_TEST_USER" \
PERF_PASSWORD="$ARTEMIS_TEST_PASSWORD" \
  make performance-deployed PROFILE=sustained
```

For the destructive, acknowledged-message failover check, first review the
plan and prerequisites:

```sh
./performance/run-failure-test.sh \
  --context example-eks \
  --cluster example-eks-cluster \
  --namespace example-messaging
```

See [`performance/README.md`](performance/README.md) for the explicit
confirmation flags and evidence produced by an execution.

## Validate the repository

```sh
make validate
```

This runs cross-area invariants, GitOps and Helm checks, local Compose
validation, and validation-client unit tests. Some checks require network
access to their configured artifact sources.

Run `make help` for the complete command list.

## Work laptop with GitHub UI copy/paste only

Use the [work-laptop copy/paste checklist](gitops/docs/work-laptop-copy-paste-checklist.md).
