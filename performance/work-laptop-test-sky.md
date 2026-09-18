# Run the performance and failover validations against test-SKY

Run these commands only from the authorized work computer. The procedure uses
the repository's serial validation client and the supervised two-pod tunnel.
The tunnel is local diagnostic plumbing: it does not expose a broker service
and does not prove production NLB, Service routing, NetworkPolicy, ingress
CIDR, cross-AZ network, or throughput behavior.

## 1. Select and verify the target

Replace every placeholder with the approved test-SKY value:

~~~sh
cd /path/to/Artemis

export ARTEMIS_CONTEXT='REPLACE_WITH_APPROVED_TEST_CONTEXT'
export ARTEMIS_CLUSTER='REPLACE_WITH_APPROVED_TEST_EKS_CLUSTER'
export ARTEMIS_NAMESPACE='artemis-int-sky'
export ARTEMIS_BROKER_CR='test-sky-artemis-artemis-ha'
export ARTEMIS_CREDENTIAL_SECRET="$ARTEMIS_BROKER_CR-credentials-secret"
export ARTEMIS_BROKER_SELECTOR='app.kubernetes.io/component=broker'
export PERF_DESTINATION='performance.validation'
~~~

Authenticate with the approved company AWS/EKS workflow, then stop unless
both confirmations pass:

~~~sh
actual_cluster=$(kubectl config view --minify --context "$ARTEMIS_CONTEXT" \
  -o jsonpath='{.clusters[0].name}')

printf 'context=%s\nexpected-cluster=%s\nactual-cluster=%s\n' \
  "$ARTEMIS_CONTEXT" "$ARTEMIS_CLUSTER" "$actual_cluster"

test "$(kubectl config current-context)" = "$ARTEMIS_CONTEXT"
test "$actual_cluster" = "$ARTEMIS_CLUSTER"
~~~

## 2. Check tools, broker health, and the disposable queue

~~~sh
command -v kubectl docker yq
docker version
kubectl version --client
yq --version

kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get activemqartemis "$ARTEMIS_BROKER_CR"

kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get pods -l "$ARTEMIS_BROKER_SELECTOR" -o wide
~~~

Expect exactly two ready broker replicas. The tunnel selects those two pods
and checks each pod UID before accepting a forward.

Confirm that the durable destination is already declared:

~~~sh
kubectl --context "$ARTEMIS_CONTEXT" -n "$ARTEMIS_NAMESPACE" \
  get activemqartemis "$ARTEMIS_BROKER_CR" -o json |
  yq -e '
    .spec.brokerProperties[] |
    select(. == "addressConfigurations.\"performance.validation\".routingTypes=ANYCAST")
  '
~~~

If this fails, stop. Add the destination through the normal reviewed GitOps
process and repeat the check. Do not use an application-owned queue.

## 3. Load credentials privately

Use an approved validation identity from Vault when one exists. Do not enable
shell tracing and do not print either value:

~~~sh
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
~~~

## 4. Run a tunneled performance profile

Build or verify the local validation image before starting the run:

~~~sh
make -C performance build-local-image IMAGE=artemis-validation-client:local
~~~

The runner creates two local listeners, 25672 and 25673 by default, and gives
both the producer and consumer one provider-specific failover URL. It binds
only 127.0.0.1, adds the Docker host-gateway mapping, restarts a forward after
process death or pod replacement, and cleans up both forwards on exit.

Run the burst profile first:

~~~sh
export PERF_PROTOCOL=amqp
export PERF_REPORT_ROOT="$PWD/reports/test-sky-$(date -u +%Y%m%dT%H%M%SZ)"

./performance/run-profile.sh \
  --target tunneled \
  --context "$ARTEMIS_CONTEXT" \
  --cluster "$ARTEMIS_CLUSTER" \
  --namespace "$ARTEMIS_NAMESPACE" \
  --broker-selector "$ARTEMIS_BROKER_SELECTOR" \
  --profile burst \
  --tunnel-port-a 25672 \
  --tunnel-port-b 25673 \
  --report-dir "$PERF_REPORT_ROOT"
~~~

After burst passes, run sustained during the approved window with a new
report directory:

~~~sh
export PERF_REPORT_ROOT="$PWD/reports/test-sky-sustained-$(date -u +%Y%m%dT%H%M%SZ)"

./performance/run-profile.sh \
  --target tunneled \
  --context "$ARTEMIS_CONTEXT" \
  --cluster "$ARTEMIS_CLUSTER" \
  --namespace "$ARTEMIS_NAMESPACE" \
  --broker-selector "$ARTEMIS_BROKER_SELECTOR" \
  --profile sustained \
  --report-dir "$PERF_REPORT_ROOT"
~~~

For TLS, set PERF_TLS=true, PERF_TLS_HOSTNAME to the broker certificate
hostname, and the trust-store variables before adding
--tunnel-tls --tls-hostname to the command:

~~~sh
export PERF_TLS=true
export PERF_TLS_HOSTNAME='REPLACE_WITH_BROKER_CERTIFICATE_HOSTNAME'
export PERF_TRUST_STORE_PATH='/private/path/to/truststore.p12'
export PERF_TRUST_STORE_PASSWORD='REPLACE_WITH_TRUSTSTORE_PASSWORD'
export PERF_TRUST_STORE_TYPE='PKCS12'
~~~

The certificate hostname is used for SNI and hostname verification.
host.docker.internal is only the Docker-to-host route and must not be used as
the certificate name.

## 5. Plan and execute the destructive failover validation

The failure runner is plan-only until the exact context, cluster, and
namespace are repeated as confirmation flags. Use a fresh report directory:

~~~sh
export FAILURE_REPORT_ROOT="$PWD/reports/test-sky-failure-$(date -u +%Y%m%dT%H%M%SZ)"

./performance/run-failure-test.sh \
  --context "$ARTEMIS_CONTEXT" \
  --cluster "$ARTEMIS_CLUSTER" \
  --namespace "$ARTEMIS_NAMESPACE" \
  --profile sustained \
  --fault process-kill \
  --double-failover \
  --tunnel \
  --fault-after-acknowledged 1000 \
  --repeat-interval-seconds 30 \
  --report-dir "$FAILURE_REPORT_ROOT"
~~~

Review the plan. If a time-based trigger is required, use
--fault-after-seconds N instead of --fault-after-acknowledged N; the modes are
mutually exclusive. Then execute the approved run:

~~~sh
./performance/run-failure-test.sh \
  --context "$ARTEMIS_CONTEXT" \
  --cluster "$ARTEMIS_CLUSTER" \
  --namespace "$ARTEMIS_NAMESPACE" \
  --profile sustained \
  --fault process-kill \
  --double-failover \
  --tunnel \
  --fault-after-acknowledged 1000 \
  --repeat-interval-seconds 30 \
  --report-dir "$FAILURE_REPORT_ROOT" \
  --execute \
  --confirm-context "$ARTEMIS_CONTEXT" \
  --confirm-cluster "$ARTEMIS_CLUSTER" \
  --confirm-namespace "$ARTEMIS_NAMESPACE"
~~~

Use --fault pod-delete only when pod replacement, rather than broker-process
restart, is the intended fault. The tunneled failure runner requires
PERF_USERNAME and PERF_PASSWORD but does not require PERF_URL.

## 6. Verify and preserve evidence

~~~sh
performance_report=$(find "$PERF_REPORT_ROOT" -name run.json -print -quit)
yq -e '
  .target == "tunneled" and
  .tunnel.mode == "kubectl-port-forward"
' "$performance_report"

failure_report=$(find "$FAILURE_REPORT_ROOT" -name failure-run.json -print -quit)
yq -e '
  .status == "PASS" and
  .rpoStatus == "PASS" and
  .connection.mode == "kubectl-port-forward" and
  .clientRecovery.first.recoveredAt != null and
  .clientRecovery.second.recoveredAt != null
' "$failure_report"

printf 'Performance evidence: %s\n' "$PERF_REPORT_ROOT"
printf 'Failover evidence: %s\n' "$FAILURE_REPORT_ROOT"
~~~

Preserve the report directories. The tunnel evidence is under the run's
tunnel directory: tunnel.env, tunnel-status.env, supervisor.log, and the
per-pod port-forward logs. The failure report separates broker activation
timing from the client recovery timing represented by the first acknowledged
send after each fault.

## 7. Clean up local secrets

The runners clean up their supervised forwards on normal completion and
interrupt. After preserving the reports:

~~~sh
unset PERF_PASSWORD PERF_USERNAME PERF_URL PERF_TRUST_STORE_PASSWORD
unset PERF_TLS PERF_TLS_HOSTNAME PERF_TRUST_STORE_PATH PERF_TRUST_STORE_TYPE
unset PERF_REPORT_ROOT FAILURE_REPORT_ROOT
~~~
