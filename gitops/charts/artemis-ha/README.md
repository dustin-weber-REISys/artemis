# Artemis HA chart

This chart renders an operator-managed, authenticated, persistent
competing-primary pair. Those deployment properties are chart invariants, not
values: the `ActiveMQArtemis` resource always has two replicas, login required,
persistence enabled, the embedded console on port `8161`, and an external
ZooKeeper lock manager.

The chart pins transactional and non-transactional journal sync, journal data
sync, and large-message sync to `true`. Those keys and HA/replication identity
keys are protected from `brokerProperties.extra` overrides.

The non-secret broker administrator name is set once with `broker.adminUser`
and is shared by every environment that consumes the chart. Replace
`PLACEHOLDER_ARTEMIS_ADMIN_USERNAME` with the approved value (for example,
`elis-admin`) in the environment-owned copy. The chart deliberately omits
`spec.adminPassword`, so the operator continues to generate a separate password
for each broker deployment and store it only in that deployment's credential
Secret.

Client listeners are configured under `acceptors`. Every enabled acceptor is
rendered into the broker custom resource and gets a matching active-only
`ClusterIP` Service. When client NetworkPolicy sources are configured, their
allowed ports are derived from that same enabled-acceptor set. Disabling an
acceptor therefore removes it from all three surfaces.

A TLS acceptor references one externally materialized operator SSL Secret with
`sslSecret`. That Secret owns both the server keystore and client truststore;
their paths, passwords, private keys, and certificate contents never appear in
chart values. The chart rejects TLS without an SSL Secret and rejects
`needClientAuth` unless TLS is enabled. Client certificate or password identity
is supplied through `authentication.jaasSecretName`, which must use the
operator's `-jaas-config` suffix. See the
[Classic external-security migration guide](../../docs/classic-external-security-migration.md)
for the required Secret shapes and role mapping.

The operator-managed broker cluster connector is separate from client
listeners and uses its fixed internal port `61616`. Peer ingress and egress
policy allow only that internal port. Console Services, management and
monitoring policies, and all probes share the chart's fixed console-port
helper, so they cannot be configured independently.

The readiness probe asks Jolokia for the `Active` attribute using a broker
MBean pattern instead of deriving the MBean name from the Kubernetes
application name. The operand's broker name is image configuration (for
example, `amq-broker`) and is not required to match the `ActiveMQArtemis`
resource name. The local request includes the Origin header required by the
default Jolokia CORS policy. Only the peer whose returned `Active` attribute
is `true` becomes ready.

Broker scheduling requires two eligible zone and host domains and injects an
explicit anti-affinity selector for the pair. A separate metrics Service
publishes both broker endpoints so Prometheus can scrape the passive peer even
though client Services retain the active-only readiness gate. ZooKeeper's
companion chart keeps its three voters on separate hosts and spreads them over
the environment's available zone count.

Every environment overlay admits broker pods to its on-demand worker nodes with
the exact `eid-platform/node-lifecycle=ondemand:NoSchedule` toleration. Keep
this aligned with the environment node-pool taint. A synced workload with
broker pods remaining unscheduled has no console Service endpoints, so the
shared ALB correctly returns 503 until at least the active broker is ready.

The chart puts required enterprise labels on the `ActiveMQArtemis` resource and
broker pod template, and uses the operator's unscoped `resourceTemplates`
contract to put them on every operator-generated supporting resource. This is
required because admission policy evaluates StatefulSet metadata separately
from its pod-template metadata. Removing that template leaves the custom
resource valid but causes Gatekeeper to reject the generated StatefulSet, so no
broker pods or console endpoints can exist.

Each workload's effective configuration must supply a pair-unique
`ha.coordinationId`, a unique ZooKeeper curator namespace, the external
ZooKeeper connection and selectors, ingress identity, and the approved policy
sources. The operator maps `broker.version` to the immutable private broker and
init images configured by its pinned chart. The ApplicationSet supplies
Workload Cell identity and sizing from `argocd/topology`, loads one approved
Profile, and then loads environment-owned cluster integrations. Run
`./tests/test.sh` for focused rendering, schema,
port-coherence, and Kubernetes resource validation.

The chart follows the platform's established shared ALB pattern: the
`aws-lb-ingress` IngressClass, `shared-standard-group`, HTTP and HTTPS
listeners, IP targets, an HTTP backend, and the platform-standard health check
range. HTTPS certificates, scheme, subnets, and security groups are owned by
the shared ALB/IngressClass, so Artemis does not render a workload TLS Secret
reference. The `aws-lb-ingress` IngressClass must be installed before an
Application is synced. Because ALB traffic does not originate from an
in-cluster ingress-controller pod, environments must allow their approved
ALB/VPC sources on the console port through `networkPolicy.extraIngress` or an
equivalent platform-owned policy.

Vault injection defaults off. The optional annotations only request a
pod-local credential file; they do not make it the broker's effective
administrative identity. Enable `vault.enabled` only after the environment
provides and tests the approved Vault-to-Artemis bridge.

## Client identity, authorization, and destination catalog

`authentication.jaasSecretName` stores only a Secret reference. The externally
materialized Secret contains `login.config` and its user/DN/role property files.
Its JAAS realm must retain the image's generated PropertiesLoginModule so the
operator and readiness probe can continue to authenticate.

`authorization.rules` is the reviewed, non-secret permission interface. It
renders role grants through `securityRoles` broker properties. Users, passwords,
certificate DNs, and group membership are not accepted by this interface.
`destinations` is the permanent address and queue catalog and renders
`addressConfigurations` broker properties. Direct `securityRoles` and
`addressConfigurations` entries in `brokerProperties.extra` are rejected so
these controls cannot be bypassed by an untyped override.

The maintained mTLS example in
[`tests/fixtures/external-mtls-values.yaml`](tests/fixtures/external-mtls-values.yaml)
is also rendered by the focused chart test.

## Storage

The chart consumes `persistence.storageClassName`; it never creates a
cluster-scoped StorageClass. The platform-owned class must provide the approved
EBS CSI provisioner, delayed binding, encryption, `Retain` reclaim policy, and
volume expansion. Workload Cell capacity comes from the cluster catalog
and is passed as `persistence.size`.

## Dead-letter and expiry resources

The catch-all policy under `brokerProperties.addressSettings` is authoritative
for dead-letter, expiry, redelivery, paging, and destination auto-creation
behavior. Its focused chart tests verify the rendered broker properties.
Defaults create retained per-source `DLQ.<source-address>` resources after the
configured delivery attempts. Expiry routing is disabled; enabling it creates
per-source `EXP.<source-address>` resources but does not assign a message
lifetime.

These settings currently apply to the pair's catch-all `#` match. They are
therefore platform defaults for every team sharing that pair, not independent
per-team profiles. Before teams can select different policies on one shared
pair, the chart must add and validate multiple address-setting matches, such
as `team-a.#`, and the queue catalog must record the selected policy. Do not
use unrestricted `brokerProperties.extra` entries as an informal substitute.

Permanent application queue and address auto-creation remains disabled.
Team-owned destinations are supplied declaratively through GitOps; automatic
DLQ and expiry resources are broker-managed operational destinations.

## Workload Cell management identity and storage

The environment-local ApplicationSet overrides `console.ingress.host`,
`keycloak.redirectUri`, and `persistence.size` from each Workload Cell entry in
`argocd/topology`. This gives every Workload Cell an unambiguous Hawtio/Jolokia URL,
exact OIDC redirect URI, and explicit storage allocation. The host, redirect
URI, shared-ALB certificate coverage, DNS record, and Keycloak client
registration must agree before enabling a Workload Cell.
