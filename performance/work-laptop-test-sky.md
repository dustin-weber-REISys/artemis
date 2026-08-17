# Run the performance client against test-SKY

Run these commands only from the authorized work computer. This procedure uses
the repository's serial validation client through a local port-forward. It is
not the destructive failover test.

## 1. Open the repository and set the target

Replace the first two values with the approved test-cluster identifiers.

```sh
cd /path/to/Artemis

export ARTEMIS_CONTEXT='REPLACE_WITH_APPROVED_TEST_CONTEXT'
export ARTEMIS_CLUSTER='REPLACE_WITH_APPROVED_TEST_EKS_CLUSTER'
export ARTEMIS_NAMESPACE='artemis-int-sky'
export ARTEMIS_BROKER_CR='test-sky-artemis-artemis-ha'
export ARTEMIS_AMQP_SERVICE="${ARTEMIS_BROKER_CR}-amqp"
export ARTEMIS_CREDENTIAL_SECRET="${ARTEMIS_BROKER_CR}-credentials-secret"
export PERF_DESTINATION='performance.validation'
```

Authenticate with the approved company AWS/EKS workflow. Then verify that the
context selects the intended cluster:

```sh
actual_cluster=$(
  kubectl config view --minify --context "$ARTEMIS_CONTEXT" \
    -o jsonpath='{.clusters[0].name}'
)

printf 'context=%s\nexpected-cluster=%s\nactual-cluster=%s\n' \
  "$ARTEMIS_CONTEXT" "$ARTEMIS_CLUSTER" "$actual_cluster"

test "$actual_cluster" = "$ARTEMIS_CLUSTER"
```

Stop if the last command fails.

## 2. Check prerequisites and test-SKY health

```sh
docker version
kubectl version --client
yq --version
helm version

kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get activemqartemis "$ARTEMIS_BROKER_CR"

kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get statefulset "${ARTEMIS_BROKER_CR}-ss"

kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get service "$ARTEMIS_AMQP_SERVICE"

kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get endpointslice \
  -l "kubernetes.io/service-name=$ARTEMIS_AMQP_SERVICE"
```

Expect two ready broker replicas and a ready AMQP service endpoint.

## 3. Confirm the disposable queue is declared

```sh
kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get activemqartemis "$ARTEMIS_BROKER_CR" -o json |
  yq -e '
    .spec.brokerProperties[] |
    select(. == "addressConfigurations.\"performance.validation\".routingTypes=ANYCAST")
  '
```

If that command fails, stop. Add this destination to
`gitops/workloads/test/test-sky/artemis-values.yaml` through the normal reviewed
GitOps process, allow Argo CD to reconcile it, and repeat the check:

```yaml
destinations:
  performance-validation:
    address: performance.validation
    routingTypes:
      - ANYCAST
    queues:
      - name: performance.validation
        routingType: ANYCAST
        durable: true
        maxConsumers: -1
        purgeOnNoConsumers: false
```

Do not use an application-owned queue.

## 4. Load the broker credentials

Use an approved validation identity from Vault when one exists. For the initial
operator-generated credential, use a private terminal and do not enable shell
tracing:

```sh
set +x

PERF_USERNAME=$(
  kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
    get secret "$ARTEMIS_CREDENTIAL_SECRET" \
    -o jsonpath='{.data.AMQ_USER}' |
  base64 --decode
)

PERF_PASSWORD=$(
  kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
    get secret "$ARTEMIS_CREDENTIAL_SECRET" \
    -o jsonpath='{.data.AMQ_PASSWORD}' |
  base64 --decode
)

export PERF_USERNAME PERF_PASSWORD
```

Do not print either value.

## 5. Start the tunnel

```sh
export PERF_PORT_FORWARD_LOG="${TMPDIR:-/tmp}/test-sky-amqp-port-forward.log"
kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  port-forward "service/$ARTEMIS_AMQP_SERVICE" 25672:5672 \
  >"$PERF_PORT_FORWARD_LOG" 2>&1 &

export PERF_PORT_FORWARD_PID=$!
trap 'kill "$PERF_PORT_FORWARD_PID" 2>/dev/null || true' EXIT INT TERM
sleep 2
kill -0 "$PERF_PORT_FORWARD_PID"
nc -vz 127.0.0.1 25672
```

Stop and inspect `$PERF_PORT_FORWARD_LOG` if either check fails.

## 6. Run the client

```sh
cd /path/to/Artemis

export PERF_URL='amqp://host.docker.internal:25672'
export PERF_PROTOCOL='amqp'
export PERF_DESTINATION='performance.validation'
export PERF_REPORT_ROOT="reports/test-sky-$(date -u +%Y%m%dT%H%M%SZ)"

REPORT_DIR="$PERF_REPORT_ROOT" \
  make performance-deployed PROFILE=burst
```

After `burst` passes, run the same 100,000-message validation with the
`sustained` report profile during the approved window:

```sh
export PERF_REPORT_ROOT="reports/test-sky-$(date -u +%Y%m%dT%H%M%SZ)"

REPORT_DIR="$PERF_REPORT_ROOT" \
  make performance-deployed PROFILE=sustained
```

Do not run `two-million-capacity` against test-SKY. Its approximately 244 GiB
payload exceeds the cell's 20 GiB storage allocation.

## 7. Verify and clean up

```sh
yq -e '
  .status == "PASS" and
  .acknowledgedCount == .requestedCount and
  .acknowledgementFailures == 0
' "$PERF_REPORT_ROOT/performance/send.json"

yq -e '
  .status == "PASS" and
  .rpoStatus == "PASS" and
  .receivedCount == .expectedCount and
  (.missingSequences | length) == 0 and
  (.unexpectedSequences | length) == 0
' "$PERF_REPORT_ROOT/performance/consume.json"

test "$(wc -l < "$PERF_REPORT_ROOT/performance/acknowledged.tsv" | tr -d ' ')" = 100000

printf 'Reports: %s/performance\n' "$PERF_REPORT_ROOT"

unset PERF_PASSWORD PERF_USERNAME PERF_URL

kill "$PERF_PORT_FORWARD_PID"
wait "$PERF_PORT_FORWARD_PID" 2>/dev/null || true
trap - EXIT INT TERM
unset PERF_PORT_FORWARD_PID PERF_PORT_FORWARD_LOG
```

Preserve the report directory as test evidence.
