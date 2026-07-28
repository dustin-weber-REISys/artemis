# Environment import and deployment walkthrough

Status: environment integration guide  
Applies to: `test`, `nonprod`, and `prod`  
Does not make `sandbox` promotion-grade

## 1. What this repository imports

This repository is a generic deployment baseline, not a complete AWS account
bootstrap. Importing it into the deployment system creates, through Argo CD:

- one ArkMQ Broker Operator Application per EKS cluster;
- one shared three-member ZooKeeper Application per EKS cluster by default;
  and
- one Artemis HA Application per named application environment, for ten
  workload Applications total.

Each Artemis Application creates an operator-managed, two-broker,
competing-primary HA pair in its own namespace. Each broker has its own EBS
volume. The pair shares a unique ZooKeeper lock path, while all pairs in one
EKS cluster normally use the same ZooKeeper ensemble.

| EKS cluster | Application environments | HA pairs | Broker pods |
| --- | --- | ---: | ---: |
| `TEST` | `SKY`, `SKY2` | 2 | 4 |
| `Nonprod` | `smktest` (`EUT`), `TRN`, `TRN2`, `PT` | 4 | 8 |
| `Prod` | `PE`, `PP`, `DM`, `PR` | 4 | 8 |
| **Total** | **10** | **10** | **20** |

An environment may use the same queue names as another environment because
each HA pair is an independent Artemis server namespace. The pairs do not
share journals, PVCs, services, credentials, authorization policies, queue
catalogs, or coordination identities. Clients must use the Service and
credentials for the intended environment, and no cross-pair cluster
connection, federation, or bridge is assumed.

The repository does **not** create:

- EKS clusters, VPCs, subnets, node groups, Karpenter capacity, or security
  groups;
- ECR repositories, KMS keys, ECR lifecycle policies, or image-signing keys;
- the EBS CSI driver, gp3 StorageClasses, VolumeSnapshotClasses, or backup
  policies;
- Argo CD itself, its cluster registrations, Git credentials, or ECR OCI
  repository credentials;
- Vault, Vault Kubernetes auth configuration, or the Vault Agent Injector;
- nginx ingress, wildcard certificates, DNS records, or external load
  balancers;
- Keycloak realms, clients, role mappings, or users;
- Prometheus Operator or CloudWatch log collection;
- application queues, application credentials, or client connection changes;
  or
- a Kubernetes Job for the validation client.

Do not apply the repository with its supplied placeholders. Several placeholder
values are syntactically valid and will pass Helm rendering even though they
cannot work in a real environment.

## 2. Runtime shape and ownership

```text
Argo CD control plane
  |
  +-- TEST EKS
  |    +-- platform namespace
  |    |    +-- ArkMQ operator
  |    |    `-- ZooKeeper 0/1/2, each with a separate EBS PVC
  |    +-- SKY namespace: Artemis 0/1, separate EBS PVCs
  |    `-- SKY2 namespace: Artemis 0/1, separate EBS PVCs
  |
  +-- Nonprod EKS
  |    +-- shared operator and ZooKeeper 0/1/2
  |    `-- smktest (EUT), TRN, TRN2, PT: one Artemis 0/1 pair each
  |
  `-- Prod EKS
       +-- shared operator and ZooKeeper 0/1/2 by default
       `-- PE, PP, DM, PR: one Artemis 0/1 pair each
```

For `PR`, dedicated broker node placement and a dedicated ZooKeeper ensemble
are the recommended stronger isolation option within `Prod`; Section 7.6
distinguishes that option from hard isolation in a separate EKS cluster.

Responsibility boundaries:

| Layer | Owner | Source of truth |
| --- | --- | --- |
| AWS account, network, EKS, IAM, EBS CSI, KMS | AWS/platform team | Existing infrastructure repository |
| ECR repositories and artifact evidence | supply-chain/platform team | ECR plus build evidence store |
| Argo CD registration and repository credentials | GitOps platform team | Argo CD control-plane configuration |
| Kubernetes runtime resources | Argo CD and ArkMQ operator | This repository plus environment values |
| Secret values and Vault policies | security/platform team | Vault and Vault configuration repository |
| Keycloak client and roles | identity team | Keycloak configuration |
| Queues, client identities, compatibility, and cutover | application owners | Approved messaging/application configuration |
| Monitoring, logs, alarms, and backups | operations/platform team | Cluster observability and backup configuration |

## 3. Information to collect before changing files

Create an input worksheet containing the following. Use secret references, not
secret values.

### 3.1 Global inputs

| Input | Example format | Used by |
| --- | --- | --- |
| GitOps repository URL | `https://git.example/reigroup/artemis-gitops.git` | AppProject and all ApplicationSets |
| Git revision | immutable commit, release branch, or approved tag | all Applications |
| Argo CD namespace | commonly `argocd` | AppProject and ApplicationSets |
| Argo CD project name | currently `messaging-platform` | all Applications |
| Platform namespace | for example `messaging-platform` | operator and ZooKeeper |
| AWS account ID and region | account plus `us-east-1` | ECR and AWS prerequisites |
| ECR registry | `<account>.dkr.ecr.<region>.amazonaws.com` | operator chart and every image |
| ECR repository prefix | for example `platform/messaging` | image and chart references |
| Mirrored ArkMQ chart name | OCI repository/chart path | operator ApplicationSet |

### 3.2 Inputs for each environment

Collect these separately for `test`, `nonprod`, and `prod`:

| Input | Requirement |
| --- | --- |
| EKS cluster name | Exact platform name used in namespace labels and change records |
| EKS API server | Exact server URL used by the Argo CD cluster registration |
| Argo CD destination identity | The registered cluster server URL must match the Application destination |
| Workload namespaces | Supply one unique namespace for every application environment assigned to the cluster |
| StorageClass | gp3-compatible, encrypted, `WaitForFirstConsumer`, `ReadWriteOnce` |
| Available zones | At least three schedulable zones for ZooKeeper and two for each broker pair |
| Node labels and taints | Values for broker/ZooKeeper placement, selectors, and tolerations |
| Ingress class | Normally `nginx`, but verify the installed class name |
| Ingress namespace and pod labels | Must match the Artemis NetworkPolicy selectors |
| DNS zone and console hostnames | One unique console hostname per workload |
| Wildcard TLS Secret name | The Secret must exist in every workload namespace |
| Keycloak issuer and realm | Full HTTPS issuer URL |
| Keycloak public client IDs | Prefer one client per environment or workload according to identity policy |
| Keycloak redirect URIs | Must exactly cover each workload console URL |
| Keycloak viewer/admin roles | Must match token claims and chart role mappings |
| Keycloak namespace, pod labels, and port | Required by NetworkPolicy when Keycloak is in-cluster |
| Vault Kubernetes auth mount | Used when creating Vault roles outside this repository |
| Vault namespace, service labels, and port | Required by NetworkPolicy when Vault is in-cluster |
| Vault CA Secret and CA file path | The Secret must be available in every workload namespace |
| Prometheus namespace, pod labels, and release label | Required by NetworkPolicy and ServiceMonitor selection |
| CloudWatch destination and retention | Configured in the cluster log agent, not this chart |
| Resource requests and limits | Finalized from test/nonprod load evidence |
| EBS volume sizes, IOPS, and throughput | Derived from rate, size, retention, paging, and recovery tests |
| Snapshot policy, retention, and KMS key | External AWS backup configuration |

### 3.3 Inputs for every workload

These values must be unique or explicitly approved for each of the ten
workloads:

| Input | Rules |
| --- | --- |
| `workloadKey` | Stable, DNS-safe deployment identity |
| `workloadNamespace` | Unique Kubernetes namespace |
| `ha.coordinationId` | Same for the two peers, unique across pairs, 8-16 characters |
| `ha.groupName` | Stable Artemis HA group identity |
| `ha.clusterName` | Stable logical Artemis cluster name; do not leave `my-cluster` |
| `zookeeper.curatorNamespace` | Unique path such as `artemis/test/orders-a`; never reuse it for another pair |
| Console hostname | Unique hostname; workloads in one EKS cluster cannot share the cluster default safely |
| Keycloak redirect URI/client | Must match the workload console |
| Vault role | Bound to the workload namespace and broker service account |
| Vault secret path | Separate path per workload unless shared credentials are an explicit decision |
| Allowed client namespaces/pods | Populate `networkPolicy.clientSources` |
| Management and monitoring selectors | Match actual namespace and pod labels |
| Queue/address policy | Derived from the Classic inventory and committed declaratively |
| Broker credential consumers | Administrative user and each application role/client |
| Capacity and alert overrides | Only when the workload differs from its environment baseline |

## 4. Tools required

### 4.1 Repository and CI validation

| Tool | Why it is needed |
| --- | --- |
| Git and GNU Make | repository workflow |
| Bash | validation and EKS scenario scripts |
| `rg` | static scans used by the repository |
| Helm 3 | chart linting, rendering, packaging, and pulling the operator chart |
| `kubeconform` | rendered Kubernetes schema checks |
| `yq` v4 | scenario validation and CRD extraction; the baseline records v4.53.3 |
| `curl` | pinned ArkMQ manifest download and console checks |
| Java 17 and Maven | validation-client unit tests and package |
| Docker with Compose v2 | optional local broker and smoke test |

`make validate` also downloads the checksum-pinned ArkMQ 2.2.0 manifest and
operator chart unless `ARKMQ_OPERATOR_MANIFEST_URL` and
`ARKMQ_OPERATOR_CHART` point to approved internal mirrors. CI therefore needs
network access to the selected sources.

### 4.2 AWS and cluster operations

| Tool | Why it is needed |
| --- | --- |
| AWS CLI v2 | EKS context creation, ECR login, and AWS preflight checks |
| `kubectl` | install verification and destructive EKS scenarios |
| Argo CD CLI | status, sync, and rollback scenarios |
| OCI copy client such as `crane` or `skopeo` | exact image/chart mirroring |
| `cosign` | signing and signature verification |
| `syft` plus the approved vulnerability scanner | SBOM and scan evidence |

The repository does not prescribe a particular mirroring, signing, or scanning
product. The importing organization must select and automate those tools.

## 5. AWS and EKS prerequisites

Complete this section before Argo CD is allowed to sync workloads.

### 5.1 Cluster capacity and placement

1. Confirm Kubernetes and ArkMQ 2.2.0 compatibility.
2. Confirm nodes are schedulable in at least three availability zones.
3. Confirm every node has
   `topology.kubernetes.io/zone` and `kubernetes.io/hostname`.
4. Reserve enough simultaneous capacity for three ZooKeeper members and both
   broker peers. A required zone-spread rule intentionally leaves pods Pending
   instead of collapsing them into one zone.
5. If nodes are tainted or dedicated, add matching `nodeSelector` and
   `tolerations` values. Validate Karpenter or Cluster Autoscaler behavior in
   every required zone.

### 5.2 EBS

1. Install and verify the AWS EBS CSI driver using its own approved IAM role.
   Artemis and ZooKeeper service accounts do not need AWS API permissions.
2. Create or identify an encrypted gp3-compatible StorageClass.
3. Require `volumeBindingMode: WaitForFirstConsumer`; otherwise a volume can be
   allocated in a zone before the pod is scheduled.
4. Set the reclaim policy according to the data-retention standard. Production
   should not delete broker data merely because an Argo Application is pruned.
5. Grant the EBS CSI role access to the selected KMS key.
6. Define VolumeSnapshotClass/AWS Backup behavior, retention, restore account,
   and cross-region policy outside this repository.
7. Test restore into an isolated namespace with a new coordination ID. Never
   attach one restored broker volume to two broker identities.

### 5.3 ECR and network access

Create repositories for at least:

- the ArkMQ operator OCI chart;
- the ArkMQ operator image;
- `activemq-artemis-broker-kubernetes`;
- `activemq-artemis-broker-init`;
- `zookeeper`; and
- the deterministic validation client.

Configure lifecycle and immutability policies so promoted digests cannot be
silently overwritten. EKS node roles, Fargate profiles, or configured
`imagePullSecrets` must be able to pull the images. Argo CD repo-server must
have a repository credential capable of reading the private operator OCI
chart.

For private clusters, verify the required NAT path or VPC endpoints for ECR
API, ECR Docker, S3, STS when used, CloudWatch Logs, and any other platform
service. Also verify private DNS and security-group/NACL behavior.

### 5.4 Cluster add-ons

Verify all of the following before bootstrap:

- Argo CD and ApplicationSet controller;
- nginx ingress controller;
- Vault Agent Injector and its mutation webhook;
- Prometheus Operator CRDs when `ServiceMonitor` and `PrometheusRule` are
  enabled;
- a NetworkPolicy-enforcing CNI;
- CoreDNS labels matching the chart's `kube-system`/`k8s-app=kube-dns`
  selectors, or corresponding policy overrides; and
- the cluster's CloudWatch-compatible stdout log collector.

If Vault, Keycloak, DNS, or monitoring uses an external endpoint rather than
pods selected by the chart, add precise `networkPolicy.extraEgress` rules. The
default pod selectors will not admit an external IP automatically.

## 6. Mirror and promote artifacts

Do not update environment values until all artifact evidence is recorded.

| Artifact | Repository baseline | File to update |
| --- | --- | --- |
| ArkMQ operator chart | `2.2.0` | operator ApplicationSet chart/revision |
| ArkMQ operator image | `2.2.0`, current overlay digest embedded in tag | all `operator-values.yaml` files |
| Artemis broker Kubernetes image | `2.53.0`, pinned digest in base values | `images.broker.repository`; digest only if the verified mirror differs |
| Artemis broker init image | `2.53.0`, pinned digest in base values | `images.init.repository`; digest only if the verified mirror differs |
| ZooKeeper image | Docker Official Image `docker.io/library/zookeeper:3.9.5` | replace the all-zero digest and ECR placeholders |
| Validation client | repository-owned build | build, scan, sign, push, and record its new digest |

For each artifact:

1. Copy the exact upstream version into ECR.
2. Resolve and record the destination digest.
3. Store source version, source digest, destination digest, licenses, SBOM,
   vulnerability result, signature, build provenance, and approval.
4. Verify the target architecture matches the EKS nodes.
5. For the broker image, verify
   `org.apache.activemq.artemis.lockmanager.zookeeper.CuratorDistributedLockManager`
   is present.
6. For the operator, verify the 2.2.0 operand matrix supports Artemis 2.53.0.
7. Promote the exact approved digests from test to nonprod to prod. Do not
   rebuild an artifact between environments.

The production validation-client Dockerfile requires immutable Maven builder
and Temurin runtime digests:

```sh
make build-image \
  BUILD_IMAGE_DIGEST=sha256:APPROVED_MAVEN_DIGEST \
  RUNTIME_IMAGE_DIGEST=sha256:APPROVED_TEMURIN_DIGEST \
  IMAGE=ECR_REGISTRY/ECR_REPOSITORY/validation-client:RELEASE
```

The local image in `compose.yaml` is a developer-only artifact and is not part
of the EKS promotion set.

## 7. Change the repository configuration

Keep generic chart defaults generic. Put shared environment settings in
`environments/<environment>`, and put workload-specific settings in the
ApplicationSet generator/parameters or separate workload overlays.

### 7.1 AppProject

Update `argocd/projects/messaging-platform.yaml`:

- `metadata.namespace`;
- Git repository and ECR entries under `sourceRepos`;
- platform and workload destination namespaces; and
- the exact registered EKS API server for each destination.

Review the broad `namespaceResourceWhitelist`. Narrow it if platform policy
requires, but retain every namespaced kind rendered by the charts and operator.

### 7.2 Operator ApplicationSet

Update `argocd/applications/operator-applicationset.yaml`:

- Argo CD namespace;
- three EKS cluster names and API servers;
- platform namespace;
- ECR OCI registry and mirrored chart name;
- Git repository URL; and
- an approved Git revision instead of a floating branch when required.

Update all three `environments/*/operator-values.yaml` files with:

- the operator image ECR repository and verified digest;
- broker-init ECR repository and verified digest;
- broker Kubernetes image ECR repository and verified digest;
- operator watch scope; and
- CRD ownership policy.

`clusterScoped: true` and `watchNamespaces: []` mean one cluster-wide operator
watches all namespaces. Changing this is an architecture and RBAC decision,
not a simple naming change.

### 7.3 ZooKeeper ApplicationSet and overlays

Update `argocd/applications/zookeeper-applicationset.yaml` with the Argo CD
namespace, Git URL/revision, cluster endpoints, and platform namespace.

For every `environments/*/zookeeper-values.yaml`, replace:

- ECR registry and repository;
- the all-zero ZooKeeper digest;
- environment StorageClass;
- EKS cluster label used by the broker namespace selector;
- monitoring namespace and actual Prometheus pod selector; and
- Prometheus release labels.

Decide whether ZooKeeper client TLS and SASL are required. If enabled:

- create `tls.client.secretName` in the platform namespace with
  `keystore.jks`, `truststore.jks`, and the configured password keys;
- create `authentication.jaasSecretName` with the configured `jaas.conf`; and
- configure the Artemis Curator client with matching TLS/authentication
  properties. Enabling only the ZooKeeper server side will break broker
  coordination.

The ZooKeeper ApplicationSet explicitly keeps the Helm release name equal to
the generated Argo CD Application name:

```text
<environment>-shared-zookeeper
```

The chart therefore creates this client Service:

```text
<environment>-shared-zookeeper-zookeeper-client
```

Every Artemis `zookeeper.connectString` derives that exact Service in the
platform namespace. Keep the Application name, Helm release name, and endpoint
template aligned if the naming convention changes.

### 7.4 Artemis environment overlays

The current `environments/*/artemis-values.yaml` files override only image
repositories, resources, storage size/class, console host, and redirect URI.
They still inherit example values for Keycloak, Vault, TLS, network policy,
HA cluster name, and monitoring.

At minimum, each effective workload configuration must override:

```yaml
images:
  broker:
    repository: ECR_REGISTRY/ECR_REPOSITORY/activemq-artemis-broker-kubernetes
  init:
    repository: ECR_REGISTRY/ECR_REPOSITORY/activemq-artemis-broker-init

ha:
  clusterName: WORKLOAD_LOGICAL_CLUSTER

persistence:
  storageClassName: ENVIRONMENT_GP3_STORAGE_CLASS

console:
  ingress:
    className: nginx
    host: WORKLOAD_UNIQUE_CONSOLE_HOST
    tlsSecretName: WORKLOAD_NAMESPACE_TLS_SECRET

keycloak:
  issuerUrl: https://KEYCLOAK/realms/REALM
  clientId: WORKLOAD_OR_ENVIRONMENT_PUBLIC_CLIENT
  redirectUri: https://WORKLOAD_UNIQUE_CONSOLE_HOST/console
  viewerRole: MESSAGING_VIEWER_ROLE
  administratorRole: MESSAGING_ADMIN_ROLE
  namespace: KEYCLOAK_NAMESPACE
  podSelector:
    ACTUAL_LABEL_KEY: ACTUAL_LABEL_VALUE

vault:
  role: WORKLOAD_VAULT_ROLE
  tlsSecretName: VAULT_CA_SECRET_IN_WORKLOAD_NAMESPACE
  caCertPath: /vault/tls/ca.crt
  secretPath: VAULT_KV_PATH
  namespace: VAULT_NAMESPACE
  podSelector:
    ACTUAL_LABEL_KEY: ACTUAL_LABEL_VALUE

networkPolicy:
  clientSources:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: APPROVED_CLIENT_NAMESPACE
      podSelector:
        matchLabels:
          ACTUAL_CLIENT_LABEL: ACTUAL_VALUE
  managementSources:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ACTUAL_INGRESS_NAMESPACE
      podSelector:
        matchLabels:
          ACTUAL_INGRESS_LABEL: ACTUAL_VALUE
  monitoringSources:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ACTUAL_MONITORING_NAMESPACE
      podSelector:
        matchLabels:
          ACTUAL_PROMETHEUS_LABEL: ACTUAL_VALUE

monitoring:
  serviceMonitor:
    labels:
      release: ACTUAL_PROMETHEUS_RELEASE
  prometheusRule:
    labels:
      release: ACTUAL_PROMETHEUS_RELEASE
```

Also review:

- enabled protocol listeners and ports;
- TLS for messaging acceptors;
- maximum connections and protocol frame limits;
- journal type;
- global and per-address memory/paging limits;
- disk threshold, duplicate cache, redelivery, DLQ, and expiry behavior;
- automatic address/queue creation;
- topology labels, taints, and tolerations;
- ServiceMonitor namespace and exporter metric names; and
- alert thresholds and severities.

Do not enable `ASYNCIO` until the exact image and node kernel support are
verified. Keep `automaticFailback: false` until the failback runbook has passed.

#### 7.4.1 Queue creation and dead-letter policy

Promoted environments use two different lifecycle policies:

- permanent application addresses and queues are declared through GitOps;
- per-source dead-letter queues are created by Artemis when they are first
  needed and are retained for operational triage.

The chart defaults implement the dead-letter policy without permitting an
application producer or consumer to create an arbitrary permanent queue:

```yaml
brokerProperties:
  addressSettings:
    deadLetterAddress: DLA
    autoCreateDeadLetterResources: true
    deadLetterQueuePrefix: "DLQ."
    deadLetterQueueSuffix: ""
    autoDeleteQueues: false
    autoDeleteAddresses: false
    autoCreateQueues: false
    autoCreateAddresses: false
```

The dead-letter address is an internal routing resource. Artemis creates a
separate filtered `DLQ.<source-address>` queue when the first message from that
source exceeds `maxDeliveryAttempts`. It records the original address and
queue metadata on the message for browsing, replay, and audit. Creating or
connecting a producer or consumer does not create the source queue under the
promoted defaults; deploy the source address and queue before the application.

For an isolated environment test only, set both application auto-creation
controls to `true`. Verify creation from a producer and consumer, restart and
HA persistence, multiple independent source/DLQ pairs, redelivery exhaustion,
retention, Hawtio/ELP visibility, and replay. Restore both controls to `false`
before promotion. Changing them back does not itself delete resources already
created; cleanup must be explicit and evidence-preserving.

Message expiry is a separate, disabled-by-default policy. The dormant
`brokerProperties.addressSettings.expiry` values retain the intended
`ExpiryQueue` address, automatic resource creation, and `EXP.` per-source queue
prefix. Setting only `expiry.enabled: true` renders the complete expiry
configuration. Until that switch is enabled, the chart does not render an
expiry address or expiry-resource settings, and no broker-wide expiry delay is
configured.

### 7.5 Workload-specific ApplicationSet values

The current matrix generator supplies each EKS cluster's environment, cluster
name, and API server once. Its workload list supplies the workload key,
namespace, and explicit coordination ID; the template derives unique HA group
names, logical broker cluster names, and Curator paths. Workloads generated for
the same EKS cluster still inherit one console hostname and the example Vault
configuration. That is not a deployable final state.

Add workload fields such as:

```yaml
- workloadKey: test-sky
  workloadNamespace: PLACEHOLDER_TEST_NAMESPACE_SKY
  coordinationId: test-sky-01
  consoleHost: artemis-sky.example.com
  tlsSecretName: wildcard-example-com
  keycloakClientId: artemis-sky
  vaultRole: sky-artemis
  vaultSecretPath: kubernetes/test/sky/artemis
```

Pass them as Helm parameters or use one additional workload-specific values
file. At minimum add parameters for:

```text
console.ingress.host
console.ingress.tlsSecretName
keycloak.clientId
keycloak.redirectUri
vault.role
vault.secretPath
```

If client NetworkPolicy selectors or resource sizing differ per workload, use
a workload values file because nested selector arrays are awkward and
error-prone as Helm command-line parameters.

The workload ApplicationSet is the sole source of Artemis Applications; do not
add a standalone Application for a workload already generated by it.

### 7.6 PR isolation choices

The baseline already isolates `PR` message data from `PE`, `PP`, and `DM`:
`PR` has its own Artemis HA pair, journals, PVCs, namespace, Service,
credentials, Vault path, authorization policy, queue catalog, console
identity, and unique coordination ID and Curator namespace.

Within the existing `Prod` EKS cluster, the recommended stronger option is:

- schedule the two `PR` broker pods on dedicated nodes using approved labels,
  taints, and tolerations while preserving cross-zone anti-affinity;
- deploy a dedicated three-member ZooKeeper release for `PR`, with separate
  PVCs, Service, PDB, NetworkPolicies, monitoring, and maintenance lifecycle;
- restrict `PR` NetworkPolicies to approved clients and platform services;
- apply quotas to `PE`, `PP`, and `DM` and an appropriate priority class to
  `PR`; and
- leave cluster connections, federation, and bridges between the four
  production pairs disabled unless separately approved.

This reduces capacity and coordination coupling, but `PR` still shares the EKS
control plane, cluster networking, cluster-wide capacity, and upgrade events.
Do not describe dedicated nodes or dedicated ZooKeeper as EKS-level isolation.

If `PR` must remain available through those entire-cluster failures, use a
separate EKS cluster with its own Argo CD registration, operator, ZooKeeper
ensemble, node capacity, platform integrations, and observability. That is the
hard-isolation option and requires explicit infrastructure, security, and
operational approval; importing this repository does not create or mandate it.

## 8. Vault: what must be loaded

### 8.1 Vault platform objects

For every workload:

1. Enable/configure the Kubernetes auth mount for the target EKS cluster.
2. Create a Vault policy granting read access only to that workload's paths.
3. Create a Vault role bound to:
   - the exact broker service account name;
   - the exact workload namespace; and
   - the workload policy.
4. Make the Vault CA Kubernetes Secret available in the workload namespace.
5. Confirm the chart's Vault namespace, pod selector, and port select the
   actual Vault endpoint, or add the correct external egress rule.

Unless `fullnameOverride` or a custom service-account name is used, the chart's
service account is `<helm-release>-artemis-ha`. Render the chart to confirm the
exact name before creating the Vault role.

The chart currently sets
`security.serviceAccount.automountServiceAccountToken: false`. Confirm that the
installed Vault injector supplies a projected Kubernetes auth token through
your platform's supported pattern. If it does not, add a narrowly scoped
projected token volume/injector annotation before deployment. Vault login will
otherwise fail even if the role and policy are correct.

### 8.2 Secret data inventory

Recommended logical Vault entries:

| Secret set | Minimum data | Consumer |
| --- | --- | --- |
| Broker administration | `username`, `password` | readiness/Jolokia and authorized administrators |
| Application identities | username/password or JAAS/user-role properties per approved client | producer and consumer applications |
| Broker authorization | user-to-role and role-to-permission data | Artemis security configuration |
| Messaging TLS | keystore/truststore material and passwords when acceptor TLS is enabled | Artemis broker and clients |
| ZooKeeper client identity | JAAS/TLS identity and passwords if ZooKeeper auth/TLS is enabled | Artemis Curator client |
| ZooKeeper server identity | server/quorum stores, JAAS, and passwords if enabled | ZooKeeper pods |
| Optional console trust | private CA/trust material when Keycloak is privately issued | Hawtio/JVM |

Keycloak is configured as a public browser client with PKCE, so a Keycloak
client secret should not be loaded into the broker pod.

The current default Vault KV template expects this data shape at
`vault.secretPath`:

```yaml
data:
  username: BROKER_ADMIN_USERNAME
  password: BROKER_ADMIN_PASSWORD
```

It renders:

```text
/vault/secrets/broker-credentials.properties
```

with `username=` and `password=` properties. The template's literal path inside
`vault.templates.brokerCredentials` must be changed whenever
`vault.secretPath` changes; changing only `secretPath` leaves the template
reading the example path.

### 8.3 Required authentication integration decision

The current chart injects the broker credential file, but it does **not** wire
that file into the operator's literal `adminUser`/`adminPassword` fields or
Artemis JAAS configuration. With `broker.requireLogin: true`, the operator can
still generate its own admin Secret. Therefore Vault injection annotations
alone do not prove that Artemis is using the Vault credentials.

Before production, implement and test one approved bridge:

- a platform secret-sync controller that creates the exact Kubernetes Secret
  shape consumed by the operator;
- an operator-supported mounted Secret/JAAS configuration; or
- a minimal, reviewed broker bootstrap integration that reads the injected
  files.

The bridge must support rotation without placing secret values in Git,
rendered manifests, Argo CD parameters, shell history, or logs. Update the
readiness probe to use the same effective administrative identity and test the
`vault-credential-rotation` scenario.

ZooKeeper's chart also consumes Kubernetes Secret references directly; it does
not contain Vault Agent annotations. If ZooKeeper TLS/SASL is enabled, the
environment platform must materialize those Kubernetes Secrets from Vault or
another approved source.

## 9. Keycloak, TLS, and DNS

For each console:

1. Create a public OIDC client.
2. Enable authorization code flow and PKCE `S256`.
3. Register the exact HTTPS redirect URI rendered by the workload.
4. Put viewer and administrator roles in the token path configured by
   `keycloak.rolesPath`.
5. Confirm role names match the chart values.
6. Create the DNS record for the ingress.
7. Replicate or issue the wildcard TLS Secret into the workload namespace.
   Kubernetes Ingress normally cannot reference a Secret in another namespace.
8. Verify nginx namespace/pod labels match the management NetworkPolicy.
9. Verify the broker can reach the issuer/JWKS endpoint when required.

The repository exposes only the Hawtio console through ingress. OpenWire, AMQP,
STOMP, MQTT, and WebSocket services remain internal `ClusterIP` services.

### 9.1 Hawtio management authorization migration

Do not port the legacy Hawtio configuration as a single file. In Artemis, the
embedded Hawtio console is a presentation layer over Jolokia and JMX. The
effective management authorization decision must be made by Artemis so the
same decision applies to console clicks and direct Jolokia/JMX calls.

Use these separate control layers:

| Control | Target source of truth | Purpose |
| --- | --- | --- |
| Human identity and role assignment | Keycloak | Users, groups, and console-role membership |
| Console admission | Hawtio OIDC configuration | Validate the token and require an approved console role |
| Management action authorization | Artemis management RBAC | Allow read-only or mutating MBean operations |
| HTTP/JMX exposure restrictions | `jolokia-access.xml` and ingress | CORS/origin checks and hard restrictions on dangerous MBeans or commands |
| Application messaging authorization | Artemis address security settings | `send`, `consume`, `browse`, and address/queue lifecycle permissions |

Keep human console roles separate from application producer/consumer roles.
Do not grant a user management access merely because the same person or
service can send to or consume from an application address.

#### 9.1.1 Legacy work-environment inventory

Collect the effective files from the running ActiveMQ Classic installation,
including local overrides, rather than relying only on the original install
package:

- `conf/jetty-realm.properties` and the effective Jetty authentication
  configuration;
- `conf/login.config` plus referenced user and group/role property files;
- `conf/jolokia-access.xml` and any web application `web.xml` overrides;
- `conf/activemq.xml`, especially authentication and authorization plugins;
- Hawtio system properties, environment variables, or container arguments;
  and
- LDAP, Keycloak, or other identity-provider group and role mappings.

Do not copy passwords, client secrets, access tokens, or bind credentials into
this repository or a change record. Record secret references and redact
values. For every effective legacy role, complete an action matrix like this:

| Legacy role | Can sign in | Can view | Allowed mutations | Queue/address scope | Target role |
| --- | --- | --- | --- | --- | --- |
| `LEGACY_VIEW_ROLE` | yes | all approved resources | none | `SCOPE` | `messaging-viewer` |
| `LEGACY_ADMIN_ROLE` | yes | all approved resources | `LIST_ACTIONS` | `SCOPE` | `messaging-admin` |

If permissions are assigned directly to named users, convert them to reviewed
roles or groups before migration. Preserve a per-user exception only when
there is a documented business and audit requirement.

#### 9.1.2 Target Artemis authorization

The baseline roles are:

| Artemis role | Management permission |
| --- | --- |
| `messaging-viewer` | `view` on approved `mops.*` resources; no `edit` |
| `messaging-admin` | `view` and `edit` on approved `mops.*` resources |

Add a narrower role, such as `messaging-operator`, when the legacy matrix
allows selected mutations but not full administration. Match exact management
resources and operation names rather than granting that role `edit` on
`mops.#`.

The preferred operator/GitOps representation is Artemis broker properties:

```yaml
brokerProperties:
  extra:
    - 'securityRoles."mops.#".messaging-viewer.view=true'
    - 'securityRoles."mops.#".messaging-admin.view=true'
    - 'securityRoles."mops.#".messaging-admin.edit=true'
```

Narrower grants use the hierarchical form
`mops.<resource-type>.<resource-name>.<operation>`. Verify the exact address
exported by the pinned Artemis version before granting a selected mutation.
Do not infer an operation name only from a Hawtio button label.

Hawtio must admit the intended roles and create the principal classes Artemis
expects. The effective JVM arguments must include the equivalent of:

```text
-Dhawtio.roles=messaging-viewer,messaging-admin
-Dhawtio.rolePrincipalClasses=org.apache.activemq.artemis.spi.core.security.jaas.RolePrincipal
-Dhawtio.userPrincipalClasses=org.apache.activemq.artemis.spi.core.security.jaas.UserPrincipal
-Djavax.management.builder.initial=org.apache.activemq.artemis.core.server.management.ArtemisRbacMBeanServerBuilder
```

The `ArtemisRbacMBeanServerBuilder` security-settings approach and the
`management.xml` `authorisation` approach are alternatives. When the builder
is enabled, the generated `management.xml` must not retain its competing
`authorisation` section. Implement that removal through an operator-supported
init/configuration customization and verify the resulting file in both broker
pods.

The current chart is not yet complete for this target. It:

- defines `messaging-viewer` and `messaging-admin`;
- extracts and maps those roles from the configured JWT claim; and
- sets `managementRBACEnabled: true`;

but it does not yet render the `mops.*` grants, explicit Artemis principal
classes, or the required `management.xml` change. Treat those items as
pre-production blockers. Setting only `managementRBACEnabled: true` does not
connect the Keycloak role names to the intended viewer/admin actions.

#### 9.1.3 Work-environment verification

Capture the following non-secret evidence for each application environment:

1. Keycloak client export or identity-team confirmation showing:
   - the exact issuer and client ID;
   - authorization code flow with PKCE `S256`;
   - the configured role claim path;
   - viewer, administrator, and any narrower operator roles; and
   - representative group-to-role assignments.
2. A decoded example token produced through Keycloak's evaluation function,
   with the token value and personal claims redacted, showing the expected
   roles at `keycloak.rolesPath`.
3. The rendered `hawtio-oidc.properties`, confirming issuer, client ID,
   redirect URI, user path, role path, and mappings.
4. The effective JVM arguments from each broker pod, confirming the OIDC
   configuration, console admission roles, Artemis principal classes, and
   `ArtemisRbacMBeanServerBuilder`.
5. The effective `management.xml` from each pod, confirming that its
   `authorisation` block is absent when the builder is used.
6. The effective broker configuration or `exportConfigAsProperties` output,
   confirming all intended `securityRoles."mops..."` entries and no
   unexpected broader grant.
7. Broker `getStatus()` output showing no broker-property application errors.
8. The effective `jolokia-access.xml` and ingress exposure, confirming
   approved origins and required MBean/command restrictions.

Do not accept screenshots of hidden or disabled Hawtio buttons as
authorization evidence. Execute both UI and direct Jolokia negative tests:

| Identity | Read/list operation | Approved limited mutation | Admin mutation |
| --- | --- | --- | --- |
| No console role | denied | denied | denied |
| `messaging-viewer` | allowed | denied | denied |
| Narrow operator role, if used | allowed as designed | allowed only where explicitly granted | denied |
| `messaging-admin` | allowed | allowed | allowed only within approved scope |

At minimum, test viewing broker and queue state and denying the viewer's
attempts to purge/delete a queue, move or remove messages, pause/resume a
resource, change security settings, and force failover. Use a disposable test
queue and test messages for mutation tests. Run direct Jolokia tests against
the same operations to prove the server rejects unauthorized requests even
when Hawtio is bypassed. Record the HTTP/Jolokia authorization result and
broker audit event without recording credentials or bearer tokens.

## 10. Monitoring, logging, and backups

### 10.1 Prometheus

The chart creates ServiceMonitor and PrometheusRule objects when enabled.
Confirm:

- Prometheus Operator CRDs exist before workload sync;
- namespace discovery and RBAC include the workload namespaces;
- the release labels match the installed Prometheus selector;
- the Prometheus pod labels match NetworkPolicy;
- `/metrics` on the console service is reachable; and
- exporter rules provide active and replica-synchronized metric names before
  enabling those optional alerts.

### 10.2 CloudWatch

No CloudWatch resources are rendered. Configure the existing cluster log agent
to collect stdout/stderr from the operator, Artemis, and ZooKeeper namespaces.
Add environment, cluster, namespace, component, pod, and broker identity
metadata. Set log groups, KMS encryption, retention, subscription filters,
alarms, and dashboards outside this repository. Verify that messages and
credentials are not logged.

### 10.3 Backup

No backup controller is rendered. Configure EBS snapshots/AWS Backup outside
the chart and follow `docs/runbooks/backup-restore.md`. A crash-consistent
snapshot is not automatically a broker-consistent recovery guarantee.

## 11. Bootstrap order

Use this controlled first-import sequence:

1. Mirror, scan, sign, and approve artifacts.
2. Register each EKS cluster in Argo CD using the exact destination server URL.
3. Configure Argo CD Git credentials and the private ECR OCI chart credential.
4. Create platform prerequisites: StorageClass, ingress, Vault injector/auth,
   Keycloak clients, TLS Secrets, monitoring CRDs, log collection, and backup
   policy.
5. Create Vault policies, roles, and workload secret data.
6. Label namespaces and platform pods exactly as required by NetworkPolicies.
7. Run local rendering and validation.
8. Apply the AppProject.
9. Apply only the operator ApplicationSet; wait for each operator and CRD to be
   Healthy.
10. Apply only the ZooKeeper ApplicationSet; wait for three members, three
    PVCs, quorum, metrics, and policy checks.
11. Apply one test Artemis workload; verify Vault injection/authentication,
    active/passive behavior, distinct PVCs/AZs, ingress, Keycloak, metrics, and
    client connectivity.
12. Run the clean-install, protocol, durability, failure, and rotation tests.
13. Add `SKY2` after `SKY` passes.
14. Promote the exact artifacts to `Nonprod`, add `smktest` (`EUT`), `TRN`,
    `TRN2`, and `PT` one at a time, and run load/upgrade/rollback tests.
15. Obtain approval, then add `PE`, `PP`, `DM`, and `PR` one at a time in
    `Prod`, applying the approved `PR` isolation option.

The `-20`, `-10`, and `0` annotations describe the intended dependency order.
Do not assume separate generated Applications will wait for one another merely
because they carry wave annotations. Enforce the sequence with a parent
bootstrap Application and health checks, or use the phased procedure above.

## 12. Render and validate before sync

Start with the repository suite:

```sh
make validate
make package
```

Render each effective workload using the same release name, namespace, base
chart, environment values, workload values, and Helm parameters that Argo CD
will use. Inspect at least:

```sh
helm lint charts/artemis-ha \
  --values environments/test/artemis-values.yaml \
  --values PATH_TO_TEST_A_VALUES

helm template TEST_A_RELEASE charts/artemis-ha \
  --namespace TEST_A_NAMESPACE \
  --values environments/test/artemis-values.yaml \
  --values PATH_TO_TEST_A_VALUES

helm lint charts/zookeeper \
  --values environments/test/zookeeper-values.yaml

helm template TEST_ZOOKEEPER_RELEASE charts/zookeeper \
  --namespace PLATFORM_NAMESPACE \
  --values environments/test/zookeeper-values.yaml
```

Fail the import if rendered output contains any of:

```sh
rg -n 'PLACEHOLDER_|example\.invalid|example-|my-cluster|sha256:0{64}' \
  RENDERED_MANIFESTS_DIRECTORY
```

Also fail if:

- a secret value is present in Git or rendered YAML;
- two pairs share a coordination ID or Curator namespace;
- two workloads share an unapproved console hostname;
- an image is tag-only or uses an unapproved digest;
- a wildcard TLS/Vault CA/ZooKeeper Secret is absent from its consuming
  namespace;
- network selectors do not match real labels;
- the StorageClass is immediate-binding or unencrypted;
- only one or two zones are schedulable for ZooKeeper; or
- the Vault authentication bridge has not been demonstrated.

## 13. First-workload verification

After Argo CD reports Synced and Healthy:

1. Confirm the operator version, CRDs, and related-image repositories.
2. Confirm three ZooKeeper members are on distinct nodes and zones with
   separate RWO PVCs.
3. Confirm ZooKeeper has one leader, two followers, and writable quorum.
4. Confirm the broker pair is on distinct nodes/zones with two separate RWO
   PVCs.
5. Confirm exactly one broker is active and ready and the peer is passive.
6. Confirm each protocol Service has only the active endpoint.
7. Confirm replication is connected and synchronized.
8. Confirm Vault authentication succeeded and the broker uses the intended
   credentials without printing them.
9. Confirm Keycloak login and complete the viewer/admin authorization evidence
   in Section 9.1, including direct Jolokia negative tests.
10. Confirm ingress TLS chain, host, redirects, and DNS.
11. Confirm NetworkPolicies allow only approved paths.
12. Confirm Prometheus targets/rules and CloudWatch logs.
13. Run OpenWire and AMQP deterministic sends/consumes.
14. Run a durable 100,000-message backlog and destructive failover scenarios.
15. Attach Argo, placement, PVC, quorum, active/passive, replication, Vault,
    OIDC, metrics, logs, and sequence reports to the change record.

Use `scripts/eks-scenario.sh` in dry-run mode first. Destructive mode requires
the exact context, cluster, and namespace confirmations.

## 14. Environment promotion rules

| Setting | Test | Nonprod | Prod |
| --- | --- | --- | --- |
| Application environments | `SKY`, `SKY2` | `smktest` (`EUT`), `TRN`, `TRN2`, `PT` | `PE`, `PP`, `DM`, `PR` |
| Artemis topology | 2 HA pairs / 4 broker pods | 4 HA pairs / 8 broker pods | 4 HA pairs / 8 broker pods |
| ZooKeeper topology | one shared 3-member ensemble | one shared 3-member ensemble | one shared 3-member ensemble by default; dedicated `PR` ensemble recommended |
| Broker storage baseline | 20 GiB | 50 GiB | 100 GiB, then measured |
| ZooKeeper storage baseline | 10 GiB | 20 GiB | 20 GiB |
| Artifacts | candidate digests | exact test digests | exact approved nonprod digests |
| Failure tests | full destructive suite | full release-candidate suite | controlled verification |
| Load | functional plus failure load | production-like sustained/burst | observe against approved SLO |
| Secrets | isolated test paths/roles | isolated nonprod paths/roles | isolated prod paths/roles |
| DNS/TLS/OIDC | test identities | nonprod identities | prod identities |

Do not vary HA mode, replica counts, persistence, zone spread, or coordination
semantics between promotion environments. Vary capacity, retention, identity,
domains, secret references, allowlists, and alert routing.

## 15. Current pre-production blockers

Treat these as explicit work items:

1. Replace every placeholder and example value in effective manifests.
2. Replace the ZooKeeper all-zero digest with a verified ECR digest.
3. Add per-workload console, Keycloak, Vault, HA cluster, and network-policy
   inputs to the ApplicationSet or workload overlays.
4. Implement and test the Vault-to-Artemis authentication bridge.
5. Verify the Vault injector token flow with service-account token automount
   disabled.
6. Decide and implement ZooKeeper client/server TLS and authentication if
   required by production policy.
7. Create declarative application addresses/queues and complete Classic 6.2.6
   compatibility tests.
8. Complete the Hawtio management authorization chain: Artemis principal
   classes, `mops.*` role grants, removal of the competing `management.xml`
   authorization block, and UI plus direct-Jolokia negative tests.
9. Add an environment deployment Job or approved runner for the validation
   client.
10. Supply external CloudWatch, EBS snapshot/restore, KMS, and alert-routing
   configuration.
11. Prove active-only readiness, Curator class availability, replication,
    zero dual activation, and zero loss of acknowledged durable messages on a
    real EKS test cluster.
