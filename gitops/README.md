# Artemis GitOps and Helm

This area is the deployable EKS baseline. It owns:

- [`argocd`](argocd): per-cluster standalone-repository bootstraps and the
  environment-local 2/4/4 workload topology;
- [`charts`](charts): the Artemis HA and shared ZooKeeper Helm charts;
- [`environments`](environments): test, non-production, and production values;
- [`tests`](tests): chart, topology, compatibility, and EKS acceptance assets;
- [`scripts`](scripts): rendering, schema, topology, and scenario validation;
- [`docs`](docs): design decisions, environment import guidance, and runbooks.

Each EKS cluster has its own Argo CD instance. Terraform registers this
repository, creates the `messaging-platform` AppProject through
`argocd_additional_projects`, and creates one root Application pointing to
`gitops/argocd/bootstrap/<environment>`. All child destinations use the local
cluster server `https://kubernetes.default.svc`; this repository does not
create its own AppProject.

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
