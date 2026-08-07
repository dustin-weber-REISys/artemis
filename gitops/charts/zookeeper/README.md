# ZooKeeper chart

This chart renders the shared, persistent three-voter ZooKeeper ensemble used
for Artemis activation coordination. It intentionally requires three eligible
hosts and zones, publishes unready StatefulSet endpoints through its headless
Service, and creates all members in parallel.

Each member waits in the `wait-for-peer-dns` init container until all three
stable peer records resolve. This prevents a transient EndpointSlice or DNS
publication race from repeatedly restarting ZooKeeper with an
`UnknownHostException`. A pod that remains in `Init:0/1` indicates that a peer
has not received an IP, the headless Service has not published its endpoint,
or DNS egress is unavailable. Check Pod scheduling and PVC events, the
headless Service's EndpointSlices, and CoreDNS before changing the peer names.

Run `./tests/test.sh` for focused rendering, schema, and Kubernetes resource
validation.
