# ADR: Artemis HA through ArkMQ Broker Operator 2.2.0

*Status:* accepted for chart implementation; runtime HA acceptance remains a
promotion gate.

*Date:* 2026-07-28

## Decision

Use one `broker.amq.io/v1beta1` `ActiveMQArtemis` custom resource with a
two-replica `deploymentPlan`, `clustered: true`, file-journal persistence, and
the operator-supported `brokerProperties` escape hatch for Artemis’
replication-primary lock-manager policy. Both broker pods receive the same,
pair-unique `HAPolicyConfiguration.coordinationId` and the same ZooKeeper
ensemble connection string. The chart refuses to render unless the pair has
exactly two replicas, ZooKeeper is enabled, persistence is enabled, the
coordination identity is non-empty, and the broker image tag matches the
operator-selected operand version.

The chart uses the operator-generated StatefulSet and peer/headless Services.
It adds stable ClusterIP Services for OpenWire, AMQP, STOMP, MQTT, WebSocket,
and the console, plus a separate nginx TLS Ingress for the console. The
operator’s generated StatefulSet owns the broker PVCs, one per pod, using the
configured storage class and size. The chart requests active-only readiness
with a local authenticated Jolokia read of Artemis’ `Active` management
attribute while keeping startup and liveness independent of active/passive
state.

## Version and schema evidence

ArkMQ Broker Operator `v2.2.0` is pinned in the chart values and schema. The
operator’s release source declares the supported operand matrix as
`2.21.0` through `2.53.0` (including the listed patch/minor releases) and
declares `2.53.0` as its latest operand image. Artemis `2.55.0`, the candidate
in the implementation baseline, is therefore not a valid operand for this
operator release. The chart defaults to `2.53.0` and restricts the schema to
the exact upstream matrix.

The default example ECR-mirror image references preserve immutable upstream
tag-plus-digest pairs:
the broker image uses `sha256:6855d008e0a11b5110395ac321daaf69cfde24e36188c50e2b0291069e5a6234`
and the init image uses
`sha256:97967beea913ae9f4deb84de0be71247d3c3d7cb325b7f7a45c1257521997f83`.
Environment values should replace the example mirror repository only after independently
verifying that the mirror preserves the upstream digest; a changed digest is
a new artifact requiring review, scan, SBOM, and signature evidence.

Primary sources:

- [ArkMQ operator v2.2.0 version matrix](https://raw.githubusercontent.com/arkmq-org/activemq-artemis-operator/v2.2.0/version/version.go)
- [ArkMQ operator v2.2.0 ActiveMQArtemis API types](https://raw.githubusercontent.com/arkmq-org/activemq-artemis-operator/v2.2.0/api/v1beta1/activemqartemis_types.go)
- [ArkMQ operator v2.2.0 CRD](https://raw.githubusercontent.com/arkmq-org/activemq-artemis-operator/v2.2.0/config/crd/bases/broker.amq.io_activemqartemises.yaml)
- [ArkMQ operator brokerProperties documentation](https://github.com/arkmq-org/activemq-artemis-operator/blob/v2.2.0/docs/help/operator.md#configuring-brokerproperties)
- [Apache Artemis HA documentation](https://artemis.apache.org/components/artemis/documentation/latest/ha)
- [Artemis 2.53.0 configuration-property tests](https://github.com/apache/activemq-artemis/blob/2.53.0/artemis-server/src/test/java/org/apache/activemq/artemis/core/config/impl/ConfigurationImplTest.java)
- [ArkMQ Kubernetes broker image repository](https://github.com/arkmq-org/activemq-artemis-broker-kubernetes-image)

The chart’s `HAPolicyConfiguration.*` strings follow the Artemis 2.53.0
configuration bean property names, including:

```text
HAPolicyConfiguration=REPLICATION_PRIMARY_LOCK_MANAGER
HAPolicyConfiguration.distributedManagerConfiguration.className=org.apache.activemq.artemis.lockmanager.zookeeper.CuratorDistributedLockManager
HAPolicyConfiguration.distributedManagerConfiguration.properties.connect-string=<ensemble>
HAPolicyConfiguration.distributedManagerConfiguration.properties.namespace=<pair-unique-curator-namespace>
HAPolicyConfiguration.distributedManagerConfiguration.properties.session-ms=<timeout>
HAPolicyConfiguration.coordinationId=<pair-unique-id>
```

The operator documentation explicitly supports arbitrary `key=value`
`brokerProperties` and the Artemis source tests exercise the replication
primary lock-manager property tree. This is the smallest operator-managed
customization that preserves the desired broker configuration without
duplicating the operator’s StatefulSet reconciliation.

## Limitations and required acceptance

The operator does not provide a typed field that means “two competing
primaries,” does not validate that a supplied lock-manager class is present in
the selected image, and does not expose automatic/manual failback as a
first-class chart-safe switch. The chart therefore gates the intended shape
with values-schema and Helm `fail` checks, sets `automaticFailback: false` as
an explicit operational contract, and leaves failback to a runbook after the
recovered peer is synchronized. It does not claim that rendered YAML alone
proves split-brain safety.

The readiness command reads the Artemis `Active` management attribute so
passive peers are not selected by client Services. The attribute is part of
the upstream `ActiveMQServerControl` API; this behavior must still be verified
on the exact mirrored image and operator version. The upstream operator’s
default readiness script is a TCP/readiness check and is not sufficient to
establish active-only routing by itself.

The upstream broker image is preferred. The repository-owned image policy
requires a thin derived image only if runtime verification finds that the
ZooKeeper Curator lock-manager classes or required read-only-root filesystem
support are absent. Any derived image must preserve the exact upstream version
and base digest, run non-root, contain no secrets, and be rebuilt, scanned,
SBOMed, signed, and re-pinned before use.

The Vault Agent Injector annotations intentionally use
`agent-pre-populate-only: "true"` and file templates. The operator can
generate its own admin Secret when `requireLogin` is enabled, but its
`adminUser`/`adminPassword` CR fields are literal values and its
`extraMounts.secrets` mechanism consumes Kubernetes Secrets, not files written
by an init container. The chart consequently does not pretend that an
injected Vault file is automatically wired into those CR fields. The Vault
hooks are available for application/JAAS, Keycloak client, trust, and
post-launch configuration integration, while environments must provide the
tested broker authentication bridge without putting secret data in Git.

The [Artemis ActiveMQServerControl API](https://github.com/apache/activemq-artemis/blob/2.53.0/artemis-core-client/src/main/java/org/apache/activemq/artemis/api/core/management/ActiveMQServerControl.java)
provides the `Active` and `ReplicaSync` management attributes. The operator’s
default Prometheus configuration does not export every management attribute,
so the chart’s active-endpoint alert is always enabled and the optional
active/replication metric alerts are gated on environment-supplied exporter
metric names.

The chart renders Hawtio's documented `hawtio-oidc.properties` format into a
ConfigMap, mounts it through the operator's `extraMounts.configMaps` API, and
sets `-Dhawtio.oidcConfig` through `JAVA_ARGS_APPEND`. The Keycloak client is
a public browser client using authorization code flow with PKCE `S256`, so no
client secret is distributed to the console pod. Issuer, redirect URI, client
ID, scopes, and role mappings still require an image/console integration test
before promotion. The chart does not expose messaging ports through an
Ingress or LoadBalancer.

## Consequences

This design keeps the operator responsible for broker lifecycle, PVCs,
cluster discovery, and generated resources while making the HA policy and
security posture reviewable in the CR. It also means EKS validation is
mandatory: render/schema validation can verify the property strings and
topology, but only destructive tests can prove zero dual activation, durable
acknowledgement behavior, ZooKeeper quorum behavior, replication recovery,
active-only Service routing, Keycloak authorization, and Vault rotation.
