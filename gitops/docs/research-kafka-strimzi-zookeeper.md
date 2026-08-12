# Strimzi, Kafka, and ZooKeeper

Research date: 2026-08-11

## Answer

Current Strimzi does **not** deploy ZooKeeper. Strimzi 0.46 removed support for
ZooKeeper-based Kafka clusters, and current Strimzi supports only KRaft-based
Kafka. Kafka 4.0 and later also run exclusively in KRaft mode. In KRaft, Kafka
controllers store cluster metadata in Kafka's own Raft metadata log; this is
not a general-purpose ZooKeeper endpoint that Artemis Curator clients can use.

Historically, Strimzi did manage ZooKeeper for Kafka. Through Strimzi 0.45.x,
a ZooKeeper-mode `Kafka` custom resource caused the Cluster Operator to create
and reconcile a Kafka-specific ZooKeeper ensemble, including its pods,
services, PVCs, certificates, and network policies. Older examples commonly
created three Kafka brokers and three ZooKeeper nodes.

Artemis should not reuse a historical Strimzi-managed ZooKeeper ensemble for
broker activation locking:

- Current Strimzi offers no such ensemble, so this cannot be the forward-looking
  design.
- In ZooKeeper-era Strimzi, the ensemble was an implementation resource owned
  by the `Kafka` custom resource. Strimzi documentation says the operator
  patches or recreates owned resources to match that resource and undeploys
  related resources when the owning resource is deleted.
- Strimzi's KRaft migration automatically deletes ZooKeeper resources. Coupling
  Artemis locks to them would therefore turn a Kafka migration or removal into
  an Artemis availability event.
- Access would also have to be added around Strimzi-generated TLS and network
  policy. That creates an unsupported cross-application ownership seam even if
  ZooKeeper's namespacing makes separate znodes technically possible.
- Sharing would couple Kafka metadata and Artemis activation to one quorum and
  one maintenance lifecycle. It saves three pods at the cost of a wider failure
  domain and harder upgrades.

The last two points are architecture inferences from Strimzi's documented
ownership and lifecycle, rather than an explicit Strimzi prohibition. The
recommended boundary is to keep Artemis's ZooKeeper ensemble independent. If
the Kafka platform is current Strimzi, it is already KRaft-only and there is no
Kafka ZooKeeper to consolidate with.

## Primary sources

- [Current Strimzi deploying and managing guide](https://strimzi.io/docs/operators/latest/deploying.html): KRaft replaces ZooKeeper; ZooKeeper support was removed in Strimzi 0.46; Kafka 4.0 has no ZooKeeper integration.
- [Strimzi 0.45.2 deploying and managing guide](https://strimzi.io/docs/operators/0.45.2/deploying.html): documents the former ZooKeeper deployment, operator ownership semantics, and migration states in which ZooKeeper resources are automatically deleted.
- [Strimzi KRaft information page](https://strimzi.io/kraft/): official transition timeline and links to migration guidance.
- [Apache Kafka KRaft documentation](https://kafka.apache.org/documentation/#kraft): describes the KRaft controller quorum and ZooKeeper-free metadata management.

