#!/usr/bin/env bash
set -euo pipefail

# Keep tunnel lifecycle separate from the JMS client. Both producer and
# consumer use the same two loopback ports and the provider's own failover
# implementation.

context=''
namespace=''
selector=''
pod_a=''
pod_b=''
protocol=''
local_port_a=25672
local_port_b=25673
remote_port=''
endpoint_host=host.docker.internal
tls=0
tls_hostname=''
env_file=''
status_file=''
log_dir=''
max_restarts=5
startup_timeout_seconds=15
pod_wait_timeout_seconds=180
retry_delay_seconds=1
poll_seconds=1

pid_a=''
pid_b=''
uid_a=''
uid_b=''
ready_a=0
ready_b=0
restart_count_a=0
restart_count_b=0
last_event_a=''
last_event_b=''
supervisor_failed=0
stopping=0

usage() {
  printf '%s\n' \
    'Usage: kubectl-tunnel.sh --context CONTEXT --namespace NAMESPACE --protocol amqp|openwire [options]' \
    '' \
    'Select exactly two stable broker pods with either --pod-a/--pod-b or --selector.' \
    'The supervisor binds only 127.0.0.1 and writes the generated endpoint to --env-file.' \
    '' \
    'Options:' \
    '  --pod-a POD                         First stable broker pod' \
    '  --pod-b POD                         Second stable broker pod' \
    '  --selector SELECTOR                 Select exactly two broker pods' \
    '  --local-port-a PORT                 Loopback port for pod A (default: 25672)' \
    '  --local-port-b PORT                 Loopback port for pod B (default: 25673)' \
    '  --remote-port PORT                  Broker port; defaults by protocol/TLS' \
    '  --endpoint-host HOST                Client endpoint host (default: host.docker.internal)' \
    '  --tls                               Use amqps/ssl and require --tls-hostname' \
    '  --tls-hostname HOST                 TLS SNI/certificate hostname' \
    '  --env-file FILE                     Atomic client environment output' \
    '  --status-file FILE                  Atomic supervisor status output' \
    '  --log-dir DIRECTORY                 Per-slot kubectl logs' \
    '  --max-restarts N                    Supervisor restarts per slot (default: 5)' \
    '  --startup-timeout-seconds N         Forwarding-line readiness timeout (default: 15)' \
    '  --pod-wait-timeout-seconds N        Pod replacement wait bound (default: 180)' \
    '  --retry-delay-seconds N             Delay between bounded retries (default: 1)' \
    '  --poll-seconds N                    Pod/process poll interval (default: 1)' \
    '  -h, --help                          Show this help'
}

die() {
  printf 'kubectl-tunnel: %s\n' "$*" >&2
  exit 2
}

fail_supervisor() {
  supervisor_failed=1
  write_status FAILED "$*" || true
  printf 'kubectl-tunnel: %s\n' "$*" >&2
  exit 1
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

require_non_negative_integer() {
  local option=$1
  local value=$2
  [[ "$value" =~ ^[0-9][0-9]*$ ]] || die "$option must be a non-negative integer"
}

require_port() {
  local option=$1
  local value=$2
  require_positive_integer "$option" "$value"
  ((value <= 65535)) || die "$option must be between 1 and 65535"
}

shell_quote() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

slot_value() {
  local slot=$1
  local field=$2
  case "$slot:$field" in
    a:pid) printf '%s' "$pid_a" ;;
    b:pid) printf '%s' "$pid_b" ;;
    a:pod) printf '%s' "$pod_a" ;;
    b:pod) printf '%s' "$pod_b" ;;
    a:port) printf '%s' "$local_port_a" ;;
    b:port) printf '%s' "$local_port_b" ;;
    a:uid) printf '%s' "$uid_a" ;;
    b:uid) printf '%s' "$uid_b" ;;
    a:ready) printf '%s' "$ready_a" ;;
    b:ready) printf '%s' "$ready_b" ;;
    a:restarts) printf '%s' "$restart_count_a" ;;
    b:restarts) printf '%s' "$restart_count_b" ;;
    a:event) printf '%s' "$last_event_a" ;;
    b:event) printf '%s' "$last_event_b" ;;
    *) return 1 ;;
  esac
}

set_slot_value() {
  local slot=$1
  local field=$2
  local value=$3
  case "$slot:$field" in
    a:pid) pid_a=$value ;;
    b:pid) pid_b=$value ;;
    a:uid) uid_a=$value ;;
    b:uid) uid_b=$value ;;
    a:ready) ready_a=$value ;;
    b:ready) ready_b=$value ;;
    a:restarts) restart_count_a=$value ;;
    b:restarts) restart_count_b=$value ;;
    a:event) last_event_a=$value ;;
    b:event) last_event_b=$value ;;
    *) return 1 ;;
  esac
}

pod_identity() {
  local pod=$1
  local identity
  identity=$("${kube[@]}" get pod "$pod" -o 'jsonpath={.metadata.uid}{"\t"}{.status.phase}' 2>/dev/null) || return 1
  local uid=${identity%%$'\t'*}
  local phase=${identity#*$'\t'}
  [[ -n "$uid" && "$uid" != "$identity" && "$phase" == Running ]] || return 1
  printf '%s\t%s' "$uid" "$phase"
}

select_pods() {
  local names
  [[ -n "$selector" ]] || return 0
  names=$("${kube[@]}" get pods -l "$selector" -o name 2>/dev/null) ||
    die "could not list pods for selector $selector"
  pod_a=$(printf '%s\n' "$names" | sed 's#^pod/##' | sed '/^$/d' | sort -u | sed -n '1p')
  pod_b=$(printf '%s\n' "$names" | sed 's#^pod/##' | sed '/^$/d' | sort -u | sed -n '2p')
  [[ -n "$pod_a" && -n "$pod_b" ]] ||
    die "selector $selector must match exactly two broker pods"
  local extra
  extra=$(printf '%s\n' "$names" | sed 's#^pod/##' | sed '/^$/d' | sort -u | sed -n '3p')
  [[ -z "$extra" ]] || die "selector $selector matched more than two broker pods"
}

wait_for_pod() {
  local slot=$1
  local pod
  pod=$(slot_value "$slot" pod)
  local deadline=$((SECONDS + pod_wait_timeout_seconds))
  local identity
  while ((SECONDS <= deadline)); do
    if identity=$(pod_identity "$pod"); then
      printf '%s' "$identity"
      return 0
    fi
    sleep "$poll_seconds"
  done
  printf 'pod %s did not become Running within %s seconds' \
    "$pod" "$pod_wait_timeout_seconds" >&2
  return 1
}

forward_log() {
  local slot=$1
  printf '%s/%s-port-forward.log' "$log_dir" "$slot"
}

forward_ready() {
  local slot=$1
  local port=$2
  local log_file
  log_file=$(forward_log "$slot")
  grep -Eq "Forwarding from .*:${port} -> ${remote_port}" "$log_file" 2>/dev/null
}

start_forward() {
  local slot=$1
  local pod
  local port
  local pid
  local log_file
  local deadline
  pod=$(slot_value "$slot" pod)
  port=$(slot_value "$slot" port)
  log_file=$(forward_log "$slot")
  mkdir -p "$log_dir"
  printf '[%s] starting pod=%s local=%s remote=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pod" "$port" "$remote_port" >> "$log_file"
  set +e
  "${kube[@]}" port-forward --address 127.0.0.1 "pod/$pod" \
    "$port:$remote_port" >> "$log_file" 2>&1 &
  pid=$!
  set -e
  set_slot_value "$slot" pid "$pid"
  set_slot_value "$slot" ready 0
  deadline=$((SECONDS + startup_timeout_seconds))
  while ((SECONDS <= deadline)); do
    if forward_ready "$slot" "$port"; then
      set_slot_value "$slot" ready 1
      set_slot_value "$slot" event 'ready'
      write_status RUNNING "${slot} tunnel ready"
      return 0
    fi
    if ! pid_alive "$pid"; then
      local exit_code
      exit_code=$(reap_pid "$pid")
      set_slot_value "$slot" pid ''
      set_slot_value "$slot" event "port-forward exited with $exit_code"
      return 1
    fi
    sleep 0.1
  done
  set_slot_value "$slot" event 'port-forward did not report readiness'
  stop_pid "$pid"
  set_slot_value "$slot" pid ''
  return 1
}

increment_restart_count() {
  local slot=$1
  local count
  count=$(slot_value "$slot" restarts)
  count=$((count + 1))
  set_slot_value "$slot" restarts "$count"
  ((count <= max_restarts)) || return 1
}

restart_slot() {
  local slot=$1
  local reason=$2
  local pod
  local identity
  local current_uid
  local deadline=$((SECONDS + pod_wait_timeout_seconds))
  pod=$(slot_value "$slot" pod)
  set_slot_value "$slot" ready 0
  set_slot_value "$slot" event "$reason"
  stop_pid "$(slot_value "$slot" pid)"
  set_slot_value "$slot" pid ''
  write_status RUNNING "$slot: $reason"

  while ((SECONDS <= deadline)); do
    if identity=$(pod_identity "$pod"); then
      current_uid=${identity%%$'\t'*}
      set_slot_value "$slot" uid "$current_uid"
      if start_forward "$slot"; then
        write_env
        write_status RUNNING "$slot tunnel recovered"
        return 0
      fi
      if ! increment_restart_count "$slot"; then
        local log_file
        log_file=$(forward_log "$slot")
        printf 'kubectl-tunnel: %s exceeded max restarts (%s); log=%s\n' \
          "$slot" "$max_restarts" "$log_file" >&2
        sed -n '1,120p' "$log_file" >&2 || true
        return 1
      fi
      sleep "$retry_delay_seconds"
    else
      sleep "$poll_seconds"
    fi
  done
  printf 'kubectl-tunnel: pod %s did not recover within %s seconds (%s)\n' \
    "$pod" "$pod_wait_timeout_seconds" "$reason" >&2
  return 1
}

monitor_slot() {
  local slot=$1
  local pid
  local pod
  local identity
  local current_uid
  pid=$(slot_value "$slot" pid)
  if ! pid_alive "$pid"; then
    reap_pid "$pid" >/dev/null 2>&1 || true
    set_slot_value "$slot" pid ''
    if ! increment_restart_count "$slot"; then
      return 1
    fi
    restart_slot "$slot" 'port-forward process exited' || return 1
    return 0
  fi

  pod=$(slot_value "$slot" pod)
  if ! identity=$(pod_identity "$pod"); then
    if ! increment_restart_count "$slot"; then
      return 1
    fi
    restart_slot "$slot" 'pod is absent or not Running' || return 1
    return 0
  fi
  current_uid=${identity%%$'\t'*}
  if [[ "$current_uid" != "$(slot_value "$slot" uid)" ]]; then
    if ! increment_restart_count "$slot"; then
      return 1
    fi
    restart_slot "$slot" "pod UID changed to $current_uid" || return 1
  fi
  return 0
}

start_initial_slot() {
  local slot=$1
  if start_forward "$slot"; then
    return 0
  fi
  if ! increment_restart_count "$slot"; then
    return 1
  fi
  restart_slot "$slot" 'initial port-forward failure'
}

cleanup() {
  ((stopping)) && return 0
  stopping=1
  if ((supervisor_failed)); then
    write_status FAILED 'supervisor failed' || true
  else
    write_status STOPPING 'received shutdown' || true
  fi
  stop_pid "$pid_a"
  stop_pid "$pid_b"
  pid_a=''
  pid_b=''
}

main() {
while (($#)); do
  case "$1" in
    --context) require_value "$1" "${2-}"; context=$2; shift 2 ;;
    --namespace) require_value "$1" "${2-}"; namespace=$2; shift 2 ;;
    --selector) require_value "$1" "${2-}"; selector=$2; shift 2 ;;
    --pod-a) require_value "$1" "${2-}"; pod_a=$2; shift 2 ;;
    --pod-b) require_value "$1" "${2-}"; pod_b=$2; shift 2 ;;
    --protocol) require_value "$1" "${2-}"; protocol=$2; shift 2 ;;
    --local-port-a) require_value "$1" "${2-}"; local_port_a=$2; shift 2 ;;
    --local-port-b) require_value "$1" "${2-}"; local_port_b=$2; shift 2 ;;
    --remote-port) require_value "$1" "${2-}"; remote_port=$2; shift 2 ;;
    --endpoint-host) require_value "$1" "${2-}"; endpoint_host=$2; shift 2 ;;
    --tls) tls=1; shift ;;
    --tls-hostname) require_value "$1" "${2-}"; tls_hostname=$2; shift 2 ;;
    --env-file) require_value "$1" "${2-}"; env_file=$2; shift 2 ;;
    --status-file) require_value "$1" "${2-}"; status_file=$2; shift 2 ;;
    --log-dir) require_value "$1" "${2-}"; log_dir=$2; shift 2 ;;
    --max-restarts) require_value "$1" "${2-}"; max_restarts=$2; shift 2 ;;
    --startup-timeout-seconds)
      require_value "$1" "${2-}"; startup_timeout_seconds=$2; shift 2 ;;
    --pod-wait-timeout-seconds)
      require_value "$1" "${2-}"; pod_wait_timeout_seconds=$2; shift 2 ;;
    --retry-delay-seconds) require_value "$1" "${2-}"; retry_delay_seconds=$2; shift 2 ;;
    --poll-seconds) require_value "$1" "${2-}"; poll_seconds=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$context" ]] || die '--context is required'
[[ -n "$namespace" ]] || die '--namespace is required'
case "$protocol" in
  amqp|openwire) ;;
  *) die '--protocol must be amqp or openwire' ;;
esac
if [[ -n "$selector" && ( -n "$pod_a" || -n "$pod_b" ) ]]; then
  die 'use --selector or --pod-a/--pod-b, not both'
fi
if [[ -z "$selector" && ( -z "$pod_a" || -z "$pod_b" ) ]]; then
  die 'provide both --pod-a and --pod-b, or --selector'
fi
require_port --local-port-a "$local_port_a"
require_port --local-port-b "$local_port_b"
[[ "$local_port_a" != "$local_port_b" ]] || die 'local tunnel ports must be different'
if [[ -z "$remote_port" ]]; then
  if ((tls)); then
    if [[ "$protocol" == amqp ]]; then remote_port=5671; else remote_port=61617; fi
  else
    if [[ "$protocol" == amqp ]]; then remote_port=5672; else remote_port=61616; fi
  fi
fi
require_port --remote-port "$remote_port"
if ((tls)); then
  [[ -n "$tls_hostname" ]] ||
    die 'TLS tunneling requires --tls-hostname; host.docker.internal cannot satisfy broker certificate verification'
fi
require_positive_integer --max-restarts "$max_restarts"
require_positive_integer --startup-timeout-seconds "$startup_timeout_seconds"
require_positive_integer --pod-wait-timeout-seconds "$pod_wait_timeout_seconds"
require_non_negative_integer --retry-delay-seconds "$retry_delay_seconds"
require_positive_integer --poll-seconds "$poll_seconds"
command -v kubectl >/dev/null 2>&1 || die 'kubectl is required'

kube=(kubectl --context "$context" --namespace "$namespace")
if [[ -z "$log_dir" ]]; then
  log_dir="${TMPDIR:-/tmp}/artemis-kubectl-tunnel-$$"
fi
mkdir -p "$log_dir"
if [[ -z "$env_file" ]]; then env_file="$log_dir/tunnel.env"; fi
if [[ -z "$status_file" ]]; then status_file="$log_dir/tunnel-status.env"; fi
select_pods
client_url=$(build_client_url)

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! wait_for_pod a >/dev/null; then fail_supervisor "pod $pod_a is not Running"; fi
if ! wait_for_pod b >/dev/null; then fail_supervisor "pod $pod_b is not Running"; fi
uid_a=$(wait_for_pod a | sed 's/\t.*//')
uid_b=$(wait_for_pod b | sed 's/\t.*//')
write_status STARTING 'initializing two pod tunnels'

if ! start_initial_slot a; then
  fail_supervisor "could not start tunnel for pod $pod_a; log=$(forward_log a)"
fi
if ! start_initial_slot b; then
  fail_supervisor "could not start tunnel for pod $pod_b; log=$(forward_log b)"
fi
write_env
write_status READY 'both pod tunnels ready'
printf 'kubectl tunnel ready: %s\n' "$client_url"
printf '  pod-a=%s uid=%s port=%s\n' "$pod_a" "$uid_a" "$local_port_a"
printf '  pod-b=%s uid=%s port=%s\n' "$pod_b" "$uid_b" "$local_port_b"

while :; do
  monitor_slot a || fail_supervisor "tunnel A failed; log=$(forward_log a)"
  monitor_slot b || fail_supervisor "tunnel B failed; log=$(forward_log b)"
  write_status READY 'both pod tunnels healthy'
  sleep "$poll_seconds"
done

}

write_atomic() {
  local destination=$1
  local temporary="${destination}.tmp.$$"
  shift
  mkdir -p "$(dirname -- "$destination")"
  umask 077
  "$@" > "$temporary"
  mv -f "$temporary" "$destination"
}

build_client_url() {
  local scheme
  local host=$endpoint_host
  if ((tls)); then
    if [[ "$protocol" == amqp ]]; then
      scheme=amqps
    else
      scheme=ssl
    fi
    host=$tls_hostname
  else
    if [[ "$protocol" == amqp ]]; then
      scheme=amqp
    else
      scheme=tcp
    fi
  fi

  if [[ "$protocol" == amqp ]]; then
    printf 'failover:(%s://%s:%s,%s://%s:%s)?failover.maxReconnectAttempts=-1&failover.startupMaxReconnectAttempts=-1&failover.initialReconnectDelay=100&failover.reconnectDelay=1000&failover.useReconnectBackOff=false' \
      "$scheme" "$host" "$local_port_a" "$scheme" "$host" "$local_port_b"
  elif ((tls)); then
    printf 'failover:(%s://%s:%s,%s://%s:%s)?randomize=false&maxReconnectAttempts=-1&startupMaxReconnectAttempts=-1&initialReconnectDelay=100&reconnectDelay=1000&nested.verifyHostName=true' \
      "$scheme" "$host" "$local_port_a" "$scheme" "$host" "$local_port_b"
  else
    printf 'failover:(%s://%s:%s,%s://%s:%s)?randomize=false&maxReconnectAttempts=-1&startupMaxReconnectAttempts=-1&initialReconnectDelay=100&reconnectDelay=1000' \
      "$scheme" "$host" "$local_port_a" "$scheme" "$host" "$local_port_b"
  fi
}

client_url=''

write_env_contents() {
  printf '%s=%s\n' 'PERF_TUNNEL_URL' "$(shell_quote "$client_url")"
  printf '%s=%s\n' 'PERF_TUNNEL_PROTOCOL' "$(shell_quote "$protocol")"
  printf '%s=%s\n' 'PERF_TUNNEL_ENDPOINT_HOST' "$(shell_quote "$endpoint_host")"
  printf '%s=%s\n' 'PERF_TUNNEL_TLS_HOSTNAME' "$(shell_quote "$tls_hostname")"
  printf '%s=%s\n' 'PERF_TUNNEL_DOCKER_HOST_ALIAS' "$(shell_quote "$tls_hostname")"
  printf '%s=%s\n' 'PERF_TUNNEL_REMOTE_PORT' "$(shell_quote "$remote_port")"
  printf '%s=%s\n' 'PERF_TUNNEL_PORT_A' "$(shell_quote "$local_port_a")"
  printf '%s=%s\n' 'PERF_TUNNEL_PORT_B' "$(shell_quote "$local_port_b")"
  printf '%s=%s\n' 'PERF_TUNNEL_POD_A' "$(shell_quote "$pod_a")"
  printf '%s=%s\n' 'PERF_TUNNEL_POD_B' "$(shell_quote "$pod_b")"
  printf '%s=%s\n' 'PERF_TUNNEL_UID_A' "$(shell_quote "$uid_a")"
  printf '%s=%s\n' 'PERF_TUNNEL_UID_B' "$(shell_quote "$uid_b")"
  printf '%s=%s\n' 'PERF_TUNNEL_ENV_FILE' "$(shell_quote "$env_file")"
  printf '%s=%s\n' 'PERF_TUNNEL_STATUS_FILE' "$(shell_quote "$status_file")"
}

write_env() {
  [[ -n "$env_file" ]] || return 0
  write_atomic "$env_file" write_env_contents
}

write_status_contents() {
  local state=$1
  local event=$2
  printf '%s=%s\n' 'PERF_TUNNEL_STATE' "$(shell_quote "$state")"
  printf '%s=%s\n' 'PERF_TUNNEL_LAST_EVENT' "$(shell_quote "$event")"
  printf '%s=%s\n' 'PERF_TUNNEL_PROTOCOL' "$(shell_quote "$protocol")"
  printf '%s=%s\n' 'PERF_TUNNEL_URL' "$(shell_quote "$client_url")"
  printf '%s=%s\n' 'PERF_TUNNEL_POD_A' "$(shell_quote "$pod_a")"
  printf '%s=%s\n' 'PERF_TUNNEL_POD_B' "$(shell_quote "$pod_b")"
  printf '%s=%s\n' 'PERF_TUNNEL_UID_A' "$(shell_quote "$uid_a")"
  printf '%s=%s\n' 'PERF_TUNNEL_UID_B' "$(shell_quote "$uid_b")"
  printf '%s=%s\n' 'PERF_TUNNEL_SLOT_A_READY' "$(shell_quote "$ready_a")"
  printf '%s=%s\n' 'PERF_TUNNEL_SLOT_B_READY' "$(shell_quote "$ready_b")"
  printf '%s=%s\n' 'PERF_TUNNEL_SLOT_A_RESTARTS' "$(shell_quote "$restart_count_a")"
  printf '%s=%s\n' 'PERF_TUNNEL_SLOT_B_RESTARTS' "$(shell_quote "$restart_count_b")"
  printf '%s=%s\n' 'PERF_TUNNEL_PORT_A' "$(shell_quote "$local_port_a")"
  printf '%s=%s\n' 'PERF_TUNNEL_PORT_B' "$(shell_quote "$local_port_b")"
  printf '%s=%s\n' 'PERF_TUNNEL_STATUS_FILE' "$(shell_quote "$status_file")"
}

write_status() {
  local state=${1:-RUNNING}
  local event=${2:-}
  [[ -n "$status_file" ]] || return 0
  write_atomic "$status_file" write_status_contents "$state" "$event"
}

pid_alive() {
  local pid=$1
  local process_state
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  process_state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
  [[ "$process_state" != *Z* ]]
}

reap_pid() {
  local pid=$1
  local exit_code=0
  set +e
  wait "$pid"
  exit_code=$?
  set -e
  printf '%s' "$exit_code"
}

stop_pid() {
  local pid=${1-}
  local deadline
  [[ -n "$pid" ]] || return 0
  if pid_alive "$pid"; then
    kill -TERM "$pid" >/dev/null 2>&1 || true
    deadline=$((SECONDS + 3))
    while pid_alive "$pid" && ((SECONDS < deadline)); do
      sleep 0.1
    done
    if pid_alive "$pid"; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  fi
  reap_pid "$pid" >/dev/null 2>&1 || true
}

main "$@"
