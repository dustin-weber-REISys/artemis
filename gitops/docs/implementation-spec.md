# Apache ActiveMQ Artemis on EKS: implementation specification

Status: implementation baseline  
Audience: platform engineering, application teams, security, and operations

## Purpose and safety contract

This repository provides an open-source, AWS-hosted deployment baseline for
Apache ActiveMQ Artemis on existing EKS clusters. Argo CD deploys repository
charts and immutable images mirrored into an approved registry.

The system is accepted only when runtime evidence demonstrates:

1. no loss of broker-acknowledged durable messages across the approved failure
   cases;
2. no concurrent activation of both brokers in an HA pair;
3. automatic restoration of client service after primary failure;
4. acceptable behavior for the inventoried ActiveMQ Classic clients and
   features; and
5. operable upgrades, rollback, network admission, management authorization,
   monitoring, and recovery.

In-flight work may be redelivered. The delivery contract is at least once, so
consumers must be idempotent and producers should use a stable duplicate ID
when retrying a business operation.

## Sources of truth

Design rationale belongs in this specification and the ADRs. Concrete,
changeable implementation facts belong in executable files:

| Concern | Authoritative source |
| --- | --- |
| Local-cluster composition and child Applications | Rendered [`argocd/bootstrap`](../argocd/bootstrap) adapters |
| Cluster identity and complete Workload Cell topology consumed by Argo CD | Environment files under [`argocd/topology`](../argocd/topology) |
| Argo CD repository credentials and root Application | Per-cluster EKS Terraform inputs |
| `messaging-platform` AppProject policy | Shared [`argocd/bootstrap/base`](../argocd/bootstrap/base) rendered through the matching cluster adapter |
| Current platform, component, and image versions | [`releases/current.yaml`](../releases/current.yaml), the Artemis chart, and Kustomize deployment bases/overlays |
| Supported Artemis operands | [`charts/artemis-ha/values.schema.json`](../charts/artemis-ha/values.schema.json) |
| Rendered broker and ZooKeeper behavior | [`charts/artemis-ha`](../charts/artemis-ha) and [`kustomize/zookeeper`](../kustomize/zookeeper) |
| Validation workflow | [`Makefile`](../Makefile) and [`scripts`](../scripts) |
| Acceptance scenarios and thresholds | [`tests/e2e/acceptance-plan.yaml`](../tests/e2e/acceptance-plan.yaml) and [`performance/profiles/sustained-load-profiles.yaml`](../../performance/profiles/sustained-load-profiles.yaml) |
| Classic compatibility inventory | [`tests/compatibility/classic-6.2.6-inventory.yaml`](../tests/compatibility/classic-6.2.6-inventory.yaml) |
| Pair-owned listener, destination, and client-network policy; deferred external identity and authorization | Schema-validated files under [`workloads`](../workloads) |

If prose conflicts with one of these files, the executable source governs the
current implementation. A change that alters the design decision or safety
contract must update the relevant ADR or this specification in the same
review.

## Design principles

- **Topology parity, capacity variance.** Promotion environments keep the same
  HA and failure semantics while sizing, retention, identity, and alert routing
  may vary.
- **Compatibility first.** Preserve required Classic protocols and semantics
  during broker migration. Client-library or protocol modernization is a
  separate, reversible change.
- **Immutable supply chain.** Mirror, scan, sign, and tag upstream artifacts in
  immutable ECR repositories. Production does not pull unapproved public or
  mutable references. Every application or base-image rebuild receives a new
  image tag, allowing base-image maintenance to be reviewed even when the
  application version is unchanged.
- **GitOps ownership.** Argo CD is the normal writer of deployment state;
  runtime operators reconcile only the resources they own.
- **No secrets in Git.** Git stores secret references and non-secret policy,
  never credentials, tokens, private keys, or rendered secret data.
- **Failure behavior is a contract.** Rendering and schema checks are necessary
  but cannot prove split-brain safety, durability, or recovery time.

## Architecture and isolation

Each promotion workload is an independent, operator-managed Artemis HA pair
with separate persistent volumes. The peers use synchronous journal
replication and compete for activation through a ZooKeeper-backed distributed
lock. Clients connect through a stable service that must route only to the
active peer.

An EKS cluster normally has one shared ArkMQ operator and one shared
three-member ZooKeeper ensemble. Every broker pair has a unique coordination
ID and Curator namespace. Sharing coordination does not share journals,
volumes, services, credentials, policies, addresses, or queues. Cross-pair
cluster connections, federation, and bridges are absent unless separately
designed and approved.

Each EKS cluster runs its own Argo CD instance and consumes only its matching
thin Kustomize adapter and directly editable Workload Cell topology file. The
ApplicationSet generates only entries whose `enabled` field is `"true"`; the assignment below
is design intent, not evidence that a pair is currently deployed. Sandbox is
intentionally non-promotable and makes no HA, AZ-loss, durability, or upgrade
claim.

The accepted production topology assigns PE, PP, DM, and PR one internal
active/passive pair each, plus a distinct external pair for PP and PR.
External clients do not share the internal pair. PP and PR also retain
disabled batch placeholders. When enabled, every pair receives a
topology-owned management hostname, exact OIDC redirect URI, namespace,
coordination identity, and storage size. See the
[`workload-cell topology ADR`](adr-workload-cell-topology.md).

### Stronger isolation

A workload may receive dedicated broker placement and a separate ZooKeeper
release when capacity or coordination isolation justifies the additional
resources and operational lifecycle. That composition still shares the EKS
control plane, networking, and cluster-wide capacity.

Independence from whole-cluster failures requires a separate EKS cluster with
its own operator, ZooKeeper, platform integrations, and Argo CD destination.
Either option requires explicit infrastructure, security, and operations
approval; the default repository composition does not create it implicitly.
See the
[`ZooKeeper topology ADR`](adr-zookeeper-topology.md#dedicated-ensemble-option).

## Key decisions

### Operator-managed HA

The ArkMQ operator remains responsible for StatefulSet lifecycle, broker PVCs,
and generated discovery resources. The chart supplies the competing-primary
lock-manager policy through operator-supported broker properties and rejects
unsafe topology combinations. The chart does not expose a separate automatic
failback switch. Acceptance requires a recovered peer to rejoin passive and
permits a controlled role reversal only after synchronization.

The selected operator does not prove that its operand image contains the
required lock-manager classes or that both active and standby management
endpoints satisfy role-neutral readiness on the mirrored artifact. Those are
runtime promotion gates. See the
[`operator HA ADR`](adr-operator-ha.md).

### Persistence and placement

Each broker and ZooKeeper member owns its own `ReadWriteOnce` volume. Broker
peers must be placed on separate nodes and availability zones; ZooKeeper must
retain quorum across the intended failure domain. Shared cross-AZ broker
volumes are forbidden.

Storage binding, encryption, reclaim, snapshot, KMS, and restore policy are
platform responsibilities. Capacity is derived from measured message rate,
size, retention, paging, replay, replication latency, and recovery time—not
from prose in this document.

Per-pair volume size is authoritative in the environment topology, while the
stage-wide disk guardrail is authoritative in the environment values. The
provisional PP/PR envelope, its assumptions, and its promotion gate are
recorded once in the
[`workload-cell topology ADR`](adr-workload-cell-topology.md#storage-envelope).

### Protocol and destination compatibility

OpenWire is the initial migration interface for existing Classic clients. The
required port `61616` acceptor includes both `CORE` for operator-managed peer
traffic and `OPENWIRE` for clients, with advisory support explicit rather than
operator-defaulted. AMQP
is available for new integrations and later modernization. Other listeners
remain enabled only until runtime inventory and compatibility evidence approve
their removal. The current listener set and ports are defined by chart values.
No messaging listener is internet-facing by default.

Out-of-cluster internal clients use the accepted
[shared private NLB design](adr-shared-private-nlb.md) after its repository and
runtime implementation gates are complete. A unique frontend listener port and
dedicated target group identify each exposed Workload Cell acceptor; DNS names
alone do not route raw TCP between Workload Cells. Only protocols classified by
the [protocol acceptor inventory runbook](runbooks/protocol-acceptor-inventory.md)
receive NLB listeners. Until that implementation exists, the readiness-gated
`ClusterIP` Services remain the complete messaging exposure claimed here.

Permanent application addresses and queues are declared through the chart's
typed `destinations` catalog in promoted environments. A client typo must not
create a permanent destination. Dead-letter
resources may be created and retained by Artemis according to the chart's
address policy so per-source failure evidence remains available. Exact routing,
expiry, redelivery, paging, and auto-creation behavior is authoritative in the
chart and its focused tests.

The chart documents automatic per-source `DLQ.<address>` and optional
`EXP.<address>` resources. The present `#` policy is pair-wide. Application
teams may propose later policy changes, but independent per-team policies on a
shared pair require an explicit multi-match chart feature and queue-catalog
review; unrestricted broker-property overrides are not an approved interface.

The required Classic feature inventory and its current results live in
[`tests/compatibility/classic-6.2.6-inventory.yaml`](../tests/compatibility/classic-6.2.6-inventory.yaml).
A successful connection alone is not compatibility evidence.

### Security and management

The deployment boundary requires:

- non-root containers, least privilege, and default-deny network policy;
- no public broker load balancer;
- approved TLS for ingress and for future external messaging paths;
- immutable, scanned, signed artifacts;
- separate human-management authorization and messaging network admission; and
- audit evidence without credentials, tokens, or message bodies.

Keycloak owns human identity and group-to-role assignment. Hawtio authenticates
the browser session, while Artemis management RBAC must authorize the actual
JMX/Jolokia operation. UI visibility is not an authorization control.

Internal and batch messaging clients do not authenticate to Artemis. Those
Workload Cells render `requireLogin: false` and admit approved sources through
typed `networkPolicy.clientCidrs` or namespace/pod selectors. These rules reach
only enabled messaging acceptors; management and monitoring sources are
separate. Runtime acceptance must prove both allowed and denied sources using
the address actually observed by broker pods.

Keycloak role mapping and the operator's management-RBAC switch remain in
scope for Hawtio and direct Jolokia. External messaging-client JAAS, mTLS, and
typed destination authorization remain supported chart surfaces but are
deferred until an external Workload Cell is prepared and enabled.

### Secrets and Vault

Vault owns secret data and access policy. This chart may request pod-local
files through the Vault Agent Injector, but an injected credential file is not
automatically the operator's broker administrative identity. The environment
must provide and test an approved bridge before external messaging
authentication is enabled, such as a platform secret-sync controller or
operator-supported mounted authentication configuration.

The bridge must support rotation without secret values entering Git, rendered
manifests, Argo CD parameters, commands, or logs. ZooKeeper authentication and
TLS are currently deferred: the previous chart exposed disabled Secret-reference
inputs, but the Kustomize module does not claim that interface. Enabling either
requires an approved design whose Kubernetes Secret inputs are materialized by
an external process and whose rotation and negative paths are acceptance-tested.

### Observability and recovery

Prometheus evidence must cover activation, replication, queues, delivery,
paging, disk, JVM, ZooKeeper quorum, and operator reconciliation. The cluster
logging platform owns CloudWatch collection, routing, retention, encryption,
alarms, and dashboards. The chart does not own AWS backup resources.

Snapshot availability alone is not a broker-consistent recovery guarantee.
Recovery must preserve original evidence, isolate restored identities, account
for acknowledged messages, and follow
[`docs/runbooks/backup-restore.md`](runbooks/backup-restore.md).

## Ownership boundaries

| Owner | Responsibilities outside this repository |
| --- | --- |
| AWS/platform | Account, network, EKS, IAM, node capacity, EBS CSI, storage classes, KMS, snapshots, and restore infrastructure |
| Supply chain | ECR repositories, mirroring, SBOM, scanning, signing, provenance, and promotion evidence |
| GitOps platform | Per-cluster Argo CD installation, standalone Git/OCI credentials, local root Application, and bootstrap control |
| Security/Vault | Secret values, Vault auth mounts, policies, roles, certificate material, and approved secret materialization |
| Identity | Keycloak realm, public clients, redirect URIs, claims, groups, and role assignments |
| Application owners | Queue catalog, approved client source ranges, compatibility evidence, traffic quiescence, cutover, and business reconciliation |
| Operations | Monitoring selection, log collection, alarms, backup policy, incident command, and production approval |
| This repository | Artemis charts and versions, local-cluster Argo composition and project policy, workload topology, schemas, environment baselines, validation harness, ADRs, and runbooks |

## Validation and promotion gates

The machine-readable scenario catalog defines the concrete tests. Promotion
requires evidence for four claims: safety, liveness, compatibility, and
operability. At minimum:

- exactly one broker is active during every approved isolation test;
- broker-acknowledged durable IDs have no missing sequence;
- duplicates, redeliveries, and unacknowledged work are distinguished;
- ZooKeeper quorum loss never permits dual activation;
- client recovery is measured against the currently approved target;
- Argo CD returns to healthy reconciled state;
- approved internal CIDRs connect without credentials and unapproved sources are denied;
- management authentication and authorization succeed and fail for the intended roles;
- no secret appears in source, rendered resources, commands, or logs; and
- monitoring and logs contain enough evidence to explain each result.

Destructive scenarios are dry-run by default and require exact context,
cluster, and namespace confirmation plus an approved change window.

Artifacts move from test to nonprod to production under the same immutable tag. Do not
rebuild between environments or combine operator, broker, ZooKeeper, and client
upgrades into one unobserved change. Production promotion requires successful
failure, load, upgrade, rollback, CIDR-admission, management-authorization, and
recovery evidence plus operational approval.

## Migration sequence

1. Inventory sanitized Classic configuration, live protocols, destinations,
   client libraries, feature use, traffic, retention, and backlog.
2. Configure equivalent Artemis destinations and record intentional semantic
   differences.
3. Validate existing clients against Artemis over the initial compatibility
   protocol and exercise failure/rollback behavior.
4. Rehearse traffic quiescence, backlog reconciliation, endpoint change, and
   rollback with application owners.
5. Cut over only after the approved business-count and sequence checks pass.
6. Modernize protocols and remove unused listeners as separate changes.

## Upstream references

- [Apache Artemis HA](https://artemis.apache.org/components/artemis/documentation/latest/ha.html)
- [Apache Artemis network isolation](https://artemis.apache.org/components/artemis/documentation/latest/network-isolation.html)
- [Apache Artemis security and authorization](https://artemis.apache.org/components/artemis/documentation/latest/security.html)
- [Apache Artemis management](https://artemis.apache.org/components/artemis/documentation/latest/management.html)
- [ArkMQ operator configuration](https://arkmq.org/docs/help/operator/)
- [Hawtio generic OIDC](https://hawt.io/docs/oidc.html)
- [Kubernetes ZooKeeper guidance](https://kubernetes.io/docs/tutorials/stateful-application/zookeeper/)
