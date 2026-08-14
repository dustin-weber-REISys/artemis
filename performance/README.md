# Performance and validation

This area owns the deterministic JMS validation client and reusable load
profiles. The same client can run against the standalone broker under
[`local`](../local) or an explicitly supplied deployed endpoint.

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
destructive confirmations:

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
- producer, consumer, and fault logs.

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
