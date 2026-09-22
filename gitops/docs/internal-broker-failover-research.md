# Internal broker Service and failover evidence

Research date: 2026-09-22. Scope: the repository's Artemis 2.53.0 / operator
2.2.0 configuration; no live infrastructure was contacted.

## Conclusion

The short `broker` DNS alias can remain. Its target Service includes both
role-neutral Ready peers, so it is **not an active-only endpoint**. For the
ActiveMQ Classic Java/OpenWire client, a single Service URI wrapped in
`failover:(...)` can reconnect through that Service after a connection failure.
This is a retry-based design, not a guarantee that the first attempt reaches
the active peer or that reconnection finishes within a fixed time.

No documentation establishes that a custom controller is mandatory for this
client configuration. Conversely, documentation alone does not prove the
deployed client/image/network combination meets the recovery target. Retain
the repository's runtime acceptance gate and exercise the actual Service path.

## Primary-source findings

- An `ExternalName` Service returns a DNS CNAME; it does not add a proxy or
  health check. The repository's `broker` alias points at the existing
  messaging ClusterIP Service, so it preserves that Service's routing.
  [Kubernetes ExternalName Services](https://kubernetes.io/docs/concepts/services-networking/service/#externalname)
- Artemis defines an active broker as accepting remote connections and a
  passive broker as not accepting them. A healthy standby is therefore not a
  usable messaging destination until activation. Its HA policy performs the
  activation; Kubernetes DNS does not elect the active broker.
  [Apache Artemis HA](https://artemis.apache.org/components/artemis/documentation/latest/ha)
- Kubernetes Service forwarding chooses among eligible endpoints. In iptables
  mode the default selection is random; it is not an Artemis role probe.
  **Inference:** when both peers are eligible, a fresh connection can land on
  the passive peer, and a later client connection attempt can land on the
  active peer. Neither deterministic alternation nor a finite recovery bound
  follows from this behavior. The actual cluster data plane remains unverified.
  [Kubernetes virtual IPs and proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/)
- Classic failover transport adds reconnection logic and supports a single URI
  (the official examples include one). `startupMaxReconnectAttempts=-1` enables
  unlimited startup retries; `maxReconnectAttempts=-1` enables unlimited later
  retries for modern clients. The documented default maximum reconnect delay
  is 30 seconds. Infinite retry is not a recovery-time guarantee. In-flight
  transactions can require application rollback/replay handling.
  [Classic failover reference](https://activemq.apache.org/components/classic/documentation/failover-transport-reference)
- That connection-string syntax is specific to the Classic client. Artemis
  Core has different `ha` and `reconnectAttempts` settings. Protocol/client
  identity must be recorded in acceptance results.
  [Artemis Core client failover](https://artemis.apache.org/components/artemis/documentation/latest/client-failover.html)

## Why changing Pod readiness is not a safe shortcut

Normal StatefulSet rolling updates wait for an updated Pod to become Ready
before advancing. **Inference:** making a healthy passive broker permanently
unready can stall an update after that broker restarts as standby. Changing
readiness solely to filter messaging traffic also changes lifecycle behavior.
[Kubernetes StatefulSet rolling updates](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#rolling-updates)

PDB health is based on Pod `Ready=True`. **Inference:** in a two-peer set with
`maxUnavailable: 1`, treating standby as unready consumes the healthy active
peer's voluntary-eviction budget during normal operation. This is distinct
from StatefulSet rollout behavior; PDBs do not solve the rollout issue.
[Kubernetes PDB health](https://kubernetes.io/docs/tasks/run-application/configure-pdb/#healthiness-of-a-pod)

## If active-only routing becomes a requirement

A selectorless Service with controller-managed EndpointSlices is supported by
Kubernetes. A role observer could publish only the current active peer while
leaving Pod readiness role-neutral. That adds reconciliation, stale-observation,
RBAC, availability, and transition-testing requirements. It still cannot migrate
an existing broken TCP connection; the application client needs reconnection.
This is an optional design change for active-only routing, not an established
prerequisite for the existing retry-based design.
[Kubernetes custom EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/service/#services-without-selectors)

## Evidence limits and required acceptance

Pinned operator source retrieval was unsuccessful during this review. No
built-in active-role label was verified, and none should be assumed. The
StatefulSet discussion describes documented Kubernetes behavior, not an
inspection of the live operator-generated StatefulSet. The official Artemis
`latest` HA documentation was available; its version-specific 2.53.0 URL was
not retrieved, so runtime behavior on the exact mirrored artifact remains a
test obligation.

Verify the actual client repeatedly establishes messaging connections through
the short DNS name with both peers Ready, then recovers through that same name
after each peer has taken the active role. Record retry timings, the actual
Service endpoint set, broker role/synchronization evidence, client errors, and
durable-message accounting. Use a normal client network path: Service
port-forwarding selects a Pod and is not evidence of ClusterIP load balancing.
Any destructive role-switch test belongs only in the separately authorized
work-computer acceptance procedure.
