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

Run `./tests/test.sh` for focused rendering, schema, and Kubernetes resource
validation.
