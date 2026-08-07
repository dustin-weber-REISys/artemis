# Artemis HA chart

This chart renders an operator-managed, authenticated, persistent
competing-primary pair. Those deployment properties are chart invariants, not
values: the `ActiveMQArtemis` resource always has two replicas, login required,
persistence enabled, the embedded console on port `8161`, and an external
ZooKeeper lock manager.

The chart pins transactional and non-transactional journal sync, journal data
sync, and large-message sync to `true`. Those keys and HA/replication identity
keys are protected from `brokerProperties.extra` overrides.

Client listeners are configured under `acceptors`. Every enabled acceptor is
rendered into the broker custom resource and gets a matching active-only
`ClusterIP` Service. When client NetworkPolicy sources are configured, their
allowed ports are derived from that same enabled-acceptor set. Disabling an
acceptor therefore removes it from all three surfaces.

The operator-managed broker cluster connector is separate from client
listeners and uses its fixed internal port `61616`. Peer ingress and egress
policy allow only that internal port. Console Services, management and
monitoring policies, and all probes share the chart's fixed console-port
helper, so they cannot be configured independently.

Broker scheduling requires two eligible zone and host domains and injects an
explicit anti-affinity selector for the pair. A separate metrics Service
publishes both broker endpoints so Prometheus can scrape the passive peer even
though client Services retain the active-only readiness gate. ZooKeeper's
companion chart keeps its three voters on separate hosts and spreads them over
the environment's available zone count.

Each workload's effective configuration must supply a pair-unique
`ha.coordinationId`, a unique ZooKeeper curator namespace, the external
ZooKeeper connection and selectors, ingress identity, and the approved policy
sources. The operator maps `broker.version` to the immutable private broker and
init images configured by its pinned chart. The ApplicationSet supplies the
pair-specific fields from `argocd/topology`; environment overlays supply
stage-wide runtime fields. Run
`./tests/test.sh` for focused rendering, schema,
port-coherence, and Kubernetes resource validation.

Vault injection defaults off. The optional annotations only request a
pod-local credential file; they do not make it the broker's effective
administrative identity. Enable `vault.enabled` only after the environment
provides and tests the approved Vault-to-Artemis bridge.

## Storage

The chart consumes `persistence.storageClassName`; it never creates a
cluster-scoped StorageClass. The platform-owned class must provide the approved
EBS CSI provisioner, delayed binding, encryption, `Retain` reclaim policy, and
volume expansion. Pair-specific capacity comes from the environment topology
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

## Pair-specific management identity and storage

The environment-local ApplicationSet overrides `console.ingress.host`,
`keycloak.redirectUri`, and `persistence.size` from each broker-pair entry in
`argocd/topology`. This gives every pair an unambiguous Hawtio/Jolokia URL,
exact OIDC redirect URI, and explicit storage allocation. The host, redirect
URI, TLS certificate, DNS record, and Keycloak client registration must agree
before enabling a pair.
