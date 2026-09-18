#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
profile_catalog="$script_dir/profiles/sustained-load-profiles.yaml"
target=''
profile=burst
report_dir="$script_dir/../reports/performance"
image=${IMAGE:-artemis-validation-client:local}
context=''
cluster=''
namespace=''
broker_selector='app.kubernetes.io/component=broker'
tunnel_port_a=${PERF_TUNNEL_PORT_A:-25672}
tunnel_port_b=${PERF_TUNNEL_PORT_B:-25673}
tunnel_max_restarts=${PERF_TUNNEL_MAX_RESTARTS:-5}
tunnel_startup_timeout_seconds=${PERF_TUNNEL_STARTUP_TIMEOUT_SECONDS:-15}
tunnel_pod_wait_timeout_seconds=${PERF_TUNNEL_POD_WAIT_TIMEOUT_SECONDS:-180}
tunnel_retry_delay_seconds=${PERF_TUNNEL_RETRY_DELAY_SECONDS:-1}
tunnel_poll_seconds=${PERF_TUNNEL_POLL_SECONDS:-1}
tunnel_tls=0
tunnel_tls_hostname=${PERF_TLS_HOSTNAME:-}
tunnel_pid=''
tunnel_mode='none'
tunnel_env_file=''
tunnel_status_file=''

usage() {
  printf '%s\n' \
    'Usage: run-profile.sh --target local|deployed|tunneled [options]' \
    '' \
    'Local defaults:' \
    '  AMQP:     amqp://host.docker.internal:5672' \
    '  OpenWire: tcp://host.docker.internal:61616' \
    '' \
    'Deployed targets require PERF_URL, PERF_USERNAME, and PERF_PASSWORD.' \
    'Tunneled targets require --context, --cluster, and --namespace.' \
    'Tunneled mode creates two loopback pod forwards and a provider-specific' \
    'failover URL shared by the producer and consumer.' \
    '' \
    'Options:' \
    '  --profile NAME                    Load profile (default: burst)' \
    '  --report-dir DIRECTORY            Report directory' \
    '  --context CONTEXT                 Kubernetes context for tunneled mode' \
    '  --cluster CLUSTER                 Expected cluster for tunneled mode' \
    '  --namespace NAMESPACE             Broker namespace for tunneled mode' \
    '  --broker-selector SELECTOR        Exactly two broker pods' \
    '  --tunnel-port-a PORT              Loopback port for broker pod A' \
    '  --tunnel-port-b PORT              Loopback port for broker pod B' \
    '  --tunnel-tls                      Use amqps/ssl with certificate verification' \
    '  --tls-hostname HOST               TLS SNI/certificate hostname' \
    '  -h, --help                        Show this help'
}

die() {
  printf 'performance: %s\n' "$*" >&2
  exit 2
}

require_value() {
  local option=$1
  local value=${2-}
  [[ -n "$value" ]] || die "$option requires a value"
}

while (($#)); do
  case "$1" in
    --target) require_value "$1" "${2-}"; target=$2; shift 2 ;;
    --profile) require_value "$1" "${2-}"; profile=$2; shift 2 ;;
    --report-dir) require_value "$1" "${2-}"; report_dir=$2; shift 2 ;;
    --context) require_value "$1" "${2-}"; context=$2; shift 2 ;;
    --cluster) require_value "$1" "${2-}"; cluster=$2; shift 2 ;;
    --namespace) require_value "$1" "${2-}"; namespace=$2; shift 2 ;;
    --broker-selector) require_value "$1" "${2-}"; broker_selector=$2; shift 2 ;;
    --tunnel-port-a) require_value "$1" "${2-}"; tunnel_port_a=$2; shift 2 ;;
    --tunnel-port-b) require_value "$1" "${2-}"; tunnel_port_b=$2; shift 2 ;;
    --tunnel-max-restarts)
      require_value "$1" "${2-}"; tunnel_max_restarts=$2; shift 2 ;;
    --tunnel-startup-timeout-seconds)
      require_value "$1" "${2-}"; tunnel_startup_timeout_seconds=$2; shift 2 ;;
    --tunnel-pod-wait-timeout-seconds)
      require_value "$1" "${2-}"; tunnel_pod_wait_timeout_seconds=$2; shift 2 ;;
    --tunnel-retry-delay-seconds)
      require_value "$1" "${2-}"; tunnel_retry_delay_seconds=$2; shift 2 ;;
    --tunnel-poll-seconds)
      require_value "$1" "${2-}"; tunnel_poll_seconds=$2; shift 2 ;;
    --tunnel-tls) tunnel_tls=1; shift ;;
    --tls-hostname) require_value "$1" "${2-}"; tunnel_tls_hostname=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$target" in
  local|deployed|tunneled) ;;
  *) die '--target must be local, deployed, or tunneled' ;;
esac

command -v docker >/dev/null 2>&1 || die 'docker is required'
command -v yq >/dev/null 2>&1 || die 'yq 4.53.3 or newer is required'

profile_count=$(PROFILE_NAME="$profile" yq -r \
  '[.profiles[] | select(.name == strenv(PROFILE_NAME))] | length' \
  "$profile_catalog")
[[ "$profile_count" == 1 ]] || die "unknown or duplicate performance profile: $profile"
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
[[ "$producer_concurrency" == 1 && "$consumer_concurrency" == 1 ]] ||
  die "profile $profile requires unsupported concurrency (producer=$producer_concurrency, consumer=$consumer_concurrency); this runner is serial"
protocol=${PERF_PROTOCOL:-$(yq -r '.defaults.protocol' "$profile_catalog")}
destination=${PERF_DESTINATION:-"performance.$profile"}

case "$protocol" in
  amqp) local_url="amqp://host.docker.internal:${ARTEMIS_AMQP_PORT:-5672}" ;;
  openwire) local_url="tcp://host.docker.internal:${ARTEMIS_OPENWIRE_PORT:-61616}" ;;
  *) die "unsupported PERF_PROTOCOL: $protocol" ;;
esac

if [[ "$target" == local ]]; then
  broker_url=${PERF_URL:-$local_url}
  username=${PERF_USERNAME:-localdev}
  password=${PERF_PASSWORD:-localdev}
elif [[ "$target" == deployed ]]; then
  broker_url=${PERF_URL:-}
  username=${PERF_USERNAME:-}
  password=${PERF_PASSWORD:-}
  [[ -n "$broker_url" ]] || die 'PERF_URL is required for a deployed target'
  [[ -n "$username" ]] || die 'PERF_USERNAME is required for a deployed target'
  [[ -n "$password" ]] || die 'PERF_PASSWORD is required for a deployed target'
else
  [[ -n "$context" && -n "$cluster" && -n "$namespace" ]] ||
    die 'tunneled target requires --context, --cluster, and --namespace'
  command -v kubectl >/dev/null 2>&1 || die 'kubectl is required for a tunneled target'
  actual_context=$(kubectl config current-context)
  [[ "$actual_context" == "$context" ]] ||
    die "current context $actual_context does not match $context"
  actual_cluster=$(kubectl config view --minify --context "$context" \
    -o jsonpath='{.clusters[0].name}')
  [[ "$actual_cluster" == "$cluster" ]] ||
    die "selected context maps to cluster $actual_cluster, not $cluster"
  case "${PERF_TLS-0}" in
    ''|0|false|no) ;;
    1|true|yes) tunnel_tls=1 ;;
    *) die 'PERF_TLS must be true or false for a tunneled target' ;;
  esac
  broker_url=''
  username=${PERF_USERNAME-}
  password=${PERF_PASSWORD-}
  [[ -n "$username" ]] || die 'PERF_USERNAME is required for a tunneled target'
  [[ -n "$password" ]] || die 'PERF_PASSWORD is required for a tunneled target'
fi

if [[ "$report_dir" != /* ]]; then
  report_dir="$script_dir/$report_dir"
fi
mkdir -p "$report_dir"
report_dir=$(CDPATH= cd -- "$report_dir" && pwd)
run_id="${target}-${profile}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
id_prefix="$run_id-"

cleanup_tunnel() {
  if [[ -n "$tunnel_pid" ]] && kill -0 "$tunnel_pid" >/dev/null 2>&1; then
    kill -TERM "$tunnel_pid" >/dev/null 2>&1 || true
    wait "$tunnel_pid" >/dev/null 2>&1 || true
  fi
}

tunnel_pid_alive() {
  local process_state
  [[ -n "$tunnel_pid" ]] || return 1
  kill -0 "$tunnel_pid" >/dev/null 2>&1 || return 1
  process_state=$(ps -o stat= -p "$tunnel_pid" 2>/dev/null || true)
  [[ "$process_state" != *Z* ]]
}

ensure_tunnel_alive() {
  if [[ -n "$tunnel_pid" ]] && ! tunnel_pid_alive; then
    printf 'tunnel supervisor exited; see %s\n' "$report_dir/tunnel/supervisor.log" >&2
    exit 1
  fi
}

docker_network_args=(--add-host host.docker.internal:host-gateway)
if [[ "$target" == tunneled ]]; then
  tunnel_mode='kubectl-port-forward'
  tunnel_dir="$report_dir/tunnel"
  mkdir -p "$tunnel_dir"
  tunnel_env_file="$tunnel_dir/tunnel.env"
  tunnel_status_file="$tunnel_dir/tunnel-status.env"
  tunnel_command=(
    "$script_dir/kubectl-tunnel.sh"
    --context "$context"
    --namespace "$namespace"
    --selector "$broker_selector"
    --protocol "$protocol"
    --local-port-a "$tunnel_port_a"
    --local-port-b "$tunnel_port_b"
    --max-restarts "$tunnel_max_restarts"
    --startup-timeout-seconds "$tunnel_startup_timeout_seconds"
    --pod-wait-timeout-seconds "$tunnel_pod_wait_timeout_seconds"
    --retry-delay-seconds "$tunnel_retry_delay_seconds"
    --poll-seconds "$tunnel_poll_seconds"
    --env-file "$tunnel_env_file"
    --status-file "$tunnel_status_file"
    --log-dir "$tunnel_dir"
  )
  if ((tunnel_tls)); then
    [[ -n "$tunnel_tls_hostname" ]] || die 'TLS tunneling requires --tls-hostname'
    tunnel_command+=(--tls --tls-hostname "$tunnel_tls_hostname")
  fi
  trap cleanup_tunnel EXIT
  trap 'exit 130' INT
  "${tunnel_command[@]}" > "$tunnel_dir/supervisor.log" 2>&1 &
  tunnel_pid=$!
  tunnel_deadline=$((SECONDS + tunnel_startup_timeout_seconds + tunnel_pod_wait_timeout_seconds))
  while [[ ! -s "$tunnel_env_file" ]]; do
    if ! tunnel_pid_alive; then
      set +e
      wait "$tunnel_pid"
      tunnel_exit=$?
      set -e
      printf 'tunnel supervisor exited with %s; see %s\n' \
        "$tunnel_exit" "$tunnel_dir/supervisor.log" >&2
      exit 1
    fi
    ((SECONDS < tunnel_deadline)) ||
      die "tunnel supervisor did not become ready; see $tunnel_dir/supervisor.log"
    sleep 1
  done
  . "$tunnel_env_file"
  broker_url="$PERF_TUNNEL_URL"
  if ((tunnel_tls)); then
    docker_network_args+=(--add-host "$PERF_TUNNEL_TLS_HOSTNAME:host-gateway")
  fi
fi
trap cleanup_tunnel EXIT

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
docker_run_args=(--rm "${docker_network_args[@]}")
if [[ -n "${PERF_TRUST_STORE_PATH-}" ]]; then
  [[ -f "$PERF_TRUST_STORE_PATH" ]] ||
    die "trust store does not exist: $PERF_TRUST_STORE_PATH"
  [[ -n "${PERF_TRUST_STORE_PASSWORD-}" ]] ||
    die 'PERF_TRUST_STORE_PASSWORD is required with PERF_TRUST_STORE_PATH'
  docker_run_args+=(--volume "$PERF_TRUST_STORE_PATH:/run/validation/truststore:ro")
  docker_env+=(--env "JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=/tmp -Djavax.net.ssl.trustStore=/run/validation/truststore -Djavax.net.ssl.trustStorePassword=$PERF_TRUST_STORE_PASSWORD -Djavax.net.ssl.trustStoreType=${PERF_TRUST_STORE_TYPE:-PKCS12}")
fi

printf 'performance profile: %s (%s messages x %s payload bytes; %ss duration guidance)\n' \
  "$profile" "$message_count" "$payload_bytes" "$profile_duration"
printf 'target: %s; protocol: %s; destination: %s\n' \
  "$target" "$protocol" "$destination"

ensure_tunnel_alive
docker run "${docker_run_args[@]}" \
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

ensure_tunnel_alive
docker run "${docker_run_args[@]}" \
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

ensure_tunnel_alive
tunnel_pod_a=${PERF_TUNNEL_POD_A-}
tunnel_pod_b=${PERF_TUNNEL_POD_B-}
tunnel_port_a_report=${PERF_TUNNEL_PORT_A-}
tunnel_port_b_report=${PERF_TUNNEL_PORT_B-}
REPORT_TARGET=$target \
REPORT_PROFILE=$profile \
REPORT_PROTOCOL=$protocol \
REPORT_DESTINATION=$destination \
REPORT_RUN_ID=$run_id \
REPORT_MESSAGE_COUNT=$message_count \
REPORT_PAYLOAD_BYTES=$payload_bytes \
REPORT_PROFILE_DURATION=$profile_duration \
REPORT_TUNNEL_MODE=$tunnel_mode \
REPORT_TUNNEL_POD_A=$tunnel_pod_a \
REPORT_TUNNEL_POD_B=$tunnel_pod_b \
REPORT_TUNNEL_PORT_A=$tunnel_port_a_report \
REPORT_TUNNEL_PORT_B=$tunnel_port_b_report \
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
    "consumeReport": "consume.json",
    "tunnel": ({
      "none": null,
      "kubectl-port-forward": {
        "mode": strenv(REPORT_TUNNEL_MODE),
        "podA": strenv(REPORT_TUNNEL_POD_A),
        "podB": strenv(REPORT_TUNNEL_POD_B),
        "portA": ((strenv(REPORT_TUNNEL_PORT_A) | select(. != "") | tonumber) // null),
        "portB": ((strenv(REPORT_TUNNEL_PORT_B) | select(. != "") | tonumber) // null),
        "envFile": "tunnel/tunnel.env",
        "statusFile": "tunnel/tunnel-status.env"
      }
    }[strenv(REPORT_TUNNEL_MODE)])
  }' > "$report_dir/run.json"

printf 'performance validation passed; reports: %s\n' "$report_dir"
