# Argo CD composition

This repository is consumed as a standalone GitOps repository by one Argo CD
3.4.x installation in each EKS cluster. Cluster Terraform owns Argo CD itself,
repository credentials, and the root `Application` that points at exactly one
environment bootstrap directory. The selected bootstrap owns the
`messaging-platform` AppProject policy used by its child Applications.

| Argo CD instance | Root Application source path |
| --- | --- |
| Test cluster | `gitops/argocd/bootstrap/test` |
| Nonprod cluster | `gitops/argocd/bootstrap/nonprod` |
| Production cluster | `gitops/argocd/bootstrap/prod` |

Every bootstrap directory contains:

- one `AppProject` for the environment-local `messaging-platform` policy;
- one ordinary `Application` for the cluster's ArkMQ operator;
- one ordinary `Application` for the cluster's shared ZooKeeper ensemble; and
- one `ApplicationSet` that generates only that cluster's Artemis broker-pair
  Applications from the matching file under [`topology`](topology).

All destinations use `https://kubernetes.default.svc`. No Argo CD instance
needs another EKS cluster's API endpoint or registration. The EKS
infrastructure repository remains responsible for generic prerequisites such
as storage classes, EBS CSI, ingress, Vault integration capability, monitoring
CRDs, node labels, and network paths; it does not own the Artemis charts,
versions, topology, or promotion values.

## Terraform handoff

The existing EKS Terraform inputs map to Artemis as follows:

| Terraform-owned input | Artemis contract |
| --- | --- |
| `standalone_argocd_repos` | Register the standalone Artemis Git repository with the cluster-local Argo CD instance. |
| `argocd_repos` | Create one root Artemis Application using the matching bootstrap path, Git repository, and approved branch, tag, or commit. |

The ArkMQ Operator chart is pulled directly from the public upstream OCI
namespace at `quay.io/arkmq-org/helm-charts`. The operator Applications use
Argo CD multiple sources: Quay supplies the pinned chart version and Git
supplies shared release values. Operator and operand image locations remain
environment-specific ECR placeholders in the bootstrap manifests. Runtime
environment values do not repeat image locations, tags, or digests.

The public chart source does not require the ECR Helm credential-refresh
integration. The separate ECR mirroring design remains documented in
[`Helm chart mirroring to ECR`](../docs/helm-ecr-mirroring.md) for a future
switch back to the private source.

The bootstrap-managed `messaging-platform` project allows:

- the standalone Artemis Git repository and the operator chart's effective
  public Helm/OCI source
  (`quay.io/arkmq-org/helm-charts/arkmq-org-broker-operator`);
- `https://kubernetes.default.svc` as the only destination server;
- the local platform namespace and the workload namespaces listed in that
  cluster's topology file; and
- the exact cluster-scoped kinds rendered by the approved ArkMQ operator
  chart. With `clusterScoped: true`, this includes `Namespace`,
  `CustomResourceDefinition`, `ClusterRole`, and `ClusterRoleBinding` at
  minimum; admission or other cluster-scoped kinds must be derived from the
  mirrored chart rather than guessed.

The root Application uses the `default` project for bootstrap. Sync wave `-30`
creates the environment-local `messaging-platform` project before the operator,
ZooKeeper, and generated Artemis Applications reference it. Git and private
image-registry credentials remain platform-owned and must exist before the
root sync; the public operator chart source needs no ECR Helm token.

Set `PLACEHOLDER_GITOPS_REVISION` in the bootstrap manifests to the exact
branch, tag, or commit configured for the root entry in `argocd_repos`. The
operator values source, ZooKeeper source, workload generator, and generated
workload source must all use that same environment revision.

## Controlled bootstrap

Sync-wave annotations communicate dependency intent, but the first deployment
must still be health-gated:

1. apply Terraform and verify repository credentials and the root Application
   exist, then sync the root to create the `messaging-platform` project;
2. sync the operator Application, then wait for the operator and required
   CRDs;
3. sync ZooKeeper, then verify placement, persistent volumes, quorum, policy,
   and metrics;
4. preview the workload ApplicationSet;
5. change `enabled` to `"true"` for one test broker pair, allow it to
   reconcile, and complete acceptance; and
6. enable the remaining pairs one at a time before promoting the same
   artifacts.

Broker pairs default to disabled. The workload ApplicationSet uses
`applicationsSync: create-update` and preserves resources on ApplicationSet
deletion, so an accidental catalog edit cannot automatically delete an
existing generated Application or its live resources. Retirement is a
separate, explicitly approved operation.

Do not copy these raw ApplicationSet manifests into an outer Helm
`templates/` directory without escaping the ApplicationSet Go-template
expressions. The intended root source is the raw YAML bootstrap directory.

Replace `PLACEHOLDER_NONPROD_ECR_REPOSITORY` and
`PLACEHOLDER_PROD_ECR_REPOSITORY` with full ECR prefixes shaped like
`123456789012.dkr.ecr.us-gov-west-1.amazonaws.com/artemis`. The checked-in
configuration appends image names. The public Helm-style OCI `repoURL`
intentionally omits `oci://` and the chart name. Replace every other
placeholder before sync. Each AppProject must allow its exact Git and OCI
sources. Git and private image-registry credentials, AppProject policy, and
secret values remain outside this repository.
