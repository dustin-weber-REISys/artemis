# Artemis GitOps and Helm

This area is the deployable EKS baseline. It owns:

- [`argocd`](argocd): per-cluster standalone-repository bootstraps and the
  environment-local broker-pair catalog, including disabled PP/PR batch
  placeholders;
- [`charts`](charts): the repository-owned Artemis HA and shared ZooKeeper
  charts, plus the ArkMQ operator wrapper and its immutable release pin;
- [`environments`](environments): test, non-production, and production runtime
  values without image locations or release pins;
- [`tests`](tests): chart, topology, compatibility, and EKS acceptance assets;
- [`scripts`](scripts): rendering, schema, topology, and scenario validation;
- [`docs`](docs): design decisions, environment import guidance, and runbooks.

## Deterministic validation

`make validate-charts` defaults to offline mode. It performs Helm linting,
rendering, chart assertions, and policy checks without allowing kubeconform to
download schemas. The JSON report records Kubernetes schema validation as
`NOT_RUN`; a successful offline run does not claim that schemas were checked.

Run the network-backed phase explicitly on a connected workstation:

```sh
ARTEMIS_SCHEMA_MODE=network make validate-charts
```

The target Kubernetes version comes from [`releases/current.yaml`](releases/current.yaml).
Network mode fails when schema downloads fail. Custom-resource schema checks
remain in `make validate-operator-schema`, which also distinguishes its offline
contract checks from its explicit network phase.

The vendored ArkMQ chart is generated from a checksum-locked upstream package
and named patches. See [`charts/arkmq-operator/vendor`](charts/arkmq-operator/vendor)
and run `make vendor-check ARKMQ_UPSTREAM_CHART=/path/to/chart.tgz` before an
operator upgrade.

The
[`observed production workload baseline`](docs/production-workload-baseline.md)
captures the consumer footprint, burst behavior, retained backlog, and
production-derived scenarios that should inform capacity and recovery testing.

Each EKS cluster has its own Argo CD instance. Terraform registers this
repository and creates one root Application pointing to
`gitops/argocd/bootstrap/<environment>`. The selected bootstrap creates its
environment-local `messaging-platform` AppProject before its child
Applications. All child destinations use the local cluster server
`https://kubernetes.default.svc`.

Argo CD paths are repository-relative and therefore include the `gitops/`
prefix. Helm values files remain relative to their chart directories.

From the repository root:

```sh
make validate-scenarios
make validate-topology
make test-topology
make validate-charts
make validate-operator-schema
```

Or run the area-level suite:

```sh
make -C gitops validate
```

The reusable deterministic client and load profiles live in
[`performance`](../performance). Local standalone development is isolated
under [`local`](../local).
