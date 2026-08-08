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

The operator Applications use the repository-owned
[`arkmq-operator`](../charts/arkmq-operator) wrapper chart as their Git source.
The wrapper pins a repository-local copy of ArkMQ Broker Operator `2.2.0` and
patches its label handling so Gatekeeper-required labels are present on the
operator Deployment and pod template. Its `-v2` Deployment identity performs a
one-time declarative replacement for installations whose immutable selectors
were rendered differently by earlier revisions. `PruneLast=true` keeps the old
controller available until the replacement is healthy, then automated pruning
removes it.
Operator and operand image locations remain environment-specific ECR
placeholders in the bootstrap manifests. The manager image uses the mirrored
`2.2.0` tag rather than the upstream Quay digest: ECR returned `NotFound` when
the private repository was combined with a digest that was not present in that
repository. The private tag must be immutable under the platform's ECR policy.
The approved `2.53.0` init and broker operands follow the same rule: their
related-image variables use the private mirror's immutable
`artemis.2.53.0` tags, not the upstream Quay digests stored as vendored-chart
fallbacks.

The repository-local chart dependency needs no runtime Helm-registry
credentials. The separate ECR mirroring design remains documented in
[`Helm chart mirroring to ECR`](../docs/helm-ecr-mirroring.md) for a future
switch back to the private source.

The bootstrap-managed `messaging-platform` project allows:

- the standalone Artemis Git repository used by every child Application;
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
root sync; the repository-local operator dependency needs no ECR Helm token.

Set `PLACEHOLDER_GITOPS_REVISION` in the bootstrap manifests to the exact
branch, tag, or commit configured for the root entry in `argocd_repos`. The
operator wrapper source, ZooKeeper source, workload generator, and generated
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
configuration appends image names. The wrapper resolves its chart dependency
from the checked-in `vendor` directory rather than an Application source.
Replace every other placeholder before sync. Each AppProject allows the exact
Git source used by its children. Git and private image-registry credentials,
AppProject policy, and secret values remain outside this repository.
