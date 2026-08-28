# ADR: Shared private NLB for out-of-cluster messaging

- Status: Accepted design; implementation pending platform integration
- Date: 2026-08-25
- Decision owners: Platform Engineering

## Context

Every enabled Artemis acceptor currently has a readiness-gated Kubernetes
`ClusterIP` Service. Those Services give in-cluster clients stable discovery
while allowing broker pod IPs to change, but they do not provide an endpoint
for clients outside EKS. The shared Application Load Balancer serves only the
HTTP/HTTPS management console and cannot carry OpenWire, AMQP, STOMP, or MQTT
traffic.

Provisioning one Network Load Balancer for every Workload Cell would preserve
the standard broker ports, but would multiply load balancers, security groups,
DNS records, and platform lifecycle work. The platform instead needs one
private Layer 4 entry point without allowing one Workload Cell's clients to be
routed to another Workload Cell.

An NLB cannot select an Artemis backend from a DNS name. DNS aliases that point
to the same NLB resolve to the same frontend addresses, and NLB TLS SNI support
selects certificates rather than a Workload Cell target group. A listener that
forwards to multiple Workload Cell target groups would distribute connections
among those cells and is therefore invalid for broker isolation.

## Decision

Use one shared **internal** NLB per EKS cluster and compatible messaging trust
boundary. Internal and batch Workload Cells may share it when their network
admission policy is compatible. Do not place the management console on this
NLB. Do not add a future partner-facing or external-client listener to the
internal NLB until the external mTLS, authentication, authorization, and
per-listener network controls have passed their separate enablement gates.

Each exposed Workload Cell acceptor receives:

1. one unique NLB frontend listener port;
2. one target group dedicated to that Workload Cell and acceptor;
3. one namespaced `TargetGroupBinding` that associates the target group with
   the existing readiness-gated `ClusterIP` Service; and
4. one friendly private DNS name for client configuration.

The frontend listener port, not the DNS name, is the Workload Cell routing key.
Different DNS aliases may point to the shared NLB, but two Workload Cells
cannot both use the same NLB listener port. The target group can forward its
unique frontend port to the acceptor's standard backend port, such as a unique
allocated port forwarding to OpenWire/CORE `61616`.

Do not change the acceptor Services to `type: LoadBalancer`; the normal AWS
Load Balancer Controller Service reconciliation model would create an NLB per
Service. The shared NLB, listeners, target groups, security group, subnet
placement, and private DNS aliases are platform-owned. The
`TargetGroupBinding` remains Workload Cell scoped and lets the controller track
changing ready pod IPs without making pod addresses part of client
configuration.

## Listener allocation and protocol scope

Allocate listener ports from a platform-owned registry keyed by cluster,
Workload Cell, and acceptor. An allocation must not be reused while its DNS
name or clients may still exist. Client documentation records both the friendly
DNS name and allocated port.

Expose only protocols confirmed by the
[protocol acceptor inventory runbook](runbooks/protocol-acceptor-inventory.md).
An enabled broker acceptor does not automatically receive an NLB listener.
CORE/OpenWire `61616` is the initial migration path; add AMQP or another
protocol only for a Workload Cell with an identified client and completed
positive and negative tests.

This constraint also protects NLB capacity. AWS currently permits 50 listeners
per NLB and does not make that quota adjustable. The production topology has
eight declared Workload Cells, while the standard Profile currently enables
five acceptors per cell. Exposing every default would consume 40 listeners
before growth or migration overlap. A minimal one-listener-per-cell design
uses eight and leaves deliberate capacity for proven requirements.

Before implementation, the platform owner must publish the complete proposed
allocation and fail validation when it contains duplicate frontend ports or
exceeds the listener budget.

## Traffic and security requirements

- Use the `internal` NLB scheme and approved private subnets. This decision
  does not authorize an internet-facing messaging listener.
- Restrict frontend traffic with the smallest supported client security groups
  or stable source CIDRs. Security-group admission does not replace broker pod
  NetworkPolicy.
- Choose NLB target type and client-IP preservation explicitly. Record whether
  the pod observes the original client, a NAT address, or an NLB address, then
  configure the corresponding narrow `networkPolicy` source.
- Use one target group per listener. Never combine targets from independent
  Workload Cells in one target group and never use weighted forwarding between
  cells.
- Register only ready Service endpoints. Runtime acceptance must prove that the
  active broker is registered, the passive broker is not client-routable, and
  target registration follows broker failover.
- Do not expose the console, Jolokia, metrics, ZooKeeper, JGroups, or the broker
  peer-only path through the messaging NLB.
- Use a Route 53 private alias as the client contract. Clients must reconnect
  and re-resolve DNS; they must not store broker pod IPs or depend on the NLB's
  generated hostname.
- Monitor target health, rejected connections, listener usage, connection
  resets, and failover recovery by Workload Cell and listener.

The effective source address must be established in the authorized runtime
environment as described by the
[internal CIDR onboarding runbook](runbooks/internal-cidr-onboarding.md). This
offline checkout must not inspect or modify live NLBs, security groups, routes,
or EKS resources.

## Availability and operational consequences

The shared NLB reduces resource count and centralizes private client entry, but
it becomes a shared configuration and capacity boundary. An erroneous listener,
security-group, subnet, or NLB lifecycle change can affect multiple Workload
Cells even though journals, queues, Services, and target groups remain
independent. Platform changes therefore require rendered allocation review,
per-listener health evidence, and rollback that does not replace or delete the
shared NLB.

Workload Cell retirement removes its DNS alias, listener, target group, and
`TargetGroupBinding` only after clients have drained and the port-retention
window has elapsed. It must not change unrelated listeners.

If clients require the same frontend port for every Workload Cell, this design
cannot satisfy that requirement with a plain NLB. The alternatives are separate
NLBs or a separately approved SNI-aware TCP proxy. Such a proxy adds a hop,
protocol and TLS assumptions, another availability tier, and a larger failure
domain, so it is not part of this decision.

## Implementation gates

Repository implementation is complete only when it includes:

- a validated platform-owned listener and target-group allocation;
- a typed Workload Cell interface for the assigned target group and frontend
  endpoint without secret material;
- rendered `TargetGroupBinding` resources for selected acceptors only;
- duplicate-port, missing-target-group, and listener-budget validation;
- NetworkPolicy rules aligned with the source address observed at the pod;
- private DNS and security-group ownership documentation;
- active/passive registration, failover, denied-source, disabled-protocol, and
  rollback acceptance tests; and
- retirement handling for DNS, listeners, target groups, and port allocations.

Until those gates are implemented and tested, the chart's `ClusterIP` Services
remain authoritative and no out-of-cluster messaging exposure is claimed.

## References

- [AWS EKS Network Load Balancing](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html)
- [AWS Load Balancer Controller TargetGroupBinding](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/targetgroupbinding/targetgroupbinding/)
- [AWS Load Balancer Controller L4 Gateway behavior](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/gateway/l4gateway/)
- [AWS NLB quotas](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-limits.html)
