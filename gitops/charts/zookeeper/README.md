# ZooKeeper chart

This chart renders the shared, persistent three-voter ZooKeeper ensemble used
for Artemis activation coordination. It requires three eligible hosts and
spreads them across the environment's configured zone count, publishes
unready StatefulSet endpoints through its headless Service, and creates all
members in parallel. Test uses two zones; nonprod and prod retain three.

Each member waits in the `wait-for-peer-dns` init container until all three
stable peer records resolve. This prevents a transient EndpointSlice or DNS
publication race from repeatedly restarting ZooKeeper with an
`UnknownHostException`. A pod that remains in `Init:0/1` indicates that a peer
has not received an IP, the headless Service has not published its endpoint,
or DNS egress is unavailable. Check Pod scheduling and PVC events, the
headless Service's EndpointSlices, and CoreDNS before changing the peer names.

The hard host anti-affinity and zone spread are quorum safeguards. If the
eligible nodes are tainted, configure `scheduling.nodeSelector` for that node
pool and `scheduling.tolerations` for its exact taint in the environment
values. Do not change `topology.whenUnsatisfiable`, relax pod anti-affinity, or
add a keyless `Exists` toleration merely to make the pods schedule; those
changes can co-locate voters or admit them to unrelated protected nodes.
Do not tolerate autoscaler deletion-candidate, `unschedulable`, or `not-ready`
taints. Those nodes are intentionally unavailable and must leave the eligible
set.

The selected EBS StorageClass must use `WaitForFirstConsumer`. Otherwise a
volume can bind to an availability zone before Kubernetes evaluates the
ZooKeeper host and zone constraints, leaving the pod with simultaneous
`PersistentVolume node affinity` and topology-spread failures. Changing this
chart or the StorageClass does not relocate an existing bound EBS volume.

For a new ensemble that has never formed or accepted data, first correct the
StorageClass and then recreate its uninitialized claims so the scheduler can
provision them against the corrected topology. Treat claim deletion as data
destruction: do not use that recovery on an initialized ensemble. Recover an
initialized ensemble one member at a time under the backup/restore and quorum
runbooks instead.

The readiness check starts after the same 30-second startup window as the
liveness check. A single `Readiness probe failed` event during an older rollout
means that `zkServer.sh status` reached the local client port before that voter
finished joining the quorum; if the pod subsequently becomes Ready and the
event count stops increasing, no recovery action is required. Investigate a
repeating event or a pod that remains unready as a quorum, network, or process
failure.

Run `./tests/test.sh` for focused rendering, schema, and Kubernetes resource
validation.
