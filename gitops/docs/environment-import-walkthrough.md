# Environment import and deployment guide

Status: environment integration guide  
Applies to: promotion environments; sandbox remains non-promotable

## Scope

This repository composes Artemis, ZooKeeper, and the ArkMQ operator onto
existing EKS and Argo CD platforms. It does not provision AWS accounts,
clusters, networking, registries, storage drivers, Argo CD, Vault, ingress,
DNS, Keycloak, monitoring, logging, backup infrastructure, application queues,
credentials, or client cutover.

Do not sync the supplied examples unchanged. Some placeholders are
syntactically valid and can pass rendering while remaining unusable or unsafe.
The effective rendered configuration must contain no placeholder, example
endpoint, all-zero digest, or secret value.

Replace `PLACEHOLDER_ARTEMIS_CONTACT` and `PLACEHOLDER_ARTEMIS_FISMAID` with
the enterprise ownership and system identifiers required by Gatekeeper. The
ZooKeeper and Artemis environment overlays set the required `env` label
explicitly. The Artemis chart passes these labels through
`spec.deploymentPlan.labels` for the operator-generated broker workloads.
All four values are Kubernetes label values, so they must be 63 characters or
fewer, use only letters, digits, `.`, `_`, or `-`, and begin and end with a
letter or digit. In particular, do not use a raw email address for `contact`:
`@` is not legal in a label value. Use the enterprise-approved label-safe
contact identifier instead; keep a human-readable email in an annotation or
the enterprise ownership system when one is also required.

Replace `PLACEHOLDER_ARTEMIS_ADMIN_USERNAME` once with the approved shared,
non-secret broker administrator name, such as `elis-admin`. That value is
rendered as `spec.adminUser` for every test, nonprod, and prod broker. Do not
add `spec.adminPassword` or a password value to Git; the operator generates a
different password in each deployment's credential Secret.

The local-cluster bootstraps are authoritative in
[`argocd/bootstrap`](../argocd/bootstrap), and each cluster's broker-pair
inventory is authoritative in [`argocd/topology`](../argocd/topology). Chart
defaults and constraints are authoritative in [`charts`](../charts), and
promotion overlays are in [`environments`](../environments). Do not copy those
volatile values into an environment checklist.

## Ownership and handoffs

| Layer | Owner and handoff required before sync |
| --- | --- |
| AWS/EKS | Platform team supplies the local cluster, network paths, node capacity, placement labels, EBS CSI, encrypted delayed-binding storage, KMS, and restore capability. |
| Artifact supply chain | Platform team supplies private image-registry access and evidence for exact image digests and the pinned public chart version, licenses, SBOMs, scans, signatures, provenance, and architecture support. |
| Argo CD | GitOps team supplies one local Argo CD installation per EKS cluster, ApplicationSet support, standalone Git credentials, the Terraform-created root Application, and a controlled bootstrap mechanism. The selected repository bootstrap supplies project policy. |
| Vault and certificates | Security/platform team supplies auth mounts, least-privilege policies and roles, CA/TLS material, workload-bound secret references, and any Secret synchronization. |
| Keycloak and ingress | Identity/network teams supply public OIDC clients, exact redirect URIs, claims and role mappings, DNS, TLS Secrets, ingress labels, and reachable issuer/JWKS endpoints. |
| Observability and backup | Operations supplies Prometheus discovery, log collection and retention, alarms, snapshots, restore procedures, and on-call ownership. |
| Messaging migration | Application owners supply the sanitized Classic inventory, declarative destinations, client identities, compatibility results, traffic plan, reconciliation rules, and cutover approval. |

Git stores only non-secret configuration and references. Credentials, tokens,
private keys, message bodies, account-specific evidence, and decoded bearer
tokens belong in their approved systems, not this repository or change logs.

## Prerequisites

Complete these checks before changing Argo CD resources:

### EKS and storage

- Nodes have the standard zone and hostname labels and enough simultaneous
  capacity in the zones required by broker anti-affinity and ZooKeeper quorum.
  Required placement may intentionally leave a pod pending rather than
  collapse the failure boundary.
- The EBS CSI driver uses its approved IAM role. Artemis and ZooKeeper service
  accounts do not receive AWS permissions merely to mount PVCs.
- The selected encrypted storage class supports `ReadWriteOnce` and
  `WaitForFirstConsumer`, uses `Retain`, and allows volume expansion. Snapshot,
  KMS, cross-account/region restore, and retention policies are approved
  outside this repository.
- A restore has been rehearsed in isolation. Never attach one restored broker
  volume to two broker identities or reuse the original coordination identity
  during an isolated recovery test.

### Cluster services and network

- The cluster-local Argo CD and its ApplicationSet controller, the approved
  IngressClass/controller, Vault Agent Injector, Prometheus CRDs (when enabled), a
  NetworkPolicy-enforcing CNI, DNS, and the cluster log collector are healthy.
- Actual namespace and pod labels are available for every NetworkPolicy
  selector. External Vault, Keycloak, DNS, or monitoring endpoints receive
  explicit least-privilege egress; pod selectors do not admit external IPs.
- Private clusters have approved paths to the registry and any AWS or identity
  endpoints required at runtime.
- Wildcard or workload TLS Secrets exist in each consuming namespace; ingress
  cannot normally reference a Secret in another namespace.

### Tools and artifact access

The canonical local workflow is in the root [`README`](../README.md#validate),
[`Makefile`](../Makefile), and [`scripts`](../scripts). Install the tools those
files check. The wrapper dependency in `charts/arkmq-operator/Chart.yaml` must
point to the approved ECR OCI namespace before a restricted-environment
promotion; the public upstream reference is for connected development and
initial import.

Cluster verification additionally needs the approved AWS, Kubernetes, Argo CD,
OCI-copy, signing, SBOM, and vulnerability-scanning tools selected by the
platform. This repository does not mandate a vendor for those functions.

## Integration workflow

### 1. Approve and mirror artifacts

Resolve current artifact references from chart values, environment overlays,
and the environment-local operator Applications. For every artifact:

1. copy the exact upstream artifact into the approved registry;
2. verify the destination digest and target architecture;
3. record source/destination digests, license, SBOM, scan, signature,
   provenance, and approval;
4. verify the operator/operand relationship against the operator-supported
   matrix; and
5. promote the same approved digest between environments without rebuilding.

The Artemis image must contain the ZooKeeper Curator lock-manager behavior
required by the HA ADR. A changed digest is a new artifact, even if its tag or
repository name appears equivalent.

### 2. Integrate Argo CD

Update the selected directory under
[`argocd/bootstrap`](../argocd/bootstrap) and its matching
[`topology`](../argocd/topology) file with the approved Argo namespace,
Git source, immutable revision policy, local platform namespace, workload
namespaces, and cluster identity. Replace the matching nonprod or prod ECR base
placeholder for the image repositories in the bootstrap manifests. The
repository-owned operator wrapper resolves its pinned, patched ArkMQ dependency
from the checked-in `vendor` directory.

In the cluster's Terraform configuration:

1. register the Artemis Git repository through `standalone_argocd_repos`; the
   repository-local operator dependency does not require chart-registry
   credentials;
2. add one Artemis root entry to `argocd_repos` whose source path is exactly
   `gitops/argocd/bootstrap/<environment>`; and
3. use the same approved branch, tag, or commit for the root entry and every
   `PLACEHOLDER_GITOPS_REVISION` in that environment's child manifests.

Do not register the other EKS clusters as destinations. Every child
Application uses `https://kubernetes.default.svc`. The environment bootstrap
creates its `messaging-platform` AppProject at sync wave `-30`, before any
Application references the project.

The bootstrap project allows the local platform and workload namespaces, the
Artemis Git source, and the exact cluster-scoped kinds rendered by the approved
ArkMQ chart. Each operator Application explicitly sets `clusterScoped: true`,
and the wrapper values repeat that default as defense in depth. The allowlist
therefore includes `Namespace`, `CustomResourceDefinition`, `ClusterRole`, and
`ClusterRoleBinding` at minimum.

Keep the operator's cluster scope, CRD ownership, and watch scope as
architecture decisions. Narrowing or expanding them requires RBAC and
ownership review, not a naming-only change.

The ZooKeeper release name and the Artemis connection template must continue
to resolve to the same client service. Coordination IDs and Curator namespaces
must remain unique per broker pair. These invariants are checked by repository
validation; do not create parallel standalone Applications for workloads
already generated by the local ApplicationSet.

### 3. Supply environment and workload values

Put settings shared by a promotion stage in its file under
[`environments`](../environments). Put the approved broker-pair identities and
namespaces in the matching topology file. Put workload-specific console,
Vault, client allowlist, queue, capacity, or alert differences in explicit
workload configuration or ApplicationSet parameters.

Artifact tags and digests are shared release data, not environment data. The
pinned ArkMQ chart maps the Artemis `broker.version` to its broker and init
digests; the [operator wrapper defaults](../charts/arkmq-operator/values.yaml)
pin the operator container. Promote them together by advancing the
environment's approved Git revision.

Review the effective schema and rendered manifest rather than following a
copied property inventory. At minimum, resolve:

- the selected ECR base repository and approved release digests;
- persistent storage and placement;
- the installed `aws-lb-ingress` IngressClass, shared ALB group, certificate
  coverage, and any environment-specific NetworkPolicy inputs;
- pair-unique HA and ZooKeeper identities;
- unique workload namespace, service, console, Keycloak, and Vault
  identities;
- actual NetworkPolicy namespace/pod selectors and approved external egress;
- declarative application addresses, queues, authorization, redelivery,
  dead-letter, expiry, paging, and auto-creation policy; and
- monitoring discovery labels, metric availability, and alert routing.

Do not add a separate automatic-failback override. Runtime acceptance must
show the recovered peer rejoining passive before any controlled role reversal.
Do not enable optional filesystem, TLS, or authentication modes without
verifying both endpoints and the exact runtime image.

### 4. Complete Vault authentication integration

For each workload, bind a least-privilege Vault role to the rendered broker
service account and namespace, provide the CA Secret, and verify the injector's
Kubernetes token flow when service-account token automount is disabled.

The current chart can request a credential file when `vault.enabled` is set,
but the option defaults off because it does not prove that the operator or
Artemis uses that file as its effective administrative identity. Before
enabling it, implement and test an approved bridge:

- platform synchronization to the exact Kubernetes Secret shape consumed by
  the operator;
- operator-supported mounted Secret or authentication configuration; or
- a minimal reviewed bootstrap integration that reads the injected file.

Rotation must not expose secret values through Git, manifests, Argo
parameters, command lines, or logs. ZooKeeper Secret inputs also require an
approved external materialization process when its authentication or TLS is
enabled.

### 5. Complete identity and management authorization

Keycloak owns users, groups, and console-role membership. Configure each
browser client as public, use authorization code flow with PKCE, and register
the exact rendered redirect URI. Hawtio authenticates the session; Artemis
management RBAC authorizes actions.

Before production, the effective broker configuration must demonstrate:

- the intended Keycloak claim and role mapping;
- the Artemis user and role principal classes;
- scoped management view/edit grants;
- exactly one Artemis management authorization mechanism; and
- least-privilege Jolokia and ingress restrictions.

The baseline chart does not yet complete every part of that chain. Verify both
the UI and direct Jolokia: unauthenticated and viewer identities must be denied
mutations, any limited operator role may perform only its explicit actions,
and administrators remain limited to the approved management scope. Use
disposable queues and redact tokens, credentials, personal claims, and message
bodies from evidence.

### 6. Complete external operations integration

Confirm Prometheus can discover the rendered monitors and that optional alerts
reference metrics exported by the selected runtime. Configure CloudWatch
collection, encryption, retention, routing, dashboards, and alarms in the
cluster logging platform; the charts render no AWS logging resources.

Configure EBS snapshots or AWS Backup outside the charts and rehearse
[`backup and restore`](runbooks/backup-restore.md). A crash-consistent volume
snapshot alone does not establish the acknowledged-message recovery claim.

## Bootstrap sequence

The order is an operational gate, not merely a set of sync-wave annotations.
Generated Applications do not necessarily wait for one another unless a
parent bootstrap or a phased procedure enforces health checks.

1. Approve artifacts and all AWS, cluster, identity, secret, observability, and
   backup prerequisites.
2. In each cluster's Terraform, configure this standalone Git repository and
   the root Application through `argocd_repos`, pointing only to that cluster's
   bootstrap path and approved revision. Confirm Argo CD can resolve the
   repository-local operator dependency; no ECR Helm token is required. The
   bootstrap creates the `messaging-platform` project.
3. Create Vault policies/roles/data references, Keycloak clients, TLS
   material, and the namespace/pod labels required by policy.
4. Run the canonical repository validation and inspect effective rendered
   manifests for placeholders, secret values, identity collisions, mutable
   images, and incorrect selectors.
5. Verify the root sync created the local `messaging-platform` AppProject and
   that its effective source, destination, and cluster-resource policy matches
   the rendered operator and the approved topology.
6. Sync the operator Application and wait for the operator and its CRDs to
   become healthy.
7. Sync the ZooKeeper Application and verify placement, separate PVCs, quorum,
   policy, and metrics.
8. Preview the local workload ApplicationSet, change `enabled` to `"true"` for
   one test broker pair, allow it to reconcile, and complete the first-workload
   checks below.
9. Enable remaining test workloads one at a time, then promote the exact
   artifacts to nonprod for load, failure, upgrade, rollback, rotation, and
   authorization testing.
10. Obtain application, security, platform, and operations approval before
    adding production workloads one at a time.

## First-workload acceptance

After Argo CD reports healthy reconciliation, record non-secret evidence that:

- the expected operator/CRDs and immutable related images are running;
- ZooKeeper has quorum, separate persistent volumes, and the approved
  node/zone placement;
- the two brokers have separate persistent volumes and approved placement;
- exactly one peer is active and client-ready, the passive peer is not routed,
  and replication is synchronized;
- the broker uses the approved Vault-sourced identity and rotation path;
- ingress TLS, DNS, Keycloak login, Artemis management RBAC, and direct Jolokia
  denial tests behave as approved;
- NetworkPolicies permit only intended messaging and platform paths;
- Prometheus and logging evidence is available without secrets or message
  bodies; and
- deterministic protocol, durability, failure, and recovery reports satisfy
  the machine-readable acceptance claims.

Use [`scripts/eks-scenario.sh`](../scripts/eks-scenario.sh) in its default
dry-run mode before any mutation. Destructive execution requires an approved
window and exact context, cluster, and namespace confirmations.

## Promotion gates

Promotion environments keep the same HA mode, persistence, placement, and
coordination semantics. Capacity, retention, identity, domains, allowlists,
secret references, and alert routing may vary based on measured evidence.

Stop promotion when any of the following remains unresolved:

- effective manifests contain placeholders, examples, mutable/unapproved
  artifacts, all-zero digests, or secret values;
- workload console, Keycloak, Vault, coordination, queue, or NetworkPolicy
  identity is inherited incorrectly or collides;
- the Vault-to-Artemis authentication bridge or injector token flow is
  unproven;
- optional ZooKeeper authentication/TLS is enabled on only one side;
- Classic compatibility, declarative destination ownership, or client cutover
  evidence is incomplete;
- the Hawtio-to-Artemis authorization chain or direct-Jolokia negative tests
  are incomplete;
- validation execution, CloudWatch, backup/restore, KMS, or alert ownership is
  missing; or
- real-cluster tests have not proven active-only routing, lock-manager
  availability, replication, quorum safety, acknowledged-message accounting,
  and the approved recovery target.

Dedicated ZooKeeper or broker placement may reduce a workload's coordination
or capacity blast radius inside an EKS cluster. Separate-cluster isolation is
an infrastructure change and requires its own approval; neither is silently
enabled by this import.
