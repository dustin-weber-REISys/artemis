# Artemis GitOps and Helm

This area is the deployable EKS baseline. It owns:

- [`argocd`](argocd): per-cluster standalone-repository bootstraps and the
  environment-local broker-pair catalog, including disabled PP/PR batch
  placeholders;
- [`charts`](charts): the repository-owned Artemis HA and shared ZooKeeper
  charts;
- [`environments`](environments): test, non-production, and production values;
- [`tests`](tests): chart, topology, compatibility, and EKS acceptance assets;
- [`scripts`](scripts): rendering, schema, topology, and scenario validation;
- [`docs`](docs): design decisions, environment import guidance, and runbooks.

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
