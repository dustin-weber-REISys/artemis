#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
profile_catalog="$script_dir/profiles/sustained-load-profiles.yaml"
context=''
cluster=''
namespace=''
profile=sustained
fault=process-kill
double_failover=0
broker_selector='app.kubernetes.io/component=broker'
broker_container=''
fault_after_acknowledged=1000
recovery_timeout_seconds=180
test_timeout_seconds=1200
report_root="$script_dir/../reports/failure"
image=${IMAGE:-artemis-validation-client:local}
execute=0
confirm_context=''
confirm_cluster=''
confirm_namespace=''

usage() {
  printf '%s\n' \
    'Usage: run-failure-test.sh --context CONTEXT --cluster CLUSTER --namespace NAMESPACE [options]' \
    '' \
    'Plans by default. Destructive execution additionally requires:' \
    '  --execute --confirm-context CONTEXT --confirm-cluster CLUSTER --confirm-namespace NAMESPACE' \
    '' \
    'Runtime environment: PERF_URL, PERF_USERNAME, PERF_PASSWORD' \
    'Optional environment: PERF_PROTOCOL, PERF_DESTINATION, IMAGE' \
    '' \
    'Options:' \
    '  --profile NAME                    Load profile (default: sustained)' \
    '  --fault process-kill|pod-delete   Fault to inject (default: process-kill)' \
    '  --double-failover                 Fail A, wait for synchronized rejoin, then fail B' \
    '  --broker-selector SELECTOR        Select exactly two HA pods' \
    '  --broker-container NAME           Main broker container; auto-detected by port 61616' \
    '  --fault-after-acknowledged N      Inject after N durable send returns (default: 1000)' \
    '  --recovery-timeout-seconds N      Wait for peer activation (default: 180)' \
    '  --test-timeout-seconds N          Bound the producer/fault phase (default: 1200)' \
    '  --report-dir DIRECTORY            Parent report directory'
}

die() {
  printf 'failure-test: %s\n' "$*" >&2
  exit 2
}

require_value() {
  local option=$1
  local value=${2-}
  [[ -n "$value" ]] || die "$option requires a value"
}

require_positive_integer() {
  local option=$1
  local value=$2
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$option must be a positive integer"
}

line_count() {
  sed '/^$/d' | wc -l | tr -d ' '
}

while (($#)); do
  case "$1" in
    --context) require_value "$1" "${2-}"; context=$2; shift 2 ;;
    --cluster) require_value "$1" "${2-}"; cluster=$2; shift 2 ;;
    --namespace) require_value "$1" "${2-}"; namespace=$2; shift 2 ;;
    --profile) require_value "$1" "${2-}"; profile=$2; shift 2 ;;
    --fault) require_value "$1" "${2-}"; fault=$2; shift 2 ;;
    --double-failover) double_failover=1; shift ;;
    --broker-selector) require_value "$1" "${2-}"; broker_selector=$2; shift 2 ;;
    --broker-container) require_value "$1" "${2-}"; broker_container=$2; shift 2 ;;
    --fault-after-acknowledged)
      require_value "$1" "${2-}"
      fault_after_acknowledged=$2
      shift 2
      ;;
    --recovery-timeout-seconds)
      require_value "$1" "${2-}"
      recovery_timeout_seconds=$2
      shift 2
      ;;
    --test-timeout-seconds)
      require_value "$1" "${2-}"
      test_timeout_seconds=$2
      shift 2
      ;;
    --report-dir) require_value "$1" "${2-}"; report_root=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    --confirm-context) require_value "$1" "${2-}"; confirm_context=$2; shift 2 ;;
    --confirm-cluster) require_value "$1" "${2-}"; confirm_cluster=$2; shift 2 ;;
    --confirm-namespace) require_value "$1" "${2-}"; confirm_namespace=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$context" && -n "$cluster" && -n "$namespace" ]] || {
  usage >&2
  exit 2
}
case "$fault" in
  process-kill|pod-delete) ;;
  *) die '--fault must be process-kill or pod-delete' ;;
esac
require_positive_integer --fault-after-acknowledged "$fault_after_acknowledged"
require_positive_integer --recovery-timeout-seconds "$recovery_timeout_seconds"
require_positive_integer --test-timeout-seconds "$test_timeout_seconds"

command -v yq >/dev/null 2>&1 || die 'yq 4.53.3 or newer is required'
profile_count=$(PROFILE_NAME="$profile" yq -r \
  '[.profiles[] | select(.name == strenv(PROFILE_NAME))] | length' \
  "$profile_catalog")
[[ "$profile_count" == 1 ]] || die "unknown or duplicate performance profile: $profile"
message_count=$(PROFILE_NAME="$profile" yq -r \
  '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .messageCount) // .defaults.messageCount' \
  "$profile_catalog")
payload_bytes=$(PROFILE_NAME="$profile" yq -r \
  '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .payloadBytes) // .defaults.payloadBytes' \
  "$profile_catalog")
producer_concurrency=$(PROFILE_NAME="$profile" yq -r \
  '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .producerConcurrency) // .defaults.producerConcurrency' \
  "$profile_catalog")
consumer_concurrency=$(PROFILE_NAME="$profile" yq -r \
  '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .consumerConcurrency) // .defaults.consumerConcurrency' \
  "$profile_catalog")
[[ "$producer_concurrency" == 1 && "$consumer_concurrency" == 1 ]] ||
  die "profile $profile requires unsupported concurrency (producer=$producer_concurrency, consumer=$consumer_concurrency); this harness is serial"
recovery_target_seconds=$(yq -r '.acceptance.recoveryTargetSeconds' "$profile_catalog")
protocol=${PERF_PROTOCOL:-$(yq -r '.defaults.protocol' "$profile_catalog")}
destination=${PERF_DESTINATION:-"failure.$profile"}
((fault_after_acknowledged < message_count)) ||
  die "--fault-after-acknowledged must be less than profile message count $message_count"
case "$protocol" in
  amqp|openwire) ;;
  *) die "unsupported PERF_PROTOCOL: $protocol" ;;
esac

if [[ "$execute" != 1 ]]; then
  printf '%s\n' \
    "PLAN: send $message_count persistent $protocol messages to $destination" \
    "PLAN: use an exact $payload_bytes-byte UTF-8 body for every message" \
    "PLAN: inject $fault after $fault_after_acknowledged recorded acknowledgements"
  if [[ "$double_failover" == 1 ]]; then
    printf '%s\n' \
      'PLAN: wait for the original active pod to restart, return passive, and report ReplicaSync=true' \
      "PLAN: inject a second $fault into the new active and verify the original pod becomes active"
  fi
  printf '%s\n' \
    'PLAN: consume after failover and reconcile only definitely acknowledged IDs' \
    "PLAN: target context=$context cluster=$cluster namespace=$namespace selector=$broker_selector" \
    'No cluster or broker action was executed.'
  exit 0
fi

[[ "$confirm_context" == "$context" ]] ||
  die '--confirm-context must exactly match --context'
[[ "$confirm_cluster" == "$cluster" ]] ||
  die '--confirm-cluster must exactly match --cluster'
[[ "$confirm_namespace" == "$namespace" ]] ||
  die '--confirm-namespace must exactly match --namespace'

for required_command in docker kubectl yq; do
  command -v "$required_command" >/dev/null 2>&1 ||
    die "$required_command is required for execution"
done
broker_url=${PERF_URL:-}
username=${PERF_USERNAME:-}
password=${PERF_PASSWORD:-}
[[ -n "$broker_url" ]] || die 'PERF_URL is required for execution'
[[ -n "$username" ]] || die 'PERF_USERNAME is required for execution'
[[ -n "$password" ]] || die 'PERF_PASSWORD is required for execution'

actual_context=$(kubectl config current-context)
[[ "$actual_context" == "$context" ]] ||
  die "current context $actual_context does not match $context"
actual_cluster=$(kubectl config view --minify --context "$context" -o jsonpath='{.clusters[0].name}')
[[ "$actual_cluster" == "$cluster" ]] ||
  die "selected context maps to cluster $actual_cluster, not $cluster"
kubectl --context "$context" get namespace "$namespace" >/dev/null
docker image inspect "$image" >/dev/null 2>&1 ||
  die "validation image is not available locally: $image"

if [[ "$report_root" != /* ]]; then
  report_root="$script_dir/$report_root"
fi
mkdir -p "$report_root"
report_root=$(CDPATH= cd -- "$report_root" && pwd)
run_id="failure-${profile}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$report_root/$run_id"
mkdir -p "$run_dir"

kube=(kubectl --context "$context" --namespace "$namespace")
pods_json="$run_dir/preflight-pods.json"
"${kube[@]}" get pods -l "$broker_selector" -o json > "$pods_json"
pod_names=$(yq -r '.items[].metadata.name' "$pods_json")
pod_count=$(printf '%s\n' "$pod_names" | line_count)
[[ "$pod_count" == 2 ]] ||
  die "preflight requires exactly two broker pods; selector matched $pod_count"
running_count=$(yq -r '[.items[] | select(.status.phase == "Running")] | length' "$pods_json")
[[ "$running_count" == 2 ]] ||
  die "preflight requires two Running broker pods; found $running_count"

pods=()
while IFS= read -r pod; do
  [[ -n "$pod" ]] && pods+=("$pod")
done <<< "$pod_names"

if [[ -z "$broker_container" ]]; then
  broker_container=$(yq -r \
    '.items[0].spec.containers[] | select(.ports[]?.containerPort == 61616) | .name' \
    "$pods_json" | sed -n '1p')
fi
[[ -n "$broker_container" ]] ||
  die 'could not auto-detect the broker container; provide --broker-container'

zones=()
claims=()
storage_classes=()
for pod in "${pods[@]}"; do
  node=$("${kube[@]}" get pod "$pod" -o jsonpath='{.spec.nodeName}')
  [[ -n "$node" ]] || die "broker pod $pod is not scheduled"
  zone=$(kubectl --context "$context" get node "$node" \
    -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
  [[ -n "$zone" ]] || die "node $node has no topology.kubernetes.io/zone label"
  zones+=("$zone")

  pod_json="$run_dir/$pod.json"
  "${kube[@]}" get pod "$pod" -o json > "$pod_json"
  claim_names=$(yq -r \
    '.spec.volumes[] | select(.persistentVolumeClaim != null) | .persistentVolumeClaim.claimName' \
    "$pod_json")
  claim_count=$(printf '%s\n' "$claim_names" | line_count)
  [[ "$claim_count" == 1 ]] ||
    die "broker pod $pod must mount exactly one PVC; found $claim_count"
  claim=$(printf '%s\n' "$claim_names" | sed -n '1p')
  claims+=("$claim")

  pvc_phase=$("${kube[@]}" get pvc "$claim" -o jsonpath='{.status.phase}')
  [[ "$pvc_phase" == Bound ]] || die "PVC $claim is not Bound"
  storage_class=$("${kube[@]}" get pvc "$claim" -o jsonpath='{.spec.storageClassName}')
  [[ -n "$storage_class" ]] || die "PVC $claim has no storage class"
  storage_classes+=("$storage_class")
done

distinct_zones=$(printf '%s\n' "${zones[@]}" | sort -u | line_count)
[[ "$distinct_zones" == 2 ]] ||
  die "broker pods must occupy two zones; found ${zones[*]}"
distinct_claims=$(printf '%s\n' "${claims[@]}" | sort -u | line_count)
[[ "$distinct_claims" == 2 ]] ||
  die "broker pods must use separate PVCs; found ${claims[*]}"

for storage_class in $(printf '%s\n' "${storage_classes[@]}" | sort -u); do
  provisioner=$(kubectl --context "$context" get storageclass "$storage_class" \
    -o jsonpath='{.provisioner}')
  binding_mode=$(kubectl --context "$context" get storageclass "$storage_class" \
    -o jsonpath='{.volumeBindingMode}')
  reclaim_policy=$(kubectl --context "$context" get storageclass "$storage_class" \
    -o jsonpath='{.reclaimPolicy}')
  allow_volume_expansion=$(kubectl --context "$context" get storageclass "$storage_class" \
    -o jsonpath='{.allowVolumeExpansion}')
  [[ "$provisioner" == ebs.csi.aws.com ]] ||
    die "storage class $storage_class must use ebs.csi.aws.com, found $provisioner"
  [[ "$binding_mode" == WaitForFirstConsumer ]] ||
    die "storage class $storage_class must use WaitForFirstConsumer, found $binding_mode"
  [[ "$reclaim_policy" == Retain ]] ||
    die "storage class $storage_class must use Retain, found $reclaim_policy"
  [[ "$allow_volume_expansion" == true ]] ||
    die "storage class $storage_class must allow volume expansion, found ${allow_volume_expansion:-unset}"
done

broker_attribute_is() {
  local pod=$1
  local attribute=$2
  local expected=$3
  "${kube[@]}" exec "$pod" -c "$broker_container" -- /bin/bash -ec \
    'curl -fsS --max-time 3 -u "$AMQ_USER:$AMQ_PASSWORD" \
      "http://$HOSTNAME:8161/console/jolokia/read/org.apache.activemq.artemis:broker=%22${APPLICATION_NAME}%22/$1" \
      | grep -q "\"value\":$2"' \
    -- "$attribute" "$expected" >/dev/null 2>&1
}

active_pods() {
  local pod
  local current_pods
  current_pods=$("${kube[@]}" get pods -l "$broker_selector" -o name 2>/dev/null || true)
  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    pod=${pod#pod/}
    if broker_attribute_is "$pod" Active true; then
      printf '%s\n' "$pod"
    fi
  done <<< "$current_pods"
}

inject_fault() {
  local pod=$1
  local log_file=$2
  local command_exit=0
  case "$fault" in
    process-kill)
      set +e
      "${kube[@]}" exec "$pod" -c "$broker_container" -- kill -KILL 1 \
        > "$log_file" 2>&1
      command_exit=$?
      set -e
      ;;
    pod-delete)
      "${kube[@]}" delete pod "$pod" \
        --grace-period=0 --force --wait=false > "$log_file" 2>&1
      ;;
  esac
  printf '%s\n' "$command_exit"
}

preflight_active=$(active_pods)
preflight_active_count=$(printf '%s\n' "$preflight_active" | line_count)
[[ "$preflight_active_count" == 1 ]] ||
  die "preflight requires exactly one active broker; observed $preflight_active_count"
target_pod=$(printf '%s\n' "$preflight_active" | sed -n '1p')
target_runtime_json=$("${kube[@]}" get pod "$target_pod" -o json)
target_initial_uid=$(printf '%s\n' "$target_runtime_json" | yq -r '.metadata.uid')
target_initial_restart_count=$(CONTAINER_NAME="$broker_container" yq -r \
  '[.status.containerStatuses[]? |
    select(.name == strenv(CONTAINER_NAME)) | .restartCount][0] // 0' \
  <<< "$target_runtime_json")
[[ -n "$target_initial_uid" && "$target_initial_uid" != null ]] ||
  die "active broker pod $target_pod has no UID"

target_rejoined_and_synchronized() {
  local runtime_json
  local current_uid
  local current_restart_count
  local current_phase
  local restarted=false
  runtime_json=$("${kube[@]}" get pod "$target_pod" -o json 2>/dev/null) || return 1
  current_uid=$(printf '%s\n' "$runtime_json" | yq -r '.metadata.uid')
  current_phase=$(printf '%s\n' "$runtime_json" | yq -r '.status.phase // ""')
  current_restart_count=$(CONTAINER_NAME="$broker_container" yq -r \
    '[.status.containerStatuses[]? |
      select(.name == strenv(CONTAINER_NAME)) | .restartCount][0] // 0' \
    <<< "$runtime_json")
  if [[ "$current_uid" != "$target_initial_uid" ]] ||
     ((current_restart_count > target_initial_restart_count)); then
    restarted=true
  fi
  [[ "$restarted" == true && "$current_phase" == Running ]] || return 1
  broker_attribute_is "$target_pod" Active false || return 1
  broker_attribute_is "$target_pod" ReplicaSync true
}

ZONES=$(IFS=,; printf '%s' "${zones[*]}") \
CLAIMS=$(IFS=,; printf '%s' "${claims[*]}") \
STORAGE_CLASSES=$(IFS=,; printf '%s' "${storage_classes[*]}") \
TARGET_POD=$target_pod \
TARGET_UID=$target_initial_uid \
TARGET_RESTART_COUNT=$target_initial_restart_count \
BROKER_CONTAINER=$broker_container \
  yq -n -o=json -I=2 '{
    "brokerPods": 2,
    "activePod": strenv(TARGET_POD),
    "activePodUid": strenv(TARGET_UID),
    "activeContainerRestartCount": (strenv(TARGET_RESTART_COUNT) | tonumber),
    "brokerContainer": strenv(BROKER_CONTAINER),
    "zones": (strenv(ZONES) | split(",")),
    "persistentVolumeClaims": (strenv(CLAIMS) | split(",")),
    "storageClasses": (strenv(STORAGE_CLASSES) | split(","))
  }' > "$run_dir/preflight.json"

acknowledgement_ledger="$run_dir/acknowledged.tsv"
send_report="$run_dir/send.json"
consume_report="$run_dir/consume.json"
producer_pid=''
cleanup_background() {
  if [[ -n "$producer_pid" ]] && kill -0 "$producer_pid" >/dev/null 2>&1; then
    kill "$producer_pid" >/dev/null 2>&1 || true
    wait "$producer_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup_background EXIT

id_prefix="$run_id-"
docker_env=(
  --env "PERF_PROTOCOL=$protocol"
  --env "PERF_URL=$broker_url"
  --env "PERF_DESTINATION=$destination"
  --env "PERF_USERNAME=$username"
  --env "PERF_PASSWORD=$password"
  --env "PERF_RUN_ID=$run_id"
  --env "PERF_ID_PREFIX=$id_prefix"
  --env "PERF_MESSAGE_COUNT=$message_count"
  --env "PERF_PAYLOAD_BYTES=$payload_bytes"
)

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker run --rm \
  --add-host host.docker.internal:host-gateway \
  --volume "$run_dir:/reports" \
  "${docker_env[@]}" \
  --entrypoint /bin/sh \
  "$image" -ec '
    exec java -cp "/opt/validation-client/client.jar:/opt/validation-client/lib/*" \
      org.example.artemis.validation.Main send \
      --protocol "$PERF_PROTOCOL" \
      --url "$PERF_URL" \
      --destination "$PERF_DESTINATION" \
      --username "$PERF_USERNAME" \
      --password "$PERF_PASSWORD" \
      --run-id "$PERF_RUN_ID" \
      --id-prefix "$PERF_ID_PREFIX" \
      --duplicate-id-prefix "$PERF_RUN_ID-duplicate-" \
      --count "$PERF_MESSAGE_COUNT" \
      --payload-bytes "$PERF_PAYLOAD_BYTES" \
      --acknowledgement-ledger /reports/acknowledged.tsv \
      --output /reports/send.json
  ' > "$run_dir/producer.log" 2>&1 &
producer_pid=$!

phase_deadline=$((SECONDS + test_timeout_seconds))
acknowledged_before_fault=0
while ((SECONDS < phase_deadline)); do
  if [[ -f "$acknowledgement_ledger" ]]; then
    acknowledged_before_fault=$(wc -l < "$acknowledgement_ledger" | tr -d ' ')
  fi
  ((acknowledged_before_fault >= fault_after_acknowledged)) && break
  kill -0 "$producer_pid" >/dev/null 2>&1 ||
    die "producer exited before the fault threshold; see $run_dir/producer.log"
  sleep 1
done
((acknowledged_before_fault >= fault_after_acknowledged)) ||
  die "producer did not reach $fault_after_acknowledged acknowledgements before timeout"

fault_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fault_epoch=$(date -u +%s)
first_fault_log_name=fault.log
[[ "$double_failover" != 1 ]] || first_fault_log_name=fault-1.log
fault_command_exit=$(inject_fault "$target_pod" "$run_dir/$first_fault_log_name")
acknowledged_at_fault=$acknowledged_before_fault
if [[ -f "$acknowledgement_ledger" ]]; then
  acknowledged_at_fault=$(wc -l < "$acknowledgement_ledger" | tr -d ' ')
fi

max_active_count=0
split_brain_observed=false
replacement_active=''
recovered_at=''
recovery_deadline=$((SECONDS + recovery_timeout_seconds))
while ((SECONDS < phase_deadline && SECONDS < recovery_deadline)); do
  current_active=$(active_pods)
  current_active_count=$(printf '%s\n' "$current_active" | line_count)
  ((current_active_count > max_active_count)) && max_active_count=$current_active_count
  if ((current_active_count > 1)); then
    split_brain_observed=true
  fi
  if [[ "$current_active_count" == 1 && "$current_active" != "$target_pod" ]]; then
    replacement_active=$current_active
    if [[ -z "$recovered_at" ]]; then
      recovered_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      recovered_epoch=$(date -u +%s)
    fi
    break
  fi
  sleep 1
done
[[ -n "$replacement_active" ]] ||
  die "no replacement active broker was observed within $recovery_timeout_seconds seconds"
recovery_duration_seconds=$((recovered_epoch - fault_epoch))

original_rejoined_at=''
second_fault_at=''
second_fault_epoch=0
second_fault_command_exit=0
second_acknowledged_before_fault=0
second_acknowledged_at_fault=0
second_replacement_active=''
second_recovered_at=''
second_recovery_duration_seconds=0
if [[ "$double_failover" == 1 ]]; then
  rejoin_deadline=$((SECONDS + recovery_timeout_seconds))
  while ((SECONDS < phase_deadline && SECONDS < rejoin_deadline)); do
    current_active=$(active_pods)
    current_active_count=$(printf '%s\n' "$current_active" | line_count)
    current_acknowledged=$acknowledged_at_fault
    if [[ -f "$acknowledgement_ledger" ]]; then
      current_acknowledged=$(wc -l < "$acknowledgement_ledger" | tr -d ' ')
    fi
    ((current_active_count > max_active_count)) && max_active_count=$current_active_count
    if ((current_active_count > 1)); then
      split_brain_observed=true
    fi
    if [[ "$current_active_count" == 1 &&
          "$current_active" == "$replacement_active" ]] &&
       ((current_acknowledged > acknowledged_at_fault)) &&
       target_rejoined_and_synchronized; then
      original_rejoined_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      break
    fi
    kill -0 "$producer_pid" >/dev/null 2>&1 ||
      die "producer exited before the original broker rejoined; see $run_dir/producer.log"
    sleep 1
  done
  [[ -n "$original_rejoined_at" ]] ||
    die "original broker $target_pod did not restart passive and synchronized while the replacement accepted a send within $recovery_timeout_seconds seconds"

  kill -0 "$producer_pid" >/dev/null 2>&1 ||
    die "producer exited before the second fault; see $run_dir/producer.log"
  if [[ -f "$acknowledgement_ledger" ]]; then
    second_acknowledged_before_fault=$(wc -l < "$acknowledgement_ledger" | tr -d ' ')
  fi
  second_fault_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  second_fault_epoch=$(date -u +%s)
  second_fault_command_exit=$(inject_fault "$replacement_active" "$run_dir/fault-2.log")
  second_acknowledged_at_fault=$second_acknowledged_before_fault
  if [[ -f "$acknowledgement_ledger" ]]; then
    second_acknowledged_at_fault=$(wc -l < "$acknowledgement_ledger" | tr -d ' ')
  fi

  second_recovery_deadline=$((SECONDS + recovery_timeout_seconds))
  while ((SECONDS < phase_deadline && SECONDS < second_recovery_deadline)); do
    current_active=$(active_pods)
    current_active_count=$(printf '%s\n' "$current_active" | line_count)
    ((current_active_count > max_active_count)) && max_active_count=$current_active_count
    if ((current_active_count > 1)); then
      split_brain_observed=true
    fi
    if [[ "$current_active_count" == 1 && "$current_active" == "$target_pod" ]]; then
      second_replacement_active=$current_active
      second_recovered_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      second_recovered_epoch=$(date -u +%s)
      break
    fi
    sleep 1
  done
  [[ "$second_replacement_active" == "$target_pod" ]] ||
    die "original broker $target_pod did not become active after the second fault within $recovery_timeout_seconds seconds"
  second_recovery_duration_seconds=$((second_recovered_epoch - second_fault_epoch))
fi

while kill -0 "$producer_pid" >/dev/null 2>&1 && ((SECONDS < phase_deadline)); do
  current_active=$(active_pods)
  current_active_count=$(printf '%s\n' "$current_active" | line_count)
  ((current_active_count > max_active_count)) && max_active_count=$current_active_count
  if ((current_active_count > 1)); then
    split_brain_observed=true
  fi
  sleep 1
done

producer_exit=0
if kill -0 "$producer_pid" >/dev/null 2>&1; then
  cleanup_background
  die "producer did not complete within $test_timeout_seconds seconds"
fi
set +e
wait "$producer_pid"
producer_exit=$?
set -e
producer_pid=''
[[ "$producer_exit" == 0 || "$producer_exit" == 1 ]] ||
  die "producer infrastructure failed with exit $producer_exit; see $run_dir/producer.log"
[[ -f "$send_report" ]] ||
  die "producer did not write $send_report"

max_messages=$((message_count * 2))
consumer_exit=0
set +e
docker run --rm \
  --add-host host.docker.internal:host-gateway \
  --volume "$run_dir:/reports" \
  "${docker_env[@]}" \
  --env "PERF_MAX_MESSAGES=$max_messages" \
  --entrypoint /bin/sh \
  "$image" -ec '
    exec java -cp "/opt/validation-client/client.jar:/opt/validation-client/lib/*" \
      org.example.artemis.validation.Main consume \
      --protocol "$PERF_PROTOCOL" \
      --url "$PERF_URL" \
      --destination "$PERF_DESTINATION" \
      --username "$PERF_USERNAME" \
      --password "$PERF_PASSWORD" \
      --run-id "$PERF_RUN_ID" \
      --id-prefix "$PERF_ID_PREFIX" \
      --expected-count "$PERF_MESSAGE_COUNT" \
      --max-messages "$PERF_MAX_MESSAGES" \
      --receive-timeout-seconds 10 \
      --output /reports/consume.json
  ' > "$run_dir/consumer.log" 2>&1
consumer_exit=$?
set -e
[[ "$consumer_exit" == 0 || "$consumer_exit" == 1 ]] ||
  die "consumer infrastructure failed with exit $consumer_exit; see $run_dir/consumer.log"
[[ -f "$consume_report" ]] ||
  die "consumer did not write $consume_report"

ledger_count=$(wc -l < "$acknowledgement_ledger" | tr -d ' ')
ledger_format_valid=true
awk -F '\t' 'NF != 2 || $1 !~ /^[0-9]+$/ || $2 == "" { invalid = 1 } END { exit invalid }' \
  "$acknowledgement_ledger" || ledger_format_valid=false
ledger_sequence_csv=$(cut -f1 "$acknowledgement_ledger" | paste -sd, -)
ledger_sequences_json=$(LEDGER_SEQUENCES=$ledger_sequence_csv yq -n -o=json -I=0 \
  'strenv(LEDGER_SEQUENCES) | split(",") | map(tonumber)')
unique_ledger_count=$(cut -f1 "$acknowledgement_ledger" | sort -u | line_count)
reported_acknowledged=$(yq -r '.acknowledgedCount' "$send_report")
post_fault_acknowledged=$((ledger_count - acknowledged_at_fault))
first_post_fault_acknowledged=$post_fault_acknowledged
second_post_fault_acknowledged=0
if [[ "$double_failover" == 1 ]]; then
  first_post_fault_acknowledged=$((second_acknowledged_before_fault - acknowledged_at_fault))
  second_post_fault_acknowledged=$((ledger_count - second_acknowledged_at_fault))
fi
ambiguous_send_count=$(yq -r '.unacknowledgedSequences | length' "$send_report")
received_delivery_count=$(yq -r '.receivedCount' "$consume_report")
processed_unique_count=$(yq -r '.uniqueCount' "$consume_report")
consumer_acknowledged_count=$(yq -r '.acknowledgedCount' "$consume_report")
duplicate_delivery_count=$(yq -r '.duplicateSequences | length' "$consume_report")
redelivered_count=$(yq -r '.redeliveredSequences | length' "$consume_report")
missing_requested_count=$(yq -r '.missingSequences | length' "$consume_report")
ledger_consistent=true
[[ "$ledger_count" == "$reported_acknowledged" &&
   "$ledger_count" == "$unique_ledger_count" &&
   "$ledger_format_valid" == true ]] || ledger_consistent=false
lost_acknowledged_json=$(LEDGER_SEQUENCES="$ledger_sequences_json" yq -o=json -I=0 \
  '.missingSequences as $missing
   | (strenv(LEDGER_SEQUENCES) | from_json) as $acknowledged
   | [$missing[] | select(. as $sequence | ($acknowledged | contains([$sequence])))]' \
  "$consume_report")
lost_acknowledged_count=$(printf '%s\n' "$lost_acknowledged_json" | yq -r 'length')
ambiguous_delivered_json=$(SEND_REPORT="$send_report" yq -o=json -I=0 \
  '.missingSequences as $missing
   | load(strenv(SEND_REPORT)).unacknowledgedSequences as $unknown
   | [$unknown[] | select(. as $sequence | ($missing | contains([$sequence]) | not))]' \
  "$consume_report")
unexpected_count=$(yq -r '.unexpectedSequences | length' "$consume_report")
consumer_ack_failures=$(yq -r '.acknowledgementFailures' "$consume_report")

status=PASS
rpo_status=PASS
if ((lost_acknowledged_count > 0)); then
  status=FAIL
  rpo_status=FAIL
fi
if [[ "$ledger_consistent" != true ]]; then
  rpo_status=NOT_EVALUATED
fi
if [[ "$ledger_consistent" != true || "$split_brain_observed" == true ]] ||
   ((unexpected_count > 0 || consumer_ack_failures > 0 ||
     recovery_duration_seconds > recovery_target_seconds ||
     first_post_fault_acknowledged < 1)); then
  status=FAIL
fi
if [[ "$double_failover" == 1 ]] &&
   ((second_recovery_duration_seconds > recovery_target_seconds ||
     second_post_fault_acknowledged < 1)); then
  status=FAIL
fi
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

REPORT_STATUS=$status \
REPORT_RPO_STATUS=$rpo_status \
REPORT_CONTEXT=$context \
REPORT_CLUSTER=$cluster \
REPORT_NAMESPACE=$namespace \
REPORT_PROFILE=$profile \
REPORT_PROTOCOL=$protocol \
REPORT_DESTINATION=$destination \
REPORT_RUN_ID=$run_id \
REPORT_PAYLOAD_BYTES=$payload_bytes \
REPORT_FAULT=$fault \
REPORT_DOUBLE_FAILOVER=$double_failover \
REPORT_TARGET_POD=$target_pod \
REPORT_REPLACEMENT_ACTIVE=$replacement_active \
REPORT_FAULT_COMMAND_EXIT=$fault_command_exit \
REPORT_ACK_BEFORE_FAULT=$acknowledged_before_fault \
REPORT_ACK_AT_FAULT=$acknowledged_at_fault \
REPORT_POST_FAULT_ACK=$post_fault_acknowledged \
REPORT_FIRST_POST_FAULT_ACK=$first_post_fault_acknowledged \
REPORT_ORIGINAL_REJOINED_AT=$original_rejoined_at \
REPORT_SECOND_TARGET_POD=$replacement_active \
REPORT_SECOND_REPLACEMENT_ACTIVE=$second_replacement_active \
REPORT_SECOND_FAULT_COMMAND_EXIT=$second_fault_command_exit \
REPORT_SECOND_ACK_BEFORE_FAULT=$second_acknowledged_before_fault \
REPORT_SECOND_ACK_AT_FAULT=$second_acknowledged_at_fault \
REPORT_SECOND_POST_FAULT_ACK=$second_post_fault_acknowledged \
REPORT_LEDGER_COUNT=$ledger_count \
REPORT_REPORTED_ACKNOWLEDGED=$reported_acknowledged \
REPORT_AMBIGUOUS_SEND_COUNT=$ambiguous_send_count \
REPORT_RECEIVED_DELIVERY_COUNT=$received_delivery_count \
REPORT_PROCESSED_UNIQUE_COUNT=$processed_unique_count \
REPORT_CONSUMER_ACKNOWLEDGED_COUNT=$consumer_acknowledged_count \
REPORT_DUPLICATE_DELIVERY_COUNT=$duplicate_delivery_count \
REPORT_REDELIVERED_COUNT=$redelivered_count \
REPORT_MISSING_REQUESTED_COUNT=$missing_requested_count \
REPORT_LEDGER_CONSISTENT=$ledger_consistent \
REPORT_LOST_ACKNOWLEDGED=$lost_acknowledged_json \
REPORT_AMBIGUOUS_DELIVERED=$ambiguous_delivered_json \
REPORT_UNEXPECTED_COUNT=$unexpected_count \
REPORT_CONSUMER_ACK_FAILURES=$consumer_ack_failures \
REPORT_SPLIT_BRAIN=$split_brain_observed \
REPORT_MAX_ACTIVE=$max_active_count \
REPORT_RECOVERY_DURATION=$recovery_duration_seconds \
REPORT_SECOND_RECOVERY_DURATION=$second_recovery_duration_seconds \
REPORT_RECOVERY_TARGET=$recovery_target_seconds \
REPORT_STARTED_AT=$started_at \
REPORT_FAULT_AT=$fault_at \
REPORT_RECOVERED_AT=$recovered_at \
REPORT_SECOND_FAULT_AT=$second_fault_at \
REPORT_SECOND_RECOVERED_AT=$second_recovered_at \
REPORT_COMPLETED_AT=$completed_at \
  yq -n -o=json -I=2 '{
    "schemaVersion": "validation.artemis.apache.org/failure-run/v1",
    "status": strenv(REPORT_STATUS),
    "rpoStatus": strenv(REPORT_RPO_STATUS),
    "context": strenv(REPORT_CONTEXT),
    "cluster": strenv(REPORT_CLUSTER),
    "namespace": strenv(REPORT_NAMESPACE),
    "profile": strenv(REPORT_PROFILE),
    "protocol": strenv(REPORT_PROTOCOL),
    "destination": strenv(REPORT_DESTINATION),
    "runId": strenv(REPORT_RUN_ID),
    "payloadBytes": (strenv(REPORT_PAYLOAD_BYTES) | tonumber),
    "producerConcurrency": 1,
    "consumerConcurrency": 1,
    "testMode": (
      {"0": "single-failover", "1": "double-failover"}[
        strenv(REPORT_DOUBLE_FAILOVER)
      ]
    ),
    "fault": {
      "type": strenv(REPORT_FAULT),
      "targetPod": strenv(REPORT_TARGET_POD),
      "replacementActivePod": strenv(REPORT_REPLACEMENT_ACTIVE),
      "commandExit": (strenv(REPORT_FAULT_COMMAND_EXIT) | tonumber),
      "acknowledgedBeforeInjection": (strenv(REPORT_ACK_BEFORE_FAULT) | tonumber),
      "acknowledgedWhenFaultCommandReturned": (strenv(REPORT_ACK_AT_FAULT) | tonumber),
      "acknowledgedAfterFaultCommand": (strenv(REPORT_POST_FAULT_ACK) | tonumber)
    },
    "faults": [
      {
        "sequence": 1,
        "type": strenv(REPORT_FAULT),
        "targetPod": strenv(REPORT_TARGET_POD),
        "replacementActivePod": strenv(REPORT_REPLACEMENT_ACTIVE),
        "commandExit": (strenv(REPORT_FAULT_COMMAND_EXIT) | tonumber),
        "acknowledgedBeforeInjection": (strenv(REPORT_ACK_BEFORE_FAULT) | tonumber),
        "acknowledgedWhenFaultCommandReturned": (strenv(REPORT_ACK_AT_FAULT) | tonumber),
        "acknowledgedBeforeNextInjection": (
          [
            null,
            (strenv(REPORT_SECOND_ACK_BEFORE_FAULT) | tonumber)
          ][strenv(REPORT_DOUBLE_FAILOVER) | tonumber]
        ),
        "acknowledgedAfterInjection": (strenv(REPORT_FIRST_POST_FAULT_ACK) | tonumber),
        "recoveryDurationSeconds": (strenv(REPORT_RECOVERY_DURATION) | tonumber)
      },
      ({
        "sequence": 2,
        "type": strenv(REPORT_FAULT),
        "targetPod": strenv(REPORT_SECOND_TARGET_POD),
        "replacementActivePod": strenv(REPORT_SECOND_REPLACEMENT_ACTIVE),
        "commandExit": (strenv(REPORT_SECOND_FAULT_COMMAND_EXIT) | tonumber),
        "acknowledgedBeforeInjection": (strenv(REPORT_SECOND_ACK_BEFORE_FAULT) | tonumber),
        "acknowledgedWhenFaultCommandReturned": (strenv(REPORT_SECOND_ACK_AT_FAULT) | tonumber),
        "acknowledgedBeforeNextInjection": null,
        "acknowledgedAfterInjection": (strenv(REPORT_SECOND_POST_FAULT_ACK) | tonumber),
        "recoveryDurationSeconds": (strenv(REPORT_SECOND_RECOVERY_DURATION) | tonumber)
      } | select(strenv(REPORT_DOUBLE_FAILOVER) == "1"))
    ],
    "messageAccounting": {
      "ledgerAcknowledgedCount": (strenv(REPORT_LEDGER_COUNT) | tonumber),
      "sendReportAcknowledgedCount": (strenv(REPORT_REPORTED_ACKNOWLEDGED) | tonumber),
      "ambiguousSendCount": (strenv(REPORT_AMBIGUOUS_SEND_COUNT) | tonumber),
      "receivedDeliveryCount": (strenv(REPORT_RECEIVED_DELIVERY_COUNT) | tonumber),
      "processedUniqueCount": (strenv(REPORT_PROCESSED_UNIQUE_COUNT) | tonumber),
      "consumerAcknowledgedCount": (strenv(REPORT_CONSUMER_ACKNOWLEDGED_COUNT) | tonumber),
      "duplicateDeliveryCount": (strenv(REPORT_DUPLICATE_DELIVERY_COUNT) | tonumber),
      "redeliveredCount": (strenv(REPORT_REDELIVERED_COUNT) | tonumber),
      "missingRequestedCount": (strenv(REPORT_MISSING_REQUESTED_COUNT) | tonumber),
      "ledgerConsistent": (strenv(REPORT_LEDGER_CONSISTENT) == "true"),
      "lostAcknowledgedSequences": (strenv(REPORT_LOST_ACKNOWLEDGED) | from_json),
      "ambiguousButDeliveredSequences": (strenv(REPORT_AMBIGUOUS_DELIVERED) | from_json),
      "unexpectedSequenceCount": (strenv(REPORT_UNEXPECTED_COUNT) | tonumber),
      "consumerAcknowledgementFailures": (strenv(REPORT_CONSUMER_ACK_FAILURES) | tonumber)
    },
    "activation": {
      "splitBrainObserved": (strenv(REPORT_SPLIT_BRAIN) == "true"),
      "maximumSimultaneouslyActive": (strenv(REPORT_MAX_ACTIVE) | tonumber),
      "recoveryDurationSeconds": (strenv(REPORT_RECOVERY_DURATION) | tonumber),
      "secondRecoveryDurationSeconds": (
        [
          null,
          (strenv(REPORT_SECOND_RECOVERY_DURATION) | tonumber)
        ][strenv(REPORT_DOUBLE_FAILOVER) | tonumber]
      ),
      "recoveryTargetSeconds": (strenv(REPORT_RECOVERY_TARGET) | tonumber)
    },
    "timing": {
      "startedAt": strenv(REPORT_STARTED_AT),
      "faultInjectedAt": strenv(REPORT_FAULT_AT),
      "replacementActiveAt": strenv(REPORT_RECOVERED_AT),
      "originalBrokerRejoinedAt": (
        [null, strenv(REPORT_ORIGINAL_REJOINED_AT)][
          strenv(REPORT_DOUBLE_FAILOVER) | tonumber
        ]
      ),
      "secondFaultInjectedAt": (
        [null, strenv(REPORT_SECOND_FAULT_AT)][
          strenv(REPORT_DOUBLE_FAILOVER) | tonumber
        ]
      ),
      "originalBrokerReactivatedAt": (
        [null, strenv(REPORT_SECOND_RECOVERED_AT)][
          strenv(REPORT_DOUBLE_FAILOVER) | tonumber
        ]
      ),
      "completedAt": strenv(REPORT_COMPLETED_AT)
    },
    "evidence": {
      "preflight": "preflight.json",
      "acknowledgementLedger": "acknowledged.tsv",
      "sendReport": "send.json",
      "consumeReport": "consume.json",
      "producerLog": "producer.log",
      "consumerLog": "consumer.log",
      "faultLog": (
        ["fault.log", "fault-1.log"][
          strenv(REPORT_DOUBLE_FAILOVER) | tonumber
        ]
      ),
      "faultLogs": (
        [
          ["fault.log"],
          ["fault-1.log", "fault-2.log"]
        ][strenv(REPORT_DOUBLE_FAILOVER) | tonumber]
      )
    },
    "notes": (
      [
        "PASS proves no definitely acknowledged ID was missing in this run. Ambiguous sends may be delivered. This does not prove remote fsync or safety during a second degraded-state failure.",
        "PASS proves both leader transitions occurred after the failed peer restarted passive with ReplicaSync=true, and no definitely acknowledged ID was missing. Ambiguous sends may be delivered. This does not prove remote fsync."
      ][strenv(REPORT_DOUBLE_FAILOVER) | tonumber]
    )
  }' > "$run_dir/failure-run.json"

trap - EXIT
printf 'failure validation %s; report: %s\n' "$status" "$run_dir/failure-run.json"
[[ "$status" == PASS ]]
