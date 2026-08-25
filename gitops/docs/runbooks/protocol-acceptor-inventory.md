# Protocol acceptor inventory and retirement

Use this runbook to determine which Artemis client protocols a Workload Cell
must enable and which of those protocols need an out-of-cluster listener. A
configured Classic listener proves capability, not current use. A successful
TCP connection proves reachability, not application compatibility.

> **Live operations boundary:** This checkout is an offline/test copy. Run the
> runtime collection and Kubernetes inspection commands only from the
> authorized work computer against the exact approved host, context, cluster,
> and namespace. Sanitize hostnames, addresses, account identifiers,
> credentials, certificate identities, and client IPs before bringing evidence
> into this repository.

## Starting disposition

The repository begins with the following evidence, not a final production-use
conclusion:

| Acceptor | Port | Starting disposition | Reason |
| --- | ---: | --- | --- |
| `artemis` (`CORE,OPENWIRE`) | `61616` | Keep | CORE carries required broker peer traffic; OpenWire is the initial ActiveMQ Classic client migration interface. |
| `amqp` | `5672` | Keep provisionally | The validation and performance client exercises AMQP and the compatibility inventory marks it required, but production application use is not yet recorded. |
| `stomp` | `61613` | Removal candidate | The repository has compatibility and external-TLS test coverage but no identified application client. |
| `mqtt` | `1883` | Removal candidate | The repository defines the listener but has no identified application client. |
| `websocket` (STOMP over HTTP/WebSocket) | `61614` | Removal candidate | The repository defines the listener but has no identified application client. |

The `artemis` acceptor itself cannot be disabled because the chart requires
CORE on `61616` for the operator-managed peer connection. Removing OpenWire
from that acceptor is a separate post-migration decision and requires changing
its advisory configuration and proving that no Classic client remains.

Broker enablement and NLB exposure are separate decisions:

| State | Meaning |
| --- | --- |
| Disabled | The acceptor is absent from the broker custom resource, Service inventory, and client NetworkPolicy ports. |
| Enabled, cluster-only | The acceptor has an active-only `ClusterIP` Service but no shared-NLB listener. |
| Enabled and privately exposed | A proven out-of-cluster client has a dedicated shared-NLB listener and target group. |

Default to the narrowest state supported by evidence. Do not create an NLB
listener merely because an acceptor remains enabled during migration.

## Required evidence window

Inventory each Workload Cell separately. The observation window must include:

- normal business peaks;
- overnight and weekend batch processing;
- scheduled jobs with weekly or monthly cadence, or an owner-confirmed record
  for jobs that cannot be observed within the change window;
- reconnect behavior during a broker restart or planned failover test; and
- every old and new client population expected during migration overlap.

A single point-in-time zero connection count is not removal evidence. If the
window cannot cover a scheduled client and its owner cannot confirm its
configuration, record the protocol as `unknown` and keep it disabled from the
NLB but enabled on the broker until the gap is resolved.

## Phase 1: Build the declared inventory

For each source Classic broker and target Workload Cell, record:

1. every configured transport connector, bind port, TLS mode, and connection
   limit;
2. application connection URLs and client libraries from deployable
   configuration rather than copied secrets;
3. the owning application, technical contact, environment, schedule, and
   expected protocol;
4. whether the client runs inside EKS, elsewhere in the VPC, across connected
   networks, or through a future partner boundary; and
5. whether the client requires the protocol itself or merely uses its default
   port by convention.

Use the [Chef ActiveMQ import workflow](../chef-activemq-import.md) for supplied
legacy JSON. Its listener candidates still require current-use evidence. Search
authorized application configuration copies for protocol schemes and default
ports with a command shaped like:

```sh
rg -n --no-heading -S \
  '(failover:|tcp://|ssl://|amqp://|amqps://|stomp://|stomp\+ssl://|mqtt://|mqtts://|ws://|wss://|:(61616|5672|61613|1883|61614)\b)' \
  PATH_TO_SANITIZED_APPLICATION_CONFIGS
```

Review matches; do not copy credentials or complete internal URLs into the
evidence record.

## Phase 2: Observe runtime use

Prefer existing broker/JMX or platform monitoring that can report current and
peak connections per transport connector over the entire evidence window.
Record counts and timestamps, not client IPs or credentials.

When approved host access is the available evidence source, this read-only
snapshot counts established TCP connections by listener port:

```sh
for port in 61616 5672 61613 1883 61614; do
  connections=$(sudo ss -Htn state established "sport = :$port" | wc -l | tr -d ' ')
  printf '%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$port" "$connections"
done
```

To sample every five minutes, write only timestamp, port, and count to a local
evidence file on the authorized work computer and stop with `Ctrl-C` after the
approved window:

```sh
ARTEMIS_PROTOCOL_LOG="artemis-protocol-counts-$(date -u +%Y%m%dT%H%M%SZ).csv"
printf '%s\n' 'observed_at_utc,listener_port,established_connections' > "$ARTEMIS_PROTOCOL_LOG"
while :; do
  for port in 61616 5672 61613 1883 61614; do
    connections=$(sudo ss -Htn state established "sport = :$port" | wc -l | tr -d ' ')
    printf '%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$port" "$connections" >> "$ARTEMIS_PROTOCOL_LOG"
  done
  sleep 300
done
```

Host counts cannot identify protocol use when multiple protocols share one
acceptor, and they can miss very short connections between samples. Reconcile
them with broker connector metrics, application configuration, schedules, and
owner confirmation. For `61616`, treat the count as combined broker CORE and
OpenWire traffic; it cannot prove the OpenWire client count by itself.

## Phase 3: Classify each protocol

Use these outcomes:

| Outcome | Required evidence | Action |
| --- | --- | --- |
| `required-peer` | Broker architecture requires it, currently CORE on `61616`. | Keep enabled; never expose the peer-only purpose separately. |
| `required-client` | Runtime connection plus identified owner/configuration, or an owner-confirmed scheduled client not safely observable in the window. | Keep enabled; expose through the NLB only if the client is outside EKS. |
| `validation-only` | Repository tests use it but no production application does. | Keep only in the test cells that need it; do not expose it in production. |
| `unknown` | Declared listener or incomplete evidence with no accountable disposition. | Do not add NLB exposure; retain temporarily and assign an evidence owner and deadline. |
| `not-used` | Complete observation window shows no use, configuration search finds no client, and affected owners approve removal. | Disable per Workload Cell and execute the retirement test flow. |

Do not infer that AMQP is a production dependency solely because the
performance harness defaults to AMQP. Conversely, do not remove it from a test
cell that still uses that harness. STOMP, MQTT, and WebSocket begin as removal
candidates, not as pre-approved removals.

Record one row for every Workload Cell and protocol:

| Environment | Workload Cell | Protocol | Declared config | Runtime peak/window | Owner | Client location | Decision | NLB listener | Evidence reference |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Example | example-cell | OpenWire | Found | Pending | Example owner | Outside EKS | `unknown` | None | Sanitized ticket/report |

The completed record belongs with the approved change evidence. Update
[`classic-6.2.6-inventory.yaml`](../../tests/compatibility/classic-6.2.6-inventory.yaml)
only when the evidence changes a repository-wide compatibility conclusion;
pair-specific findings belong in the Workload Cell change review.

## Phase 4: Disable a removal candidate in non-production

Override the candidate in the Workload Cell values file rather than weakening
every cell at once:

```yaml
acceptors:
  stomp:
    enabled: false
  mqtt:
    enabled: false
  websocket:
    enabled: false
```

Disable AMQP only where the inventory classifies it as `not-used` or where its
known purpose is `validation-only` and the target is not a validation cell.
Never disable `acceptors.artemis`.

Run local repository validation:

```sh
make validate-charts
make validate-topology
make test-topology
make validate-docs
```

The rendered change must remove the acceptor from all of these surfaces:

- `ActiveMQArtemis.spec.acceptors`;
- its protocol-specific active-only Service;
- client NetworkPolicy allowed ports; and
- any planned shared-NLB listener, target group, DNS documentation, and
  `TargetGroupBinding`.

It must not change CORE/JGroups peer rules, the management console, monitoring,
or another Workload Cell.

## Phase 5: Collect runtime acceptance evidence

After the reviewed change reaches the authorized non-production environment,
set exact identifiers and confirm them before using these read-only commands:

```sh
KUBE_CONTEXT='APPROVED_CONTEXT'
WORKLOAD_NAMESPACE='APPROVED_ARTEMIS_NAMESPACE'
BROKER_CR='APPROVED_BROKER_CR'

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get activemqartemis "$BROKER_CR" -o json |
  jq -r '.spec.acceptors[] | [.name, .port, .protocols] | @tsv'

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get services

kubectl --context "$KUBE_CONTEXT" --namespace "$WORKLOAD_NAMESPACE" \
  get networkpolicies -o yaml
```

Then prove:

1. every retained client protocol completes its representative send, receive,
   acknowledgement, reconnect, and failover behavior;
2. the removed protocol has no Service endpoint, NLB listener, or successful
   connection path;
3. broker activation, replication, discovery, failure detection, console, and
   monitoring remain healthy;
4. logs and metrics show no repeated connection attempts to the retired port;
5. the soak period covers the application's normal peak and relevant scheduled
   work; and
6. the evidence contains no credentials, message bodies, client IPs, or other
   sensitive identifiers.

A negative `nc` result alone is not sufficient; it must agree with the
rendered resources, platform listener inventory, broker configuration, and
positive tests for retained clients.

## Promotion and rollback

Promote one Workload Cell at a time. Do not change the reusable standard
Profile until every consuming cell has an explicit, reviewed protocol
disposition; otherwise one Profile edit can remove a listener from unrelated
clients.

Rollback through the same GitOps value by restoring `enabled: true` for the
specific acceptor and, when applicable, its reserved shared-NLB allocation.
Do not manually add an acceptor, Service, target, or listener in the live
environment. Keep a retired frontend port reserved until the documented client
and DNS retention window expires so rollback cannot route to a different
Workload Cell.

Close the change only after the inventory row records the final decision,
runtime evidence, owner approval, and whether the protocol is disabled,
cluster-only, or privately exposed.

