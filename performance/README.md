# Performance and validation

This area owns the deterministic JMS validation client and reusable load
profiles. The same client can run against the standalone broker under
[`local`](../local), an explicitly supplied deployed endpoint, or two
supervised pod-local forwards on an authorized work computer.

The current runner sends a deterministic persistent backlog with the profile's
exact UTF-8 `payloadBytes`, then consumes it while recording timing and
correctness reports. It is serial and rejects any profile whose producer or
consumer concurrency is not `1`. `durationSeconds` remains a target and report
field rather than a pacing control.

The `two-million-capacity` profile exercises the provisional stored-payload
envelope with two million 128-KiB bodies. It is a storage-volume scenario, not
production throughput evidence; promotion still requires production-derived
message-size distributions, concurrency, rates, paging, replication, and
drain-time measurements.

The validation client overrides provider URI options that would weaken the
evidence boundary: OpenWire and AMQP sends are forced synchronous, AMQP
producers are unsettled, and asynchronous acknowledgement options are disabled.
A normal persistent `send()` return is therefore the client-side
broker-acknowledgement boundary used by the reports.

## Local target

Start the broker, then run a profile from the repository root:

```sh
make local-up
make performance-local PROFILE=burst
```

The container connects through `host.docker.internal`. Override the local port
or protocol when needed:

```sh
ARTEMIS_AMQP_PORT=25672 PERF_PROTOCOL=amqp \
  make performance-local PROFILE=sustained
```

## Deployed target

Supply connection details only at runtime:

```sh
PERF_URL='amqps://broker.example.invalid:5671' \
PERF_USERNAME="$ARTEMIS_TEST_USER" \
PERF_PASSWORD="$ARTEMIS_TEST_PASSWORD" \
  make performance-deployed PROFILE=sustained
```

`PERF_PROTOCOL` defaults to the selected profile's protocol and may be
`amqp` or `openwire`. `PERF_DESTINATION` defaults to a queue named for the
profile. Credentials and the broker URL are passed to the transient client
container and are not written to the generated reports.

Reports are written under `reports/performance` by default:

- `send.json`: broker-acknowledged persistent-send baseline;
- `acknowledged.tsv`: force-synchronized external ledger written after each
  successful persistent send;
- `consume.json`: missing, duplicate, reordered, and redelivery findings;
- `run.json`: non-secret target and profile metadata.

## Supervised two-pod tunnel

Use `tunneled` when the validation client must reach the two HA broker pods
from a work laptop without exposing a broker service publicly. The supervisor
selects exactly two pods, binds two local loopback ports, and gives both the
producer and consumer one provider-specific failover URL:

- AMQP uses `amqp://host.docker.internal:25672` and `:25673`;
- OpenWire uses `tcp://host.docker.internal:25672` and `:25673`;
- reconnect attempts are unbounded for the run, with short initial and
  bounded retry delays; and
- a child `kubectl port-forward` is restarted only after the pod is Running
  again and its UID is checked.

Run these checks and the non-destructive plan on the authorized work
computer. Replace every placeholder before continuing:

```sh
export ARTEMIS_CONTEXT='REPLACE_WITH_APPROVED_TEST_CONTEXT'
export ARTEMIS_CLUSTER='REPLACE_WITH_APPROVED_TEST_EKS_CLUSTER'
export ARTEMIS_NAMESPACE='REPLACE_WITH_BROKER_NAMESPACE'
export ARTEMIS_BROKER_SELECTOR='app.kubernetes.io/component=broker'

test "$(kubectl config current-context)" = "$ARTEMIS_CONTEXT"
test "$(kubectl config view --minify --context "$ARTEMIS_CONTEXT" \
  -o jsonpath='{.clusters[0].name}')" = "$ARTEMIS_CLUSTER"

kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get pods -l "$ARTEMIS_BROKER_SELECTOR" -o wide

./performance/run-profile.sh \
  --target tunneled \
  --context "$ARTEMIS_CONTEXT" \
  --cluster "$ARTEMIS_CLUSTER" \
  --namespace "$ARTEMIS_NAMESPACE" \
  --broker-selector "$ARTEMIS_BROKER_SELECTOR" \
  --profile burst \
  --report-dir "$PWD/reports/tunneled-$(date -u +%Y%m%dT%H%M%SZ)"
```

The tunneled target requires `PERF_USERNAME` and `PERF_PASSWORD`. Set
`PERF_PROTOCOL=amqp` or `openwire` when overriding the profile default. Use
`--tunnel-port-a` and `--tunnel-port-b` to choose different unused local
ports. Docker receives the `host.docker.internal` host-gateway mapping
automatically.

For TLS, provide the broker certificate hostname and a trust store that the
client container can mount:

```sh
export PERF_TLS=true
export PERF_TLS_HOSTNAME='REPLACE_WITH_BROKER_CERTIFICATE_HOSTNAME'
export PERF_TRUST_STORE_PATH='/private/path/to/truststore.p12'
export PERF_TRUST_STORE_PASSWORD='REPLACE_WITH_TRUSTSTORE_PASSWORD'
export PERF_TRUST_STORE_TYPE='PKCS12'
```

Then add `--tunnel-tls --tls-hostname "$PERF_TLS_HOSTNAME"` to the runner
command. The TLS endpoint uses the certificate hostname for SNI and hostname
verification; `host.docker.internal` is only the Docker-to-host route and
must not be used as the certificate name.

The tunnel is intentionally local diagnostic plumbing. It does not exercise a
production NLB, Service routing, NetworkPolicy, ingress CIDR, cross-AZ network
path, or production throughput. Each run records `tunnel/tunnel.env`,
`tunnel/tunnel-status.env`, `tunnel/supervisor.log`, and per-pod
`kubectl port-forward` logs under the report directory. The supervisor shuts
down both forwards when the runner exits.

## Destructive failover test

`run-failure-test.sh` reuses the same profile catalog and validation client
under continuous producer load. It:

1. verifies two Running broker pods, separate PVCs and AZs, and an EBS CSI
   StorageClass using `WaitForFirstConsumer`, `Retain`, and volume expansion;
2. confirms exactly one broker reports `Active=true`;
3. starts the persistent producer and waits for the force-synchronized
   acknowledgement ledger to cross a threshold;
4. sends `SIGKILL` to PID 1 in the active broker container, or force-deletes
   the active pod;
5. observes actual Jolokia `Active` state for replacement activation and
   split brain; and
6. consumes the backlog and reconciles missing sequences against the external
   acknowledgement ledger.

Add `--double-failover` to exercise both directions in one run. After the
first active broker fails and its peer takes over, the harness waits for the
original broker process or pod to be replaced, verifies it reports
`Active=false` and `ReplicaSync=true`, and requires a successful send through
the replacement active. It then fails that active broker, verifies the
original broker becomes active, and requires another successful send before
message reconciliation.

The script is plan-only unless all three cluster identifiers are repeated as
destructive confirmations. Plan the exact run first:

```sh
./performance/run-failure-test.sh \
  --context example-eks \
  --cluster example-eks-cluster \
  --namespace example-messaging \
  --profile sustained \
  --fault process-kill \
  --double-failover \
  --tunnel \
  --fault-after-acknowledged 1000 \
  --repeat-interval-seconds 30
```

Then execute it with the same identifiers repeated as confirmations:

```sh
PERF_USERNAME="$ARTEMIS_TEST_USER" \
PERF_PASSWORD="$ARTEMIS_TEST_PASSWORD" \
  make -C performance failure-tunneled \
    CONTEXT=example-eks \
    CLUSTER=example-eks-cluster \
    NAMESPACE=example-messaging \
    PROFILE=sustained \
    FAILURE_ARGS='--fault process-kill --double-failover --fault-after-acknowledged 1000 --repeat-interval-seconds 30 --execute --confirm-context example-eks --confirm-cluster example-eks-cluster --confirm-namespace example-messaging'
```

Use `--fault-after-seconds N` instead of
`--fault-after-acknowledged N` when a time-based trigger is required; the two
trigger modes are mutually exclusive. `--repeat-interval-seconds N` applies
only to double failover and prevents the second destructive action until the
specified interval has elapsed. Use `--fault pod-delete` only when pod
replacement, rather than broker-process restart, is the behavior under test.

The tunneled failure command requires `PERF_USERNAME` and `PERF_PASSWORD`, but
does not require `PERF_URL`. `PERF_TLS=true` plus `PERF_TLS_HOSTNAME` selects the
TLS tunnel; add a trust-store path and password when the client image does
not already trust the broker CA.

The direct deployed form remains available when a separately approved
endpoint is the subject of the test:

```sh
PERF_URL='failover:(amqps://broker.example.invalid:5671)?failover.maxReconnectAttempts=-1' \
PERF_USERNAME="$ARTEMIS_TEST_USER" \
PERF_PASSWORD="$ARTEMIS_TEST_PASSWORD" \
  ./performance/run-failure-test.sh \
    --context example-eks \
    --cluster example-eks-cluster \
    --namespace example-messaging \
    --profile sustained \
    --fault process-kill \
    --double-failover \
    --execute \
    --confirm-context example-eks \
    --confirm-cluster example-eks-cluster \
    --confirm-namespace example-messaging
```

Use a disposable, pre-created durable queue. The connection URL must include
the provider's failover/reconnect transport behavior; the client pins send
settlement but does not invent environment-specific endpoints.

Each execution gets its own directory under `reports/failure` with:

- `failure-run.json`: final PASS/FAIL, zero-RPO verdict, activation timing, and
  message accounting, including sent/ambiguous, received, uniquely processed,
  acknowledged, duplicate, redelivered, and missing counts. Double-failover
  reports include the ordered `faults` array for A-to-B and B-to-A evidence;
- `acknowledged.tsv`: the external producer acknowledgement ledger;
- `send.json` and `consume.json`: raw validation-client reports;
- `preflight.json`: pod, zone, PVC, and StorageClass evidence; and
- producer, consumer, and fault logs. Tunneling runs also include the
  supervisor environment/status files, supervisor log, and per-pod
  port-forward logs.

The report keeps broker activation timing separate from client recovery:
`activation.recoveryDurationSeconds` measures the observed broker leader
transition, while `clientRecovery.first` and (for double failover)
`clientRecovery.second` measure the first post-fault acknowledged send.
`connection.mode`, `faultTrigger`, and the `connection` tunnel fields record
whether the run used direct connectivity or supervised local forwards.

A PASS means this run had no missing definitely acknowledged ID, no observed
split brain, consistent ledger/report counts, and recovery within the profile
target. In double-failover mode it also means the original peer rejoined and
reported synchronized before the second fault, both leader transitions
occurred, and sends were acknowledged after each transition. It does not prove
remote replica `fsync` or establish a general production zero-RPO guarantee.

## Client development

```sh
make -C performance test
make -C performance package
```

The promotion Dockerfile uses explicit build and runtime image version tags.

The local image normally builds the client entirely inside Docker. If the
container trust store cannot reach Maven Central, the build helper falls back
to host Maven and a runtime-only Docker build. This fallback requires Maven 3.9
and Java 17 on the host.
