# Internal CIDR client onboarding

Use this guide to admit internal application clients to an Artemis Workload
Cell. Internal messaging connections intentionally do not authenticate to the
broker. Kubernetes NetworkPolicy is the access boundary, backed by the
platform network path and the smallest approved source CIDR ranges.

> **Live operations boundary:** This checkout is an offline/test copy. Inspect
> load balancers, VPC routes, pod-observed source addresses, and NetworkPolicy
> behavior only from the authorized work computer. Do not commit real internal
> ranges to this sanitized copy.

## Current decision

As of 2026-08-20:

- Workload Cells with `trafficClass: internal` render
  `spec.deploymentPlan.requireLogin: false`. The currently deferred `batch`
  traffic class follows the same network-admitted policy when used.
- Their standard non-TLS messaging acceptors remain available, including the
  required CORE/OpenWire acceptor on port `61616`.
- Approved CIDRs are configured through `networkPolicy.clientCidrs`. Each CIDR
  can reach every enabled messaging acceptor, but not the console or metrics
  port.
- The chart remains deny-by-default when no client selector or CIDR is
  configured.
- Human console authentication and management authorization remain separate;
  this decision removes messaging-client login, not the Keycloak/Hawtio control.
- External messaging authentication and mTLS are deferred. See
  [Deferred external authentication](#deferred-external-authentication).

CIDR admission identifies a network source, not an application principal. A
client inside an approved range receives the same broker access as other
clients in that range. Keep destination creation declarative and keep the
approved ranges as narrow as the actual routing path permits.

## Repository ownership

Use the pair-owned values file when ranges differ by Workload Cell:

```text
gitops/workloads/<environment>/<workloadCellName>/artemis-values.yaml
```

```yaml
networkPolicy:
  clientCidrs:
    example-application: 192.0.2.0/24 # documentation range only
```

Use the environment overlay only when the same range is approved for every
Artemis Workload Cell in that environment:

```text
gitops/environments/<environment>/artemis-values.yaml
```

The keyed maps are Helm-composed. Do not put internal ranges in the chart
defaults or broaden an environment range to cover unrelated pair-specific
callers. In-cluster clients may instead use the narrower selector form:

```yaml
networkPolicy:
  clientSources:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: PLACEHOLDER_CLIENT_NAMESPACE
      podSelector:
        matchLabels:
          app.kubernetes.io/name: PLACEHOLDER_CLIENT_APPLICATION
```

The map keys are stable review IDs, so environment and Workload Cell layers
deep-merge without one list replacing another. The chart accepts IPv4 CIDR
notation and derives the allowed ports from the enabled `acceptors` map.
Console and monitoring sources continue to use `managementSources`,
`monitoringSources`, or a reviewed purpose-specific `extraIngress` rule.

## Establish the effective source range

Before editing values, determine the source address the broker pod will
actually observe. Private load balancers, Kubernetes Services, NAT, and routing
components may preserve or translate the original address.

From the authorized work computer:

1. Identify the private client-to-Service path and whether it preserves source
   IPs.
2. Capture a broker-side connection sample in the test environment using the
   approved observability method.
3. Reconcile the observed addresses with the platform-owned subnet inventory.
4. Select the smallest stable approved CIDR or set of CIDRs. Do not use an
   entire VPC range when only one application subnet is needed.

If the observed address is a node, load-balancer, or NAT address rather than
the original client, authorize that exact infrastructure range and record the
translation in the change evidence.

## Validate before promotion

Run local repository validation:

```sh
make validate-charts
make validate-topology
```

Review the rendered NetworkPolicy and confirm each approved CIDR is restricted
to the enabled messaging ports. The broker custom resource for an internal
cell must render `requireLogin: false` and must not mount a client JAAS Secret.

Then collect runtime evidence from the authorized test environment:

1. A client from every approved CIDR connects without credentials and performs
   its inventoried messaging operations.
2. A client outside every approved CIDR cannot establish a TCP connection.
3. The console and metrics port remain unreachable through the client CIDR
   rule.
4. Disabled acceptor ports remain unreachable.
5. Broker discovery, replication, failover, readiness, and recovery remain
   healthy; the peer-only policy still owns CORE/JGroups traffic.
6. The captured pod-observed source IP matches the documented assumption.

These checks prove both halves of the control: the repository renders the
intended CIDR and the live network path presents the address that policy
actually evaluates.

## Deferred external authentication

External Workload Cells are not currently enabled. Their traffic class is
already wired to render `requireLogin: true`, but they must not be enabled until
all of the following are implemented and runtime-tested:

- a dedicated TLS acceptor and private exposure path;
- externally materialized broker TLS, client trust, and `*-jaas-config`
  Secrets;
- client-certificate or approved credential mapping to Artemis roles;
- typed authorization rules and per-listener network source scoping;
- certificate/credential rotation and revocation behavior; and
- positive, unauthorized, untrusted, expired, failover, and rollback tests.

JAAS, authorization, and mTLS listener values may be committed and validated
while an external Workload Cell remains disabled. Enablement is a separate
topology change after the runtime gates above are satisfied. The chart rejects
enabled external cells without that security shape, requires non-peer listeners
to use mTLS or be disabled, and rejects the internal all-acceptor CIDR/selector
interfaces for external traffic.

The sanitized external fixture at
[`external-mtls-values.yaml`](../../charts/artemis-ha/tests/fixtures/external-mtls-values.yaml)
keeps the chart capability executable. The broader design remains in
[`classic-external-security-migration.md`](../classic-external-security-migration.md)
and [`external-client-mtls-modernization.html`](../external-client-mtls-modernization.html).
