# ZooKeeper Kustomize deployment

This base renders the shared, persistent three-voter ZooKeeper ensemble used
for Artemis activation coordination. The base owns the quorum, persistence,
security context, disruption budget, quorum-safe host and zone placement,
network policy, and monitoring contract. The `test`, `nonprod`, and `prod`
overlays own capacity, storage, approved node access, and integration values.
Nonprod and prod retain the hard three-zone quorum contract. Test keeps hard
one-pod-per-node anti-affinity but uses best-effort zone spread so historical,
AZ-bound test volumes cannot deadlock a replacement Pod.

Resource names intentionally match the former Helm renders. In particular,
the StatefulSet, its ordinal PVC names, the headless Service, and the client
Service retain their existing identities. The generated ConfigMap has a
content hash so configuration changes update the Pod template and trigger a
controlled StatefulSet rollout.

The PVC template also retains the former Helm chart, release, version, and
manager labels. Kubernetes treats the complete claim template as immutable, so
those historical labels intentionally do not follow later ZooKeeper upgrades.
Current release identity is recorded on the StatefulSet and Pod template.

The retired chart's optional ZooKeeper TLS and JAAS inputs were disabled in all
three environments and are not part of this Kustomize module. Enabling either
requires a separate security design with external secret materialization,
rotation, network-policy, and acceptance-test changes; do not add ad hoc Secret
mounts to an environment overlay.

Each overlay renders the complete `zoo.cfg`, including its environment-specific
peer DNS records, into a read-only ConfigMap mount. The init container only
waits for every stable peer DNS record; it does not copy or modify `zoo.cfg` at
runtime. This preserves the non-root/read-only container contract and prevents
a config-volume ownership mismatch from blocking startup. Keep the common
settings in the base and overlay files aligned when changing ZooKeeper
configuration.

A pod that remains in `Init:0/1` indicates that a peer has not received an IP,
the headless Service has not published its endpoint, or DNS egress is
unavailable. Check Pod scheduling and PVC events, the headless Service's
EndpointSlices, and CoreDNS before changing peer discovery.

The hard host anti-affinity and promotion-environment zone spread are quorum
safeguards. If eligible nodes are tainted, add only the exact node-pool
toleration in the environment StatefulSet patch. Do not relax host
anti-affinity or the three-voter count. Nonprod and prod must also retain
`DoNotSchedule`. Test intentionally uses `ScheduleAnyway`: the scheduler still
prefers one voter per zone, but an ordinal may return to its retained volume's
existing zone instead of leaving the ensemble stuck during refresh.

The selected EBS StorageClass must use `WaitForFirstConsumer`. The StatefulSet
retains ordinal PVCs across deletion and scale-down, and a replacement voter
must remain Ready for 30 seconds before the rollout continues. During node
maintenance, keep capacity available in every zone containing a bound volume,
use eviction-based drain, and disrupt only one voter at a time.

The Argo CD ZooKeeper Application intentionally disables automatic sync. Before
manual sync, run `make -C gitops check-zookeeper-rollout CONTEXT=... ENVIRONMENT=...`.
This read-only gate verifies that the current ensemble is stable and that
retained volumes, running voters, eligible nodes, and the rendered placement
policy agree. It blocks nonprod and prod unless all three voters occupy
distinct zones; in test it reports reduced zone-loss tolerance as a warning.
A retained EBS volume cannot move availability zones as part of a StatefulSet
or Argo CD rollout.

Run `./tests/test.sh` for deterministic rendering, contract assertions, and
Kubernetes resource validation.
