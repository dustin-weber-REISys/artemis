# Performance and validation

This area owns the deterministic JMS validation client and reusable load
profiles. The same client can run against the standalone broker under
[`local`](../local) or an explicitly supplied deployed endpoint.

The current runner sends a deterministic persistent backlog and then consumes
it while recording the client timing and correctness reports. It provides a
repeatable throughput baseline, but it does not yet implement the profile's
producer/consumer concurrency or hold the workload open for
`durationSeconds`. Those fields remain acceptance guidance for a production
performance harness.

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
- `consume.json`: missing, duplicate, reordered, and redelivery findings;
- `run.json`: non-secret target and profile metadata.

## Client development

```sh
make -C performance test
make -C performance package
```

The promotion Dockerfile requires digest-pinned build and runtime images.

The local image normally builds the client entirely inside Docker. If the
container trust store cannot reach Maven Central, the build helper falls back
to host Maven and a runtime-only Docker build. This fallback requires Maven 3.9
and Java 17 on the host.
