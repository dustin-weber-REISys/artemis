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

An ordinary node replacement does not relocate or replace the volume. The
StatefulSet recreates the same ordinal, and Kubernetes schedules that Pod onto
an eligible node in the EBS volume's availability zone before the EBS CSI
driver detaches the volume from the old node and attaches it to the new one.
The chart explicitly retains ordinal PVCs across StatefulSet deletion and
scale-down. It also requires a replacement voter to remain Ready for 30 seconds
before a StatefulSet rolling update proceeds to another ordinal.

For node maintenance, keep capacity available in every zone containing a
bound ZooKeeper volume, use eviction-based drain without force or
`--disable-eviction`, and disrupt only one voter at a time. Wait until all
three voters are Running and Ready and the ensemble reports one leader and two
followers before touching another node. The PDB prevents a second voluntary
eviction while one voter is unavailable, but it cannot prevent simultaneous
instance loss, forced termination, an availability-zone outage, or a node
group scale-down that bypasses eviction safeguards.

For a whole-environment shutdown, stop or quiesce brokers and clients before
workers, preserve the StatefulSet and PVCs, and leave the EBS volumes intact.
On startup, restore eligible worker capacity in every bound-volume zone and
allow all three stable ordinals to reattach their original claims and form
quorum before starting or admitting broker traffic. A pod cannot attach its
EBS volume in another zone; if its original zone will not return, recover that
member one at a time from the approved backup procedure rather than deleting
its initialized claim.

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
