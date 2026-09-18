#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tunnel="$script_dir/kubectl-tunnel.sh"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-kubectl-tunnel.XXXXXX")
current_pid=''

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$current_pid" ]] && kill -0 "$current_pid" >/dev/null 2>&1; then
    kill -TERM "$current_pid" >/dev/null 2>&1 || true
    wait "$current_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$temp_dir"
}
trap cleanup EXIT

wait_for_file() {
  local path=$1
  local deadline=$((SECONDS + 10))
  while ((SECONDS <= deadline)); do
    [[ -s "$path" ]] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_status_value() {
  local path=$1
  local expected=$2
  local deadline=$((SECONDS + 10))
  while ((SECONDS <= deadline)); do
    if [[ -s "$path" ]] && grep -Fq "$expected" "$path"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

stop_supervisor() {
  local exit_code=0
  [[ -n "$current_pid" ]] || return 0
  if kill -0 "$current_pid" >/dev/null 2>&1; then
    kill -TERM "$current_pid" >/dev/null 2>&1 || true
  fi
  set +e
  wait "$current_pid"
  exit_code=$?
  set -e
  [[ "$exit_code" == 0 || "$exit_code" == 130 || "$exit_code" == 143 ]] ||
    fail "supervisor exited unexpectedly with $exit_code"
  current_pid=''
}

new_case() {
  local name=$1
  case_dir="$temp_dir/$name"
  mkdir -p "$case_dir"
  printf '%s\n' uid-a > "$case_dir/broker-0.uid"
  printf '%s\n' uid-b > "$case_dir/broker-1.uid"
  export TUNNEL_TEST_STATE_DIR="$case_dir"
  export TUNNEL_TEST_MODE=normal
}

start_supervisor() {
  local case_dir=$1
  shift
  "$tunnel" \
    --context test-context \
    --namespace test-namespace \
    --pod-a broker-0 \
    --pod-b broker-1 \
    --protocol amqp \
    --local-port-a 31072 \
    --local-port-b 31073 \
    --max-restarts 3 \
    --startup-timeout-seconds 2 \
    --pod-wait-timeout-seconds 5 \
    --retry-delay-seconds 0 \
    --poll-seconds 1 \
    --env-file "$case_dir/tunnel.env" \
    --status-file "$case_dir/tunnel-status.env" \
    --log-dir "$case_dir/logs" \
    "$@" > "$case_dir/stdout" 2> "$case_dir/stderr" &
  current_pid=$!
  wait_for_file "$case_dir/tunnel.env" ||
    {
      sed -n '1,160p' "$case_dir/stdout" >&2 || true
      sed -n '1,160p' "$case_dir/stderr" >&2 || true
      sed -n '1,160p' "$case_dir/calls.log" >&2 || true
      fail 'supervisor did not publish its environment';
    }
}

assert_child_pids_stopped() {
  local pid_file=$1
  [[ -f "$pid_file" ]] || return 0
  while read -r pod pid; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" >/dev/null 2>&1; then
      fail "forward process for $pod survived supervisor shutdown: $pid"
    fi
  done < "$pid_file"
}

fake_bin="$temp_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=$TUNNEL_TEST_STATE_DIR
joined="$*"
printf '%s\n' "$joined" >> "$state_dir/calls.log"

if [[ "$joined" == *" get pods "*"-o name" ]]; then
  printf '%s\n' pod/broker-0 pod/broker-1
  exit 0
fi

if [[ "$joined" == *get*pod*broker-0* ]]; then
  uid=$(tr -d '\n' < "$state_dir/broker-0.uid")
  printf '%s\t%s' "$uid" Running
  exit 0
fi

if [[ "$joined" == *get*pod*broker-1* ]]; then
  uid=$(tr -d '\n' < "$state_dir/broker-1.uid")
  printf '%s\t%s' "$uid" Running
  exit 0
fi

if [[ "$joined" == *" port-forward "* ]]; then
  pod=''
  port_spec=''
  for argument in "$@"; do
    case "$argument" in
      pod/*) pod=${argument#pod/} ;;
      *:*) port_spec=$argument ;;
    esac
  done
  local_port=${port_spec%%:*}
  printf '%s\n' "$joined" >> "$state_dir/invocations.log"
  printf '%s %s\n' "$pod" "$$" >> "$state_dir/forward-pids.log"

  if [[ "$TUNNEL_TEST_MODE" == conflict ]]; then
    printf 'Unable to listen on port %s: Address already in use\n' "$local_port" >&2
    exit 1
  fi

  count_file="$state_dir/$pod.forward-count"
  count=0
  [[ -f "$count_file" ]] && count=$(tr -d '\n' < "$count_file")
  if [[ "$TUNNEL_TEST_MODE" == die-once &&
        "$pod" == broker-0 &&
        "$count" == 0 ]]; then
    printf '%s\n' $((count + 1)) > "$count_file"
    printf 'Forwarding from 127.0.0.1:%s -> %s\n' "$local_port" "${port_spec#*:}"
    sleep 0.2
    exit 137
  fi

  printf '%s\n' $((count + 1)) > "$count_file"
  printf 'Forwarding from 127.0.0.1:%s -> %s\n' "$local_port" "${port_spec#*:}"
  trap 'exit 0' TERM INT
  while :; do
    sleep 0.1
  done
fi

printf 'unexpected fake kubectl invocation: %s\n' "$joined" >&2
exit 2
EOF
chmod 755 "$fake_bin/kubectl"
export PATH="$fake_bin:$PATH"

new_case startup
start_supervisor "$case_dir"
. "$case_dir/tunnel.env"
[[ "$PERF_TUNNEL_URL" == failover:* ]] || fail 'AMQP tunnel URL did not use provider failover syntax'
[[ "$PERF_TUNNEL_URL" == *host.docker.internal:31072* &&
   "$PERF_TUNNEL_URL" == *host.docker.internal:31073* ]] ||
  fail 'AMQP tunnel URL omitted one of the supervised loopback endpoints'
grep -Fq -- '--address 127.0.0.1' "$case_dir/invocations.log" ||
  fail 'kubectl port-forward was not restricted to loopback'
startup_pids="$case_dir/forward-pids.log"
stop_supervisor
assert_child_pids_stopped "$startup_pids"

new_case forward-death
export TUNNEL_TEST_MODE=die-once
start_supervisor "$case_dir"
wait_for_status_value "$case_dir/tunnel-status.env" "PERF_TUNNEL_SLOT_A_RESTARTS='1'" ||
  fail 'supervisor did not restart a terminated port-forward'
[[ $(wc -l < "$case_dir/invocations.log" | tr -d ' ') -ge 3 ]] ||
  fail 'port-forward death test did not start both initial forwards and a replacement'
death_pids="$case_dir/forward-pids.log"
stop_supervisor
assert_child_pids_stopped "$death_pids"

new_case uid-replacement
start_supervisor "$case_dir"
printf '%s\n' uid-a-new > "$case_dir/broker-0.uid"
wait_for_status_value "$case_dir/tunnel-status.env" "PERF_TUNNEL_UID_A='uid-a-new'" ||
  fail 'supervisor did not restart the forward after a pod UID change'
grep -Fq "pod/broker-0 31072:5672" "$case_dir/invocations.log" ||
  fail 'UID replacement did not use the stable broker-0 slot'
uid_pids="$case_dir/forward-pids.log"
stop_supervisor
assert_child_pids_stopped "$uid_pids"

new_case tls
start_supervisor "$case_dir" --protocol openwire --tls --tls-hostname broker.example
. "$case_dir/tunnel.env"
[[ "$PERF_TUNNEL_URL" == failover:\(ssl://broker.example:31072,* ]] ||
  fail 'TLS tunnel URL did not use the supplied certificate hostname'
[[ "$PERF_TUNNEL_URL" == *nested.verifyHostName=true ]] ||
  fail 'TLS OpenWire tunnel URL did not require hostname verification'
tls_pids="$case_dir/forward-pids.log"
stop_supervisor
assert_child_pids_stopped "$tls_pids"

new_case bounded-failure
export TUNNEL_TEST_MODE=conflict
set +e
"$tunnel" \
  --context test-context \
  --namespace test-namespace \
  --pod-a broker-0 \
  --pod-b broker-1 \
  --protocol amqp \
  --local-port-a 31072 \
  --local-port-b 31073 \
  --max-restarts 2 \
  --startup-timeout-seconds 1 \
  --pod-wait-timeout-seconds 1 \
  --retry-delay-seconds 0 \
  --poll-seconds 1 \
  --env-file "$case_dir/tunnel.env" \
  --status-file "$case_dir/tunnel-status.env" \
  --log-dir "$case_dir/logs" > "$case_dir/stdout" 2> "$case_dir/stderr"
bounded_exit=$?
set -e
[[ "$bounded_exit" != 0 ]] || fail 'port conflict did not fail the supervisor'
grep -Fq 'exceeded max restarts' "$case_dir/stderr" ||
  fail 'bounded port conflict did not report the restart bound'
[[ $(wc -l < "$case_dir/invocations.log" | tr -d ' ') -le 3 ]] ||
  fail 'port conflict exceeded its bounded startup attempts'

new_case tls-missing-hostname
set +e
"$tunnel" \
  --context test-context \
  --namespace test-namespace \
  --pod-a broker-0 \
  --pod-b broker-1 \
  --protocol amqp \
  --tls \
  --local-port-a 31072 \
  --local-port-b 31073 \
  --env-file "$case_dir/tunnel.env" \
  --status-file "$case_dir/tunnel-status.env" \
  --log-dir "$case_dir/logs" > "$case_dir/stdout" 2> "$case_dir/stderr"
tls_exit=$?
set -e
[[ "$tls_exit" == 2 ]] || fail 'TLS without a hostname did not fail closed'
grep -Fq 'TLS tunneling requires --tls-hostname' "$case_dir/stderr" ||
  fail 'TLS hostname validation omitted its failure reason'

printf '%s\n' 'kubectl tunnel tests: PASS'
