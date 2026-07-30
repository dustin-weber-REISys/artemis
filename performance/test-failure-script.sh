#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runner="$script_dir/run-failure-test.sh"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-failure-script.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_exit() {
  local expected=$1
  shift
  local actual
  if "$@" > "$temp_dir/stdout" 2> "$temp_dir/stderr"; then
    actual=0
  else
    actual=$?
  fi
  if [[ "$actual" != "$expected" ]]; then
    sed -n '1,160p' "$temp_dir/stdout" >&2
    sed -n '1,160p' "$temp_dir/stderr" >&2
    fail "expected exit $expected, got $actual: $*"
  fi
}

expect_exit 0 "$runner" \
  --context test-context \
  --cluster test-cluster \
  --namespace test-namespace \
  --profile sustained \
  --fault process-kill
grep -Fq 'No cluster or broker action was executed.' "$temp_dir/stdout" ||
  fail 'dry-run did not state its non-destructive behavior'
grep -Fq 'reconcile only definitely acknowledged IDs' "$temp_dir/stdout" ||
  fail 'dry-run omitted acknowledged-ID reconciliation'

expect_exit 0 "$runner" \
  --context test-context \
  --cluster test-cluster \
  --namespace test-namespace \
  --profile sustained \
  --fault process-kill \
  --double-failover
grep -Fq 'wait for the original active pod to restart, return passive, and report ReplicaSync=true' \
  "$temp_dir/stdout" ||
  fail 'double-failover dry-run omitted the synchronized rejoin gate'
grep -Fq 'inject a second process-kill into the new active' "$temp_dir/stdout" ||
  fail 'double-failover dry-run omitted the second fault'

expect_exit 2 "$runner" \
  --context test-context \
  --cluster test-cluster \
  --namespace test-namespace \
  --fault unsafe-fault
grep -Fq -- '--fault must be process-kill or pod-delete' "$temp_dir/stderr" ||
  fail 'invalid fault did not fail closed'

expect_exit 2 "$runner" \
  --context test-context \
  --cluster test-cluster \
  --namespace test-namespace \
  --profile burst \
  --fault-after-acknowledged 100000
grep -Fq 'must be less than profile message count 100000' "$temp_dir/stderr" ||
  fail 'invalid acknowledgement threshold was accepted'

fake_bin="$temp_dir/bin"
mkdir -p "$fake_bin"
state_file="$temp_dir/active-state"
printf '%s\n' before > "$state_file"

cat > "$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
case "$joined" in
  'config current-context')
    printf '%s' test-context
    ;;
  'config view --minify --context test-context -o jsonpath={.clusters[0].name}')
    printf '%s' test-cluster
    ;;
  *' get namespace test-namespace')
    printf '%s\n' test-namespace
    ;;
  *' get pods -l '*' -o json')
    printf '%s\n' '{"items":[
      {"metadata":{"name":"broker-0"},"status":{"phase":"Running"},"spec":{"containers":[{"name":"broker","ports":[{"containerPort":61616}]}]}},
      {"metadata":{"name":"broker-1"},"status":{"phase":"Running"},"spec":{"containers":[{"name":"broker","ports":[{"containerPort":61616}]}]}}
    ]}'
    ;;
  *' get pods -l '*' -o name')
    printf '%s\n' pod/broker-0 pod/broker-1
    ;;
  *' get pod broker-0 -o jsonpath={.spec.nodeName}')
    printf '%s' node-0
    ;;
  *' get pod broker-1 -o jsonpath={.spec.nodeName}')
    printf '%s' node-1
    ;;
  *' get node node-0 -o jsonpath={.metadata.labels.topology\.kubernetes\.io/zone}')
    printf '%s' zone-a
    ;;
  *' get node node-1 -o jsonpath={.metadata.labels.topology\.kubernetes\.io/zone}')
    printf '%s' zone-b
    ;;
  *' get pod broker-0 -o json')
    restart_count=0
    [[ "$(cat "$FAILURE_TEST_STATE")" == before ]] || restart_count=1
    printf '%s\n' "{
      \"metadata\":{\"uid\":\"broker-0-uid\"},
      \"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"name\":\"broker\",\"restartCount\":$restart_count}]},
      \"spec\":{\"volumes\":[{\"persistentVolumeClaim\":{\"claimName\":\"data-broker-0\"}}]}
    }"
    ;;
  *' get pod broker-1 -o json')
    restart_count=0
    [[ "$(cat "$FAILURE_TEST_STATE")" != after-second ]] || restart_count=1
    printf '%s\n' "{
      \"metadata\":{\"uid\":\"broker-1-uid\"},
      \"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"name\":\"broker\",\"restartCount\":$restart_count}]},
      \"spec\":{\"volumes\":[{\"persistentVolumeClaim\":{\"claimName\":\"data-broker-1\"}}]}
    }"
    ;;
  *' get pvc data-broker-0 -o jsonpath={.status.phase}'|*' get pvc data-broker-1 -o jsonpath={.status.phase}')
    printf '%s' Bound
    ;;
  *' get pvc data-broker-0 -o jsonpath={.spec.storageClassName}'|*' get pvc data-broker-1 -o jsonpath={.spec.storageClassName}')
    printf '%s' gp3-retain
    ;;
  *' get storageclass gp3-retain -o jsonpath={.provisioner}')
    printf '%s' ebs.csi.aws.com
    ;;
  *' get storageclass gp3-retain -o jsonpath={.volumeBindingMode}')
    printf '%s' WaitForFirstConsumer
    ;;
  *' get storageclass gp3-retain -o jsonpath={.reclaimPolicy}')
    printf '%s' Retain
    ;;
  *' get storageclass gp3-retain -o jsonpath={.allowVolumeExpansion}')
    printf '%s' true
    ;;
  *' exec broker-0 -c broker -- kill -KILL 1')
    [[ "$(cat "$FAILURE_TEST_STATE")" == before ]] || exit 2
    printf '%s\n' after-first > "$FAILURE_TEST_STATE"
    exit 137
    ;;
  *' exec broker-1 -c broker -- kill -KILL 1')
    [[ "$(cat "$FAILURE_TEST_STATE")" == after-first ]] || exit 2
    printf '%s\n' after-second > "$FAILURE_TEST_STATE"
    exit 137
    ;;
  *' exec broker-0 -c broker -- /bin/bash -ec '*' -- Active true')
    state=$(cat "$FAILURE_TEST_STATE")
    [[ "$state" == before || "$state" == after-second ]]
    ;;
  *' exec broker-0 -c broker -- /bin/bash -ec '*' -- Active false')
    [[ "$(cat "$FAILURE_TEST_STATE")" == after-first ]]
    ;;
  *' exec broker-0 -c broker -- /bin/bash -ec '*' -- ReplicaSync true')
    [[ "$(cat "$FAILURE_TEST_STATE")" == after-first ]]
    ;;
  *' exec broker-1 -c broker -- /bin/bash -ec '*' -- Active true')
    [[ "$(cat "$FAILURE_TEST_STATE")" == after-first ]]
    ;;
  *' exec broker-1 -c broker -- /bin/bash -ec '*' -- Active false')
    state=$(cat "$FAILURE_TEST_STATE")
    [[ "$state" == before || "$state" == after-second ]]
    ;;
  *)
    printf 'unexpected fake kubectl invocation: %s\n' "$joined" >&2
    exit 2
    ;;
esac
EOF
chmod 755 "$fake_bin/kubectl"

cat > "$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == image && "${2-}" == inspect ]]; then
  exit 0
fi
report_dir=''
previous=''
for argument in "$@"; do
  if [[ "$previous" == --volume ]]; then
    report_dir=${argument%:/reports}
  fi
  previous=$argument
done
[[ -n "$report_dir" ]] || { printf '%s\n' 'fake docker did not receive /reports volume' >&2; exit 2; }
if [[ "$*" == *'validation.Main send'* ]]; then
  printf '%s\n' $'0\tfailure-id-0' > "$report_dir/acknowledged.tsv"
  while [[ "$(cat "$FAILURE_TEST_STATE")" == before ]]; do
    sleep 0.1
  done
  printf '%s\n' $'1\tfailure-id-1' $'2\tfailure-id-2' >> "$report_dir/acknowledged.tsv"
  acknowledged_count=3
  if [[ "${FAILURE_TEST_DOUBLE:-0}" == 1 ]]; then
    while [[ "$(cat "$FAILURE_TEST_STATE")" == after-first ]]; do
      sleep 0.1
    done
    printf '%s\n' $'3\tfailure-id-3' $'4\tfailure-id-4' >> "$report_dir/acknowledged.tsv"
    acknowledged_count=5
  fi
  printf '{
    "acknowledgedCount": %d,
    "unacknowledgedSequences": [%d]
  }\n' "$acknowledged_count" "$acknowledged_count" > "$report_dir/send.json"
elif [[ "$*" == *'validation.Main consume'* ]]; then
  acknowledged_count=3
  [[ "${FAILURE_TEST_DOUBLE:-0}" != 1 ]] || acknowledged_count=5
  printf '{
    "acknowledgedCount": %d,
    "receivedCount": %d,
    "uniqueCount": %d,
    "acknowledgementFailures": 0,
    "missingSequences": [%d],
    "duplicateSequences": [],
    "redeliveredSequences": [],
    "unexpectedSequences": []
  }\n' \
    "$acknowledged_count" \
    "$acknowledged_count" \
    "$acknowledged_count" \
    "$acknowledged_count" > "$report_dir/consume.json"
else
  printf 'unexpected fake docker invocation: %s\n' "$*" >&2
  exit 2
fi
EOF
chmod 755 "$fake_bin/docker"

execution_reports="$temp_dir/execution-reports"
single_execution_reports="$temp_dir/single-execution-reports"
expect_exit 0 env \
  PATH="$fake_bin:$PATH" \
  FAILURE_TEST_STATE="$state_file" \
  PERF_URL='failover:(amqp://broker:5672)' \
  PERF_USERNAME=test-user \
  PERF_PASSWORD=test-password \
  IMAGE=test-image \
  "$runner" \
    --context test-context \
    --cluster test-cluster \
    --namespace test-namespace \
    --profile sustained \
    --fault process-kill \
    --fault-after-acknowledged 1 \
    --recovery-timeout-seconds 10 \
    --test-timeout-seconds 20 \
    --report-dir "$single_execution_reports" \
    --execute \
    --confirm-context test-context \
    --confirm-cluster test-cluster \
    --confirm-namespace test-namespace

single_failure_report=$(find "$single_execution_reports" -name failure-run.json -print -quit)
[[ -n "$single_failure_report" ]] ||
  fail 'single-failover execution did not write failure-run.json'
yq -e '
  .status == "PASS" and
  .testMode == "single-failover" and
  (.faults | length) == 1 and
  .activation.secondRecoveryDurationSeconds == null
' "$single_failure_report" >/dev/null ||
  fail 'single-failover report compatibility regressed'

printf '%s\n' before > "$state_file"
expect_exit 0 env \
  PATH="$fake_bin:$PATH" \
  FAILURE_TEST_STATE="$state_file" \
  FAILURE_TEST_DOUBLE=1 \
  PERF_URL='failover:(amqp://broker:5672)' \
  PERF_USERNAME=test-user \
  PERF_PASSWORD=test-password \
  IMAGE=test-image \
  "$runner" \
    --context test-context \
    --cluster test-cluster \
    --namespace test-namespace \
    --profile sustained \
    --fault process-kill \
    --double-failover \
    --fault-after-acknowledged 1 \
    --recovery-timeout-seconds 10 \
    --test-timeout-seconds 20 \
    --report-dir "$execution_reports" \
    --execute \
    --confirm-context test-context \
    --confirm-cluster test-cluster \
    --confirm-namespace test-namespace

failure_report=$(find "$execution_reports" -name failure-run.json -print -quit)
[[ -n "$failure_report" ]] || fail 'executed failure harness did not write failure-run.json'
yq -e '
  .status == "PASS" and
  .rpoStatus == "PASS" and
  .testMode == "double-failover" and
  .messageAccounting.ledgerAcknowledgedCount == 5 and
  .messageAccounting.processedUniqueCount == 5 and
  (.messageAccounting.lostAcknowledgedSequences | length) == 0 and
  .fault.acknowledgedAfterFaultCommand == 4 and
  (.faults | length) == 2 and
  .faults[0].targetPod == "broker-0" and
  .faults[0].replacementActivePod == "broker-1" and
  .faults[0].acknowledgedAfterInjection == 2 and
  .faults[1].targetPod == "broker-1" and
  .faults[1].replacementActivePod == "broker-0" and
  .faults[1].acknowledgedAfterInjection == 2 and
  .activation.maximumSimultaneouslyActive == 1
' "$failure_report" >/dev/null ||
  {
    yq '.' "$failure_report" >&2
    fail 'executed failure harness report did not reconcile the acknowledged ledger'
  }

printf '%s\n' 'failure script tests: PASS'
