# Apache ActiveMQ Artemis on EKS: Implementation Specification

Status: implementation baseline  
Last updated: 2026-07-28  
Audience: platform engineering, application teams, security, and operations

## 1. Purpose

Build a generic, fully open-source, AWS-hosted deployment of Apache ActiveMQ
Artemis on existing Amazon EKS clusters. Argo CD deploys versioned Helm
artifacts and immutable container images mirrored into Amazon ECR.

The system must:

1. Preserve acknowledged durable messages through broker, node, and
   availability-zone failures.
2. Prevent two brokers in one HA pair from becoming active concurrently.
3. Restore client service automatically after a primary broker failure.
4. provide an upgrade path from ActiveMQ Classic 6.2.x clients and behavior.
5. Integrate with existing Vault Agent Injector, nginx ingress, wildcard TLS
   certificates, Keycloak, Prometheus, and CloudWatch patterns.
6. Support nine application namespaces distributed across separate `test`,
   `nonprod`, and `prod` EKS clusters.
7. Avoid paid products and external runtime dependencies.

## 2. Design Principles

- **Topology parity, capacity variance.** Promotion environments use the same HA
  components and failure semantics. CPU, memory, storage, retention, and load
  differ by environment.
- **Compatibility first.** Preserve existing client protocols during the first
  migration phase. Modernization to AMQP is a later, independently reversible
  change.
- **Immutable supply chain.** Mirror, scan, sign, and pin upstream images and
  Helm artifacts in AWS. Production must not pull from public registries.
- **GitOps ownership.** Argo CD is the only normal writer of deployment state.
  Runtime operators may reconcile their own custom resources.
- **No secrets in Git.** Vault renders credentials and sensitive configuration
  into pod-local files.
- **Failure behavior is a contract.** HA is accepted only after automated
  destructive tests demonstrate safety and recovery.

## 3. Evidence From the Legacy Deployment

The supplied screenshots are reference evidence, not a complete inventory.
They indicate:

- ActiveMQ Classic `6.2.6`;
- PostgreSQL-backed JDBC persistence with a leased database locker;
- JAAS authentication;
- a per-destination dead-letter convention using a `DLQ.` prefix;
- OpenWire on `61616`;
- AMQP on `5672`;
- STOMP on `61613`;
- MQTT on `1883`;
- WebSocket messaging on `61614`;
- a 10,000 connection limit and 100 MiB maximum frame size;
- management through JMX, Jolokia, and Hawtio;
- Hawtio OIDC integration with Keycloak;
- nginx ingress with a shared wildcard certificate;
- Vault Agent Injector with TLS verification, Kubernetes auth roles, and
  pre-populated file templates; and
- Argo CD-managed Helm applications.

This does not prove which protocols or broker-specific features applications
actually use. Runtime connection metrics and application configuration must be
inventoried before production migration.

## 4. Target Architecture

### 4.1 Per EKS Cluster

Each EKS cluster receives:

- one ArkMQ Broker Operator deployment in a platform namespace;
- one three-member ZooKeeper ensemble in a platform namespace by default;
- one Argo CD application for the operator;
- one Argo CD application for ZooKeeper;
- one Argo CD application per Artemis workload namespace; and
- cluster-level monitoring and log forwarding integrations.

One ZooKeeper ensemble may coordinate multiple HA pairs. Every pair must use a
unique ZooKeeper namespace and a unique Artemis `coordination-id`. A dedicated
ZooKeeper ensemble remains a supported override for a workload requiring a
smaller failure blast radius.

Sharing ZooKeeper does not share message data. Each broker pair retains
independent journals, EBS volumes, credentials, policies, services, and
coordination identity.

### 4.2 Per Artemis Workload Namespace

Each promotion-grade deployment contains:

- two Artemis pods managed by the ArkMQ operator;
- one independent ReadWriteOnce EBS volume per broker pod;
- synchronous journal replication between broker peers;
- a pluggable ZooKeeper distributed lock manager;
- a stable internal client Service;
- a headless Service for peer discovery and replication;
- a TLS nginx Ingress for the Artemis/Hawtio console;
- a PodDisruptionBudget;
- required zone topology spread and pod anti-affinity;
- default-deny NetworkPolicies with explicit message, replication, management,
  monitoring, DNS, Vault, Keycloak, and ZooKeeper paths;
- Prometheus scrape resources and alert rules; and
- CloudWatch-compatible structured logs.

The two brokers use the same `coordination-id` and compete for activation. At
runtime exactly one broker is active and the other is passive. Both retain
separate AZ-scoped volumes. Shared EBS across availability zones is forbidden.

### 4.3 Message Flow

1. A producer connects to the stable internal Service.
2. The Service selects only the ready, active broker.
3. A durable send is written to the active journal and synchronously replicated.
4. The producer receives its acknowledgement only after the configured durable
   guarantees are satisfied.
5. Consumers receive messages using at-least-once delivery.
6. If a consumer disconnects before acknowledgement, the message is redelivered.
7. If the active broker fails, ZooKeeper permits only the eligible peer to
   activate.
8. Clients reconnect through their configured failover or retry policy.

## 5. Environment Strategy

### 5.1 Sandbox Profile

`sandbox` is an optional values profile for rendering, basic connectivity, and
developer iteration:

- one broker;
- no replication requirement;
- ZooKeeper may be disabled;
- small persistent or ephemeral storage;
- no HA, AZ-loss, upgrade, or durability claim; and
- never a promotion gate or a source of production sizing data.

The profile must be visibly labeled `haMode: none` and disabled by default.

### 5.2 Test

The `test` cluster is the first complete implementation of the production
topology:

- two brokers across distinct zones;
- three ZooKeeper members across three zones;
- one EBS volume per stateful pod;
- production-equivalent security, ingress, Vault, monitoring, and Argo CD flow;
- smaller resource requests and storage; and
- destructive validation enabled.

Suggested starting point:

| Component | Replicas | CPU request | Memory request | Storage |
| --- | ---: | ---: | ---: | ---: |
| Artemis | 2 | 500m | 2 GiB | 20 GiB gp3 |
| ZooKeeper | 3 | 250m | 1 GiB | 10 GiB gp3 |

### 5.3 Nonprod

`nonprod` is the release-candidate environment:

- identical topology and versions to the proposed production release;
- production-like queue policy and client compatibility tests;
- upgrade, rollback, credential rotation, node drain, and AZ disruption tests;
- representative sustained workload; and
- larger storage and resources than test.

Suggested starting point:

| Component | Replicas | CPU request | Memory request | Storage |
| --- | ---: | ---: | ---: | ---: |
| Artemis | 2 | 1 | 4 GiB | 50 GiB gp3 |
| ZooKeeper | 3 | 500m | 2 GiB | 20 GiB gp3 |

### 5.4 Prod

`prod` uses the same topology and tested artifact digests:

- two brokers across distinct zones;
- three ZooKeeper members across three zones;
- conservative PodDisruptionBudgets;
- production alerts and on-call runbooks;
- backups and volume snapshot policy supplied by the platform;
- automatic failover but controlled failback; and
- resources finalized from nonprod load results.

Suggested storage baseline is 100 GiB gp3 per broker and 20 GiB gp3 per
ZooKeeper member. Capacity is not an acceptance value. Final size, IOPS, and
throughput must be derived from message rate, message size, retention, paging,
replay, replication latency, and recovery-time measurements.

## 6. Open-Source Component Baseline

Candidate versions as of the specification date:

| Component | Candidate | Source | Policy |
| --- | --- | --- | --- |
| Apache Artemis | 2.55.0 | Apache | Pin compatible image digest |
| ArkMQ Broker Operator | 2.2.0 | ArkMQ, Apache-2.0 | Mirror OCI chart and images |
| Apache ZooKeeper | 3.9.5 | Apache | Pin official image digest |

The implementation must verify the operator/operand version matrix. If ArkMQ
`2.2.0` does not support Artemis `2.55.0`, select the newest explicitly
supported Artemis release rather than bypassing operator validation.

Do not depend on an unmaintained Bitnami OCI artifact or a commercial image
catalog. The ZooKeeper chart should be a small repository-owned Helm chart
derived from the current Kubernetes StatefulSet guidance and use the official
Apache ZooKeeper image mirrored to ECR.

## 7. Helm and Argo CD Layout

Expected repository structure:

```text
.
|-- argocd/
|   |-- applications/
|   `-- projects/
|-- charts/
|   |-- artemis-ha/
|   `-- zookeeper/
|-- images/
|   |-- artemis/
|   `-- test-client/
|-- environments/
|   |-- test/
|   |-- nonprod/
|   `-- prod/
|-- tests/
|   |-- chart/
|   |-- compatibility/
|   |-- e2e/
|   `-- load/
|-- scripts/
`-- docs/
```

Environment values contain only generic configuration and references. Argo CD
or the environment repository supplies:

- ECR registry and immutable digests;
- namespace and release name;
- Vault role and secret paths;
- ingress hostname and wildcard TLS Secret name;
- Keycloak issuer, realm, and client ID;
- storage class;
- Prometheus labels;
- CloudWatch log group metadata; and
- placement labels or tolerations.

The charts must support all nine namespaces through values without copying
templates.

## 8. Container Image Policy

### 8.1 Artemis

Prefer the upstream operator-compatible image without modification. Build a
thin derived image only when the ZooKeeper lock-manager libraries, trust
material handling, or required configuration bootstrap cannot be supplied
safely through the operator.

A derived image must:

- use an exact upstream version and digest;
- run as non-root;
- contain no credentials or environment names;
- include license and source attribution;
- expose an SBOM;
- pass vulnerability policy; and
- be mirrored and signed in ECR.

### 8.2 ZooKeeper

Use the official ZooKeeper image pinned by digest and mirrored into ECR.
Configuration is injected by ConfigMap and environment variables. Data and
transaction logs use persistent volumes.

### 8.3 Validation Client

Provide a small deterministic client image that can:

- send durable messages with monotonically increasing IDs;
- set `_AMQ_DUPL_ID`;
- wait for broker acknowledgement;
- consume with explicit acknowledgement;
- intentionally disconnect before acknowledgement;
- report missing, duplicated, reordered, and redelivered IDs; and
- exercise OpenWire and AMQP initially.

## 9. Artemis Configuration

### 9.1 HA

- Replication policy with ZooKeeper pluggable lock manager.
- Two competing primary configurations with the same `coordination-id`.
- Unique ZooKeeper namespace per HA pair.
- Synchronous durable journal writes and replication acknowledgement.
- Explicit replication timeouts.
- `allow-failback` disabled initially to avoid automatic second disruption.
- Manual, runbook-driven failback after the recovered peer is synchronized.
- Readiness must identify only an active broker as a client endpoint.
- Liveness must not cause restart loops during normal passive operation.

The implementation must prove that the operator can render and preserve this
configuration. If it cannot, document the exact limitation and implement the
smallest operator-compatible customization. A direct StatefulSet is a fallback
only after that evidence is recorded in an ADR.

### 9.2 Persistence

- Artemis file journal on gp3 EBS, not the legacy PostgreSQL JDBC store.
- One PVC per broker.
- One PVC per ZooKeeper member.
- `ReadWriteOnce` access.
- `WaitForFirstConsumer` storage binding expected from the cluster storage
  class.
- Durable sends and acknowledgements are flushed.
- Disk usage, paging thresholds, and minimum free space are configurable.
- Large-message and paging directories reside on persistent storage.

### 9.3 Protocol Compatibility

Phase one preserves the legacy listener set while actual usage is inventoried:

| Protocol | Port | Initial disposition |
| --- | ---: | --- |
| OpenWire | 61616 | Required migration interface |
| AMQP 1.0 | 5672 | Enabled and preferred for new integrations |
| STOMP | 61613 | Enabled internally until usage is disproved |
| MQTT | 1883 | Enabled internally until usage is disproved |
| WebSocket | 61614 | Enabled internally until usage is disproved |
| Console/Jolokia | 8161 | Cluster service plus TLS ingress |

All ports, protocols, connection limits, frame limits, and idle timeouts are
values-driven. No messaging protocol is publicly internet-facing.

Classic clients continue with OpenWire during the initial migration. Do not
combine the broker migration with a client-library and protocol migration.

### 9.4 Address and Queue Policy

The initial compatibility profile must represent:

- anycast queues for point-to-point traffic;
- multicast addresses for topics;
- durable queues;
- per-address dead-letter behavior compatible with the `DLQ.` convention where
  feasible;
- redelivery delay and maximum attempts as explicit values;
- expiry address behavior;
- paging and producer flow control;
- duplicate detection;
- queue and address auto-creation disabled in production unless explicitly
  approved; and
- declarative queue/address definitions in Git.

The following Classic behaviors require focused compatibility tests before
production:

- virtual topics;
- advisory consumers;
- destination wildcards;
- message groups;
- scheduled messages;
- durable topic subscriptions;
- selectors;
- XA transactions;
- temporary destinations; and
- broker-specific management APIs.

### 9.5 Client Connection Policy

The chart documents example connection settings for retry, reconnect, call
timeout, and topology discovery. Server-side failover does not guarantee that
an application retries safely.

Consumers must be idempotent. Producers should set a stable duplicate ID when a
business operation can be retried.

## 10. ZooKeeper Configuration

- Three voting members.
- Required zone spread across `topology.kubernetes.io/zone`.
- Required host anti-affinity.
- `maxUnavailable: 1` PodDisruptionBudget.
- Persistent data and transaction logs.
- Four-letter-word commands restricted to required health checks.
- Admin server disabled unless explicitly required.
- Prometheus metrics enabled.
- Network access restricted to Artemis brokers, monitoring, and DNS.
- TLS and authentication are configurable; production enablement is required
  if supported cleanly by the Artemis lock-manager client.
- Curator session timeout is configurable and coordinated with broker GC and
  cluster connection timeouts.

Initial failover target may use an 18-second ZooKeeper session timeout. It must
be tuned from measured GC pauses and network behavior. Faster values are not
automatically safer.

## 11. Vault Integration

The existing pattern is Vault Agent Injector with:

- `vault.hashicorp.com/agent-inject: "true"`;
- a Vault TLS Secret and CA file;
- `vault.hashicorp.com/agent-pre-populate-only: "true"`;
- a Kubernetes auth role derived from namespace and application name;
- one or more `agent-inject-secret-*` annotations; and
- `agent-inject-template-*` templates rendered below `/vault/secrets`.

The chart exposes these as structured values and renders no defaults containing
real paths. Example placeholders:

```yaml
vault:
  enabled: true
  role: example-messaging
  tlsSecretName: example-vault-tls
  caCertPath: /vault/tls/ca.crt
  secretPath: kubernetes/example/example-messaging
```

Vault should render:

- broker administrative credentials;
- application role credentials or JAAS properties;
- ZooKeeper credentials when enabled;
- truststore/keystore passwords; and
- optional TLS key material if not supplied by the ingress wildcard Secret.

The broker configuration references files, not secret values embedded into
environment variables or command lines.

## 12. Hawtio, Keycloak, and Ingress

- Use the Artemis console based on Hawtio rather than a separately licensed
  management product.
- Integrate with the existing Keycloak realm through Hawtio 4 generic OIDC.
- Keep client ID, issuer URI, redirect URI, scopes, and role mappings
  values-driven in `hawtio-oidc.properties`.
- Configure the Keycloak browser client as public with authorization code
  flow and PKCE `S256`; do not distribute a client secret to the browser or
  broker pod.
- Retain separate viewer and administrator roles.
- Route the console through `ingressClassName: nginx`.
- Terminate TLS at nginx using the environment wildcard certificate.
- Use `ssl-passthrough: "false"`.
- Make proxy connect, read, and send timeouts configurable.
- Restrict ingress by existing network and authentication controls.
- Keep Jolokia authorization rules least-privilege.
- Do not put Hawtio in the message path.

## 13. Observability

### 13.1 Prometheus

Export and alert on:

- broker active/passive state;
- replication connected and synchronized state;
- failover count and duration;
- queue depth, enqueue, dequeue, acknowledgement, expiry, and DLQ rates;
- unacknowledged and delivering messages;
- consumer count and blocked producers;
- paging and disk usage;
- JVM heap, GC pause, threads, and file descriptors;
- ZooKeeper quorum health, leader state, latency, outstanding requests, and
  session expirations; and
- operator reconciliation failures.

Provide `ServiceMonitor` or `PodMonitor` resources behind a feature flag.

### 13.2 CloudWatch

Emit structured stdout logs for collection by the cluster log agent. Values
must support environment, cluster, namespace, component, and broker identity
labels without hardcoding a log group.

CloudWatch alarms or dashboards may be supplied as optional examples; they are
not created through this Helm chart unless the cluster platform already uses a
supported Kubernetes-to-CloudWatch mechanism.

## 14. Security

- Non-root containers and read-only root filesystems where upstream images
  permit.
- Drop Linux capabilities and disable privilege escalation.
- Default seccomp profile.
- Explicit service accounts; no AWS API access unless justified.
- Default-deny ingress and egress NetworkPolicies.
- TLS for console ingress and messaging interfaces where clients support it.
- Secret values only from Vault or referenced Kubernetes Secrets.
- Images and charts mirrored to ECR, scanned, signed, and pinned.
- No public LoadBalancer for broker protocols.
- RBAC scoped to operator requirements.
- Audit logging enabled without message bodies or credentials.

## 15. Scheduling and Disruption

- Broker pods require different availability zones.
- ZooKeeper pods require different availability zones and nodes.
- PodDisruptionBudgets protect one active Artemis service and ZooKeeper quorum.
- Argo CD sync waves install CRDs/operator, ZooKeeper, broker, and validation in
  dependency order.
- Stateful workloads use conservative rolling updates.
- Cluster Autoscaler/Karpenter behavior must preserve capacity in required
  zones.
- Planned broker restarts should fail over one peer at a time.

## 16. Validation Strategy

### 16.1 Root Claims

The validation suite exists to prove four claims:

1. **Safety:** no split brain and no loss of acknowledged durable messages.
2. **Liveness:** an eligible peer activates and client service recovers within
   the agreed recovery target.
3. **Compatibility:** existing clients and required Classic semantics behave
   acceptably against Artemis.
4. **Operability:** GitOps upgrades, rollback, secret rotation, monitoring, and
   routine maintenance do not corrupt data or produce an uncontrolled outage.

The `100,000` message count is a repeatable test fixture, not the claim.

### 16.2 Delivery Semantics

- Target RPO for acknowledged durable messages: zero.
- In-flight or unacknowledged messages may be redelivered.
- Delivery contract: at least once.
- Consumers must tolerate duplicates.
- Test output distinguishes lost, duplicated, redelivered, and unacknowledged
  messages.

### 16.3 Required Automated Scenarios

1. Chart lint, render, JSON schema, and Kubernetes schema validation.
2. Clean install and idempotent Argo CD resync.
3. OpenWire and AMQP send/consume compatibility.
4. Durable backlog of at least 100,000 sequenced messages.
5. Active broker process kill during production.
6. Active broker pod deletion during production and consumption.
7. Active broker node drain.
8. Loss of the active broker availability zone.
9. Loss of one ZooKeeper member.
10. ZooKeeper quorum loss without dual broker activation.
11. Broker-to-broker replication network interruption.
12. Broker-to-ZooKeeper network interruption.
13. Consumer death before acknowledgement and message redelivery.
14. Producer timeout after broker commit and duplicate retry.
15. EBS detach/reschedule behavior.
16. Helm/operator/Artemis upgrade through Argo CD.
17. Failed upgrade rollback.
18. Vault credential rotation and pod restart.
19. Keycloak login and Hawtio viewer/admin authorization.
20. Queue browse, move, retry, purge, and DLQ management.
21. Sustained and burst load with replication enabled.
22. Broker recovery and safe manual failback.

### 16.4 Initial Acceptance Criteria

- Exactly one active broker throughout every isolation scenario.
- No missing IDs among broker-acknowledged durable sends.
- Redeliveries are observable and duplicates are reported.
- Client endpoint recovers within 30 seconds as an initial target.
- ZooKeeper remains writable after one member loss.
- Loss of ZooKeeper quorum does not cause two active brokers.
- Argo CD returns to `Synced` and `Healthy`.
- Hawtio requires Keycloak authentication and enforces roles.
- No credential appears in rendered manifests, pod specs, or logs.
- Prometheus and CloudWatch expose enough evidence to diagnose each failure.

The 30-second target is provisional. Test results may justify a different SLO.

## 17. Upgrade and Promotion

1. Mirror candidate images and charts into ECR.
2. Record source version, digest, license, SBOM, and scan result.
3. Update the test environment digest.
4. Run all functional and destructive tests.
5. Promote the exact digests to nonprod.
6. Run production-like load, upgrade, rollback, and failure tests.
7. Obtain operational approval.
8. Promote the exact digests to prod.
9. Upgrade one HA pair or namespace at a time.
10. Observe replication, queue, client, and ZooKeeper health before continuing.

ZooKeeper upgrades occur test, then nonprod, then prod, one member at a time.

## 18. Migration From ActiveMQ Classic

### Phase 1: Inventory

- Export sanitized broker configuration.
- Enumerate destinations and runtime protocol connections.
- Identify client library versions and connection URLs.
- Identify Classic-only features.
- Record message size, rate, retention, backlog, and peak concurrency.

### Phase 2: Compatibility

- Configure equivalent Artemis addresses and queues.
- Run existing clients against Artemis using OpenWire.
- Compare DLQ, selectors, redelivery, transactions, scheduled messages, message
  groups, and durable subscriptions.
- Record intentional semantic differences.

### Phase 3: Parallel Validation

- Mirror representative traffic or replay sanitized messages.
- Compare throughput and end-to-end results.
- Exercise failover and rollback.

### Phase 4: Cutover

- Quiesce or bridge producers according to the approved migration runbook.
- Drain or migrate the remaining Classic backlog.
- Change connection endpoints.
- Validate sequence and business counts.
- Retain a time-bounded rollback path.

### Phase 5: Modernization

- Move suitable integrations from OpenWire to AMQP 1.0.
- Remove unused protocol listeners.
- Replace Classic-specific destination conventions where justified.

## 19. Deliverables

- Repository-owned Helm charts for Artemis and ZooKeeper.
- Argo CD application examples for three clusters and nine namespaces.
- Generic test, nonprod, prod, and sandbox values.
- Optional thin Artemis image definition if required.
- Deterministic validation client image.
- Chart and schema tests.
- EKS failure and compatibility test harness.
- Prometheus rules and dashboard examples.
- CloudWatch logging guidance.
- Operations, upgrade, failover, failback, backup, restore, and migration
  runbooks.
- Architecture decision records for operator use, ZooKeeper sharing, EBS
  persistence, and protocol migration.

## 20. Deferred Environment Inputs

These do not block a generic implementation:

- actual cluster and namespace names;
- ECR registry and promotion repositories;
- storage class name and available zone labels;
- Vault role and secret paths;
- wildcard TLS Secret names;
- Keycloak issuer, realm, client, scopes, and role mappings;
- Prometheus release labels;
- CloudWatch log destination;
- concrete ingress hostnames;
- final resource limits;
- client protocol usage inventory; and
- final RTO, throughput, latency, and retention SLOs.

## 21. Upstream References

- Apache Artemis HA:
  https://artemis.apache.org/components/artemis/documentation/latest/ha.html
- Apache Artemis network isolation:
  https://artemis.apache.org/components/artemis/documentation/latest/network-isolation.html
- Apache Artemis protocols:
  https://artemis.apache.org/components/artemis/documentation/latest/protocols-interoperability.html
- Apache Artemis current release:
  https://artemis.apache.org/components/artemis/download/
- ArkMQ operator:
  https://arkmq.org/docs/getting-started/quick-start/
- ArkMQ operator configuration:
  https://arkmq.org/docs/help/operator/
- Hawtio generic OIDC:
  https://hawt.io/docs/oidc.html
- Kubernetes ZooKeeper StatefulSet guidance:
  https://kubernetes.io/docs/tutorials/stateful-application/zookeeper/
- Apache ZooKeeper releases:
  https://zookeeper.apache.org/releases/
