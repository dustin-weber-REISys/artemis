# Argo CD composition

This repository is consumed as a standalone GitOps repository by one Argo CD
3.4.x installation in each EKS cluster. Cluster Terraform owns Argo CD itself,
repository credentials, the `messaging-platform` AppProject/RBAC boundary, and
the root `Application` that points at exactly one environment bootstrap
directory.

| Argo CD instance | Root Application source path |
| --- | --- |
| Test cluster | `gitops/argocd/bootstrap/test` |
| Nonprod cluster | `gitops/argocd/bootstrap/nonprod` |
| Production cluster | `gitops/argocd/bootstrap/prod` |

Every bootstrap directory contains:

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
| `argocd_additional_projects` | Create the least-privilege `messaging-platform` AppProject before the Artemis root Application is reconciled. |
| `argocd_repos` | Create one root Artemis Application using the matching bootstrap path, Git repository, and approved branch, tag, or commit. |

The approved ArkMQ Operator chart is promoted to the private ECR Helm/OCI
namespace documented in
[`Helm chart mirroring to ECR`](../docs/helm-ecr-mirroring.md). The operator
Applications use Argo CD multiple sources: ECR supplies the immutable chart
version and Git supplies the environment values. Operator container images
still come from the approved private ECR repositories configured in those
values.

The mirrored Helm namespace must also be registered through the platform's
Argo CD OCI credential mechanism. ECR authorization tokens are short-lived;
do not capture one as a long-lived Terraform value or secret. Use the owning
platform's approved credential refresh integration.

The Terraform-managed `messaging-platform` project must allow:

- the standalone Artemis Git repository and the environment's exact private
  Helm/OCI namespace as sources;
- `https://kubernetes.default.svc` as the only destination server;
- the local platform namespace and the workload namespaces listed in that
  cluster's topology file; and
- the exact cluster-scoped kinds rendered by the approved ArkMQ operator
  chart. With `clusterScoped: true`, this includes `Namespace`,
  `CustomResourceDefinition`, `ClusterRole`, and `ClusterRoleBinding` at
  minimum; admission or other cluster-scoped kinds must be derived from the
  mirrored chart rather than guessed.

The root Application should use the `default` project only for bootstrap. The
operator, ZooKeeper, and generated Artemis Applications continue to reference
the Terraform-created `messaging-platform` project. The standalone repository
must not create or modify its own AppProject.

Set `PLACEHOLDER_GITOPS_REVISION` in the bootstrap manifests to the exact
branch, tag, or commit configured for the root entry in `argocd_repos`. The
operator values source, ZooKeeper source, workload generator, and generated
workload source must all use that same environment revision.

## Controlled bootstrap

Sync-wave annotations communicate dependency intent, but the first deployment
must still be health-gated:

1. apply Terraform and verify the `messaging-platform` project, repository
   credentials, and root Application exist;
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

Replace `PLACEHOLDER_NONPROD_HELM_OCI_REPOSITORY` and
`PLACEHOLDER_PROD_HELM_OCI_REPOSITORY` with values shaped like
`123456789012.dkr.ecr.us-gov-west-1.amazonaws.com/artemis/helm`; Argo CD's
Helm-style OCI `repoURL` intentionally omits `oci://` and the chart name.
Replace every other placeholder before sync. Git/OCI credentials, AppProject
policy, and secret values remain outside this repository.
