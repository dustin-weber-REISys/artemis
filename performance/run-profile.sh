#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
profile_catalog="$script_dir/profiles/sustained-load-profiles.yaml"
target=''
profile=burst
report_dir="$script_dir/../reports/performance"
image=${IMAGE:-artemis-validation-client:local}

usage() {
  printf '%s\n' \
    'Usage: run-profile.sh --target local|deployed [--profile NAME] [--report-dir DIRECTORY]' \
    '' \
    'Local defaults:' \
    '  AMQP:     amqp://host.docker.internal:5672' \
    '  OpenWire: tcp://host.docker.internal:61616' \
    '' \
    'Deployed targets require PERF_URL, PERF_USERNAME, and PERF_PASSWORD.' \
    'PERF_PROTOCOL and PERF_DESTINATION may override profile defaults.'
}

require_value() {
  local option=$1
  local value=${2-}
  [[ -n "$value" ]] || {
    printf '%s requires a value\n' "$option" >&2
    exit 2
  }
}

while (($#)); do
  case "$1" in
    --target) require_value "$1" "${2-}"; target=$2; shift 2 ;;
    --profile) require_value "$1" "${2-}"; profile=$2; shift 2 ;;
    --report-dir) require_value "$1" "${2-}"; report_dir=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$target" in
  local|deployed) ;;
  *) printf '%s\n' '--target must be local or deployed' >&2; usage >&2; exit 2 ;;
esac

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'docker is required' >&2
  exit 2
}
command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

profile_count=$(PROFILE_NAME="$profile" yq -r \
  '[.profiles[] | select(.name == strenv(PROFILE_NAME))] | length' \
  "$profile_catalog")
[[ "$profile_count" == 1 ]] || {
  printf 'unknown or duplicate performance profile: %s\n' "$profile" >&2
  exit 2
}

message_count=$(PROFILE_NAME="$profile" yq -r \
  '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .messageCount) // .defaults.messageCount' \
  "$profile_catalog")
profile_duration=$(PROFILE_NAME="$profile" yq -r \
  '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .durationSeconds) // .defaults.durationSeconds' \
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
[[ "$producer_concurrency" == 1 && "$consumer_concurrency" == 1 ]] || {
  printf 'profile %s requires unsupported concurrency (producer=%s, consumer=%s); this runner is serial\n' \
    "$profile" "$producer_concurrency" "$consumer_concurrency" >&2
  exit 2
}
protocol=${PERF_PROTOCOL:-$(yq -r '.defaults.protocol' "$profile_catalog")}
destination=${PERF_DESTINATION:-"performance.$profile"}

case "$protocol" in
  amqp)
    local_url="amqp://host.docker.internal:${ARTEMIS_AMQP_PORT:-5672}"
    ;;
  openwire)
    local_url="tcp://host.docker.internal:${ARTEMIS_OPENWIRE_PORT:-61616}"
    ;;
  *)
    printf 'unsupported PERF_PROTOCOL: %s\n' "$protocol" >&2
    exit 2
    ;;
esac

if [[ "$target" == local ]]; then
  broker_url=${PERF_URL:-$local_url}
  username=${PERF_USERNAME:-localdev}
  password=${PERF_PASSWORD:-localdev}
else
  broker_url=${PERF_URL:-}
  username=${PERF_USERNAME:-}
  password=${PERF_PASSWORD:-}
  [[ -n "$broker_url" ]] || { printf '%s\n' 'PERF_URL is required for a deployed target' >&2; exit 2; }
  [[ -n "$username" ]] || { printf '%s\n' 'PERF_USERNAME is required for a deployed target' >&2; exit 2; }
  [[ -n "$password" ]] || { printf '%s\n' 'PERF_PASSWORD is required for a deployed target' >&2; exit 2; }
fi

if [[ "$report_dir" != /* ]]; then
  report_dir="$script_dir/$report_dir"
fi
mkdir -p "$report_dir"
report_dir=$(CDPATH= cd -- "$report_dir" && pwd)

run_id="${target}-${profile}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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
  --env "PERF_ACKNOWLEDGEMENT_LEDGER=/reports/acknowledged.tsv"
)

printf 'performance profile: %s (%s messages x %s payload bytes; %ss duration guidance)\n' \
  "$profile" "$message_count" "$payload_bytes" "$profile_duration"
printf 'target: %s; protocol: %s; destination: %s\n' \
  "$target" "$protocol" "$destination"

docker run --rm \
  --add-host host.docker.internal:host-gateway \
  --volume "$report_dir:/reports" \
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
      --acknowledgement-ledger "$PERF_ACKNOWLEDGEMENT_LEDGER" \
      --output /reports/send.json
  '

docker run --rm \
  --add-host host.docker.internal:host-gateway \
  --volume "$report_dir:/reports" \
  "${docker_env[@]}" \
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
      --output /reports/consume.json
  '

REPORT_TARGET=$target \
REPORT_PROFILE=$profile \
REPORT_PROTOCOL=$protocol \
REPORT_DESTINATION=$destination \
REPORT_RUN_ID=$run_id \
REPORT_MESSAGE_COUNT=$message_count \
REPORT_PAYLOAD_BYTES=$payload_bytes \
REPORT_PROFILE_DURATION=$profile_duration \
  yq -n -o=json -I=2 '{
    "schemaVersion": "validation.artemis.apache.org/performance-run/v1",
    "target": strenv(REPORT_TARGET),
    "profile": strenv(REPORT_PROFILE),
    "protocol": strenv(REPORT_PROTOCOL),
    "destination": strenv(REPORT_DESTINATION),
    "runId": strenv(REPORT_RUN_ID),
    "messageCount": (strenv(REPORT_MESSAGE_COUNT) | tonumber),
    "payloadBytes": (strenv(REPORT_PAYLOAD_BYTES) | tonumber),
    "producerConcurrency": 1,
    "consumerConcurrency": 1,
    "profileDurationSeconds": (strenv(REPORT_PROFILE_DURATION) | tonumber),
    "acknowledgementLedger": "acknowledged.tsv",
    "sendReport": "send.json",
    "consumeReport": "consume.json"
  }' > "$report_dir/run.json"

printf 'performance validation passed; reports: %s\n' "$report_dir"
