# Artemis GitOps

This area is the deployable EKS baseline. It owns:

- [`argocd`](argocd): one shared cluster-composition base, three directly
  editable environment topology files, and reusable Workload Cell Profiles;
- [`charts`](charts): the repository-owned Artemis HA chart;
- [`kustomize`](kustomize): the shared ZooKeeper manifests and the ArkMQ
  operator overlays applied to the unmodified upstream Helm chart;
- [`environments`](environments): test, non-production, and production runtime
  values without image locations or release pins;
- [`tests`](tests): chart, topology, compatibility, and EKS acceptance assets;
- [`scripts`](scripts): rendering, schema, topology, and scenario validation;
- [`docs`](docs): indexed design decisions, integration and migration guides,
  runbooks, proposals, and non-authoritative research.

Use the repository-wide
[change-location guide](../docs/repository-guide.md) before editing a value
layer. The [GitOps documentation index](docs/README.md) identifies which prose
is authoritative and which material is only a proposal or research record.

## Deterministic validation

`make validate-charts` and `make validate-zookeeper-kustomize` default to
offline mode. They render their respective deployment modules and run focused
contract checks without allowing kubeconform to download schemas. The chart
JSON report records Kubernetes schema validation as `NOT_RUN`; a successful
offline run does not claim that schemas were checked.

Run the network-backed phase explicitly on a connected workstation:

```sh
ARTEMIS_SCHEMA_MODE=network make validate-charts
```

The target Kubernetes version and immutable tag of every promoted operator,
broker, init, and ZooKeeper image come from
[`releases/current.yaml`](releases/current.yaml).
Network mode fails when schema downloads fail. Custom-resource schema checks
remain in `make validate-operator-schema`, which also distinguishes its offline
contract checks from its explicit network phase.

The ArkMQ operator uses Kustomize Helm inflation. Its base pins the public OCI
chart and owns the shared platform policy; environment overlays own only their
label and private image references. On a connected workstation, or with an
approved downloaded chart, run
`make validate-operator-kustomize ARKMQ_UPSTREAM_CHART=/path/to/chart.tgz`.
Release CI must run `make release-gate` with that variable so rendering cannot
silently become `NOT_RUN`. Exact release renderer versions are pinned in
[`toolchain.yaml`](toolchain.yaml).

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
prefix. Helm values files remain relative to the Artemis chart, and the
operator and ZooKeeper Applications point to their Kustomize overlay
directories.

From the repository root:

```sh
make validate-scenarios
make validate-topology
make test-topology
make validate-charts
make validate-zookeeper-kustomize
make validate-operator-schema
```

Or run the area-level suite:

```sh
make -C gitops validate
```

The reusable deterministic client and load profiles live in
[`performance`](../performance). Local standalone development is isolated
under [`local`](../local).
