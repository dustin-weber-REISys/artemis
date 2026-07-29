# Artemis HA chart

This chart renders an operator-managed, authenticated, persistent
competing-primary pair. Those deployment properties are chart invariants, not
values: the `ActiveMQArtemis` resource always has two replicas, login required,
persistence enabled, the embedded console on port `8161`, and an external
ZooKeeper lock manager.

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

Environment values must supply a pair-unique `ha.coordinationId`, a unique
ZooKeeper curator namespace, the external ZooKeeper connection and selectors,
mirrored image repositories, ingress identity, and the approved policy
sources. Run `./tests/test.sh` for focused rendering, schema, port-coherence,
and Kubernetes resource validation.
