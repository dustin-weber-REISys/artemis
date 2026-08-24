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

Each stable root path is a thin Kustomize adapter over
[`bootstrap/base`](bootstrap/base). The rendered adapter always contains:

- one `AppProject` for the environment-local `messaging-platform` policy;
- one ordinary `Application` for the cluster's ArkMQ operator;
- one ordinary `Application` for the cluster's shared ZooKeeper ensemble; and
- one `ApplicationSet` that generates only that cluster's Workload Cell
  Applications from the matching file under [`topology`](topology).

Each environment file under [`topology`](topology) is the single editable
source of truth for cluster identity and its Workload Cells: identity, traffic
class, namespace, management hostname, storage, resources, Profile, typed
features, and enablement. Argo CD consumes that file directly. There is no
catalog generation step or second committed copy.

The adapter patch owns only cluster identity and integration placeholders. The
shared base owns the fixed `argocd` and `artemis-platform` namespaces,
composition policy, sync safety, derived names, and deployment inputs. Workload Cell
namespaces are fixed as `artemis-<traffic>-<logical-environment>`, where
`internal` is abbreviated to `int`, `external` to `ext`, and functionality such
as `batch` is named directly. [`profiles`](profiles) provides reusable
capability policy; a Workload Cell selects exactly one Profile and can set only
that Profile's typed feature choices. Each cell also has one schema-validated,
ownership-restricted file under [`workloads`](../workloads) for pair-owned
listeners, destinations, and client sources. Deferred external cells may also
stage Secret references and authorization there while remaining disabled.
The centrally selected Platform Release
remains outside every adapter, Profile, and Workload Cell.

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

The operator Applications use the matching repository-owned
[`arkmq-operator`](../kustomize/arkmq-operator) Kustomize overlay as their Git
source. Kustomize inflates the pinned, unmodified public ArkMQ Broker Operator
chart, applies common scheduling and admission policy, and then applies the
environment label and private ECR image references. Argo CD must enable Helm
inflation with `kustomize.buildOptions: --enable-helm`.

The `-v2` Deployment identity remains a declarative replacement for
installations whose immutable selectors were rendered differently by earlier
revisions. `PruneLast=true` keeps the old controller available until the
replacement is healthy, then automated pruning removes it. Private image tags
must be immutable under the platform's ECR policy. The chart digest and
checksum remain release provenance; container deployments use the selected
private ECR tags.

The bootstrap-managed `messaging-platform` project allows:

- the standalone Artemis Git repository used by every child Application;
- `https://kubernetes.default.svc` as the only destination server;
- the local platform namespace explicitly and resolved Workload Cell
  namespaces through the constrained `artemis-*` pattern; and
- the exact cluster-scoped kinds rendered by the approved ArkMQ operator
  chart. With `clusterScoped: true`, this includes `Namespace`,
  `CustomResourceDefinition`, `ClusterRole`, and `ClusterRoleBinding` at
  minimum; admission or other cluster-scoped kinds must be derived from the
  mirrored chart rather than guessed.

The root Application uses the `default` project for bootstrap. Sync wave `-30`
creates the environment-local `messaging-platform` project before the operator,
ZooKeeper, and generated Artemis Applications reference it. Git and private
image-registry credentials remain platform-owned and must exist before the
root sync. Repo-server also needs an approved network path to the pinned public
chart. Private ECR chart mirroring remains deferred until repo-server
credential delivery is resolved and verified.

### Root revision injection contract

The Terraform-owned root Application selects one branch, tag, or commit. It
must inject that value by patching the rendered AppProject annotation
`composition.artemis.apache.org/git-revision`; do not patch child resources.
The adapter's Kustomize replacements copy this one value to the operator
source, ZooKeeper source, ApplicationSet Git generator, and generated Workload
Cell source.

For example, the root Application's Kustomize options should contain a patch
equivalent to:

```yaml
spec:
  source:
    path: gitops/argocd/bootstrap/test
    targetRevision: upgrade/platform-release
    kustomize:
      patches:
        - target:
            group: argoproj.io
            version: v1alpha1
            kind: AppProject
            name: messaging-platform
          patch: |-
            - op: replace
              path: /metadata/annotations/composition.artemis.apache.org~1git-revision
              value: upgrade/platform-release
```

`spec.source.targetRevision` and the injected annotation value must be equal.
The checked-in default revision is `main`. The work-laptop deployment workflow
may inject an approved tag, commit, or temporary feature branch through the
root Application contract above; a feature branch is a Release Promotion
input, not permanent cluster configuration.

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
5. change `enabled` to `"true"` for one test Workload Cell in its environment
   topology file, allow it to reconcile, and complete acceptance; and
6. enable the remaining Workload Cells one at a time before promoting the same
   artifacts.

New Workload Cells require one complete entry in the matching environment
topology file and a matching workload values file. The workload ApplicationSet uses
`applicationsSync: create-update` and preserves resources on ApplicationSet
deletion, so an accidental topology edit cannot automatically delete an
existing generated Application or its live resources. Retirement is a
separate, explicitly approved operation documented in
[`Workload Cell retirement`](../docs/runbooks/workload-cell-retirement.md).

The shared ZooKeeper Application is the deliberate exception to automated
child synchronization. Its three retained, AZ-bound volumes make scheduling a
live prerequisite that Git rendering cannot prove. A merge may make the
Application `OutOfSync`, but an operator must run the repository's read-only
ZooKeeper rollout gate, review the Argo diff, and start the sync manually. The
StatefulSet then performs the one-voter-at-a-time update; Argo CD does not
provide a separate StatefulSet rollout controller.

The `-10` annotation on the ZooKeeper `Application` orders that child
Application between the operator (`-20`) and workload cells (`0`) in the root
composition. It is not a pre-StatefulSet hook inside the ZooKeeper Application.
Do not add a `YOUR_ECR/...:PINNED_TAG` hook placeholder: an in-cluster gate is
safe only after its executable image has a repository-owned build, immutable
promotion pin, read-only RBAC, and tests for initial bootstrap, rollout, and
repair. Until those artifacts exist, the checked-in operator-run gate is the
executable control.

Do not copy these raw ApplicationSet manifests into an outer Helm
`templates/` directory without escaping the ApplicationSet Go-template
expressions. The intended root source is the raw YAML bootstrap directory.

Replace `PLACEHOLDER_NONPROD_ECR_REPOSITORY` and
`PLACEHOLDER_PROD_ECR_REPOSITORY` with full ECR prefixes shaped like
`123456789012.dkr.ecr.us-gov-west-1.amazonaws.com/artemis`. The checked-in
configuration appends image names. The operator Kustomize base inflates the
pinned public chart while its environment overlay selects these private image
references. Replace every other placeholder before sync. Each AppProject
allows the exact Git source used by its children. Git and private image-registry
credentials, AppProject policy, and secret values remain outside this
repository.
