#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runner="$script_dir/run-profile.sh"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-profile-script.XXXXXX")

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT

fake_bin="$temp_dir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

joined="$*"
if [[ "$joined" == *'config current-context'* ]]; then
  printf '%s' test-context
elif [[ "$joined" == *'config view'* ]]; then
  printf '%s' test-cluster
elif [[ "$joined" == *'get pods '*'-o name' ]]; then
  printf '%s\n' pod/broker-0 pod/broker-1
elif [[ "$joined" == *'get pod broker-0 '* ]]; then
  printf '%s\t%s' uid-a Running
elif [[ "$joined" == *'get pod broker-1 '* ]]; then
  printf '%s\t%s' uid-b Running
elif [[ "$joined" == *'port-forward'* ]]; then
  pod=''
  port_spec=''
  for argument in "$@"; do
    case "$argument" in
      pod/*) pod=${argument#pod/} ;;
      *:*) port_spec=$argument ;;
    esac
  done
  printf 'Forwarding from 127.0.0.1:%s -> %s\n' \
    "${port_spec%%:*}" "${port_spec#*:}"
  trap 'exit 0' TERM INT
  while :; do
    sleep 0.1
  done
else
  printf 'unexpected fake kubectl invocation: %s\n' "$joined" >&2
  exit 2
fi
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
[[ -n "$report_dir" ]] || {
  printf '%s\n' 'fake docker did not receive /reports volume' >&2
  exit 2
}

if [[ "$*" == *'validation.Main send'* ]]; then
  printf '%s\n' $'0\tprofile-id-0' $'1\tprofile-id-1' $'2\tprofile-id-2' \
    > "$report_dir/acknowledged.tsv"
  printf '%s\n' '{"acknowledgedCount":3,"unacknowledgedSequences":[]}' \
    > "$report_dir/send.json"
elif [[ "$*" == *'validation.Main consume'* ]]; then
  printf '%s\n' '{"receivedCount":3,"uniqueCount":3,"acknowledgedCount":3}' \
    > "$report_dir/consume.json"
else
  printf 'unexpected fake docker invocation: %s\n' "$*" >&2
  exit 2
fi
EOF
chmod 755 "$fake_bin/docker"

report_dir="$temp_dir/report"
PATH="$fake_bin:$PATH" \
PERF_USERNAME=test-user \
PERF_PASSWORD=test-password \
IMAGE=test-image \
  "$runner" \
    --target tunneled \
    --context test-context \
    --cluster test-cluster \
    --namespace test-namespace \
    --broker-selector 'app.kubernetes.io/component=broker' \
    --profile burst \
    --report-dir "$report_dir"

yq -e '
  .target == "tunneled" and
  .tunnel.mode == "kubectl-port-forward" and
  .tunnel.podA == "broker-0" and
  .tunnel.podB == "broker-1" and
  .tunnel.portA == 25672 and
  .tunnel.portB == 25673
' "$report_dir/run.json" >/dev/null ||
  fail 'tunneled profile report omitted the supervised connection'

[[ -f "$report_dir/tunnel/tunnel-status.env" ]] ||
  fail 'tunneled profile did not preserve the tunnel status evidence'
[[ "$(wc -l < "$report_dir/acknowledged.tsv" | tr -d ' ')" == 3 ]] ||
  fail 'tunneled profile did not run the producer through the fake Docker client'
[[ -f "$report_dir/consume.json" ]] ||
  fail 'tunneled profile did not run the consumer through the fake Docker client'

local_report="$temp_dir/local-report"
PATH="$fake_bin:$PATH" \
PERF_URL='amqp://host.docker.internal:5672' \
PERF_USERNAME=test-user \
PERF_PASSWORD=test-password \
IMAGE=test-image \
  "$runner" \
    --target local \
    --profile burst \
    --report-dir "$local_report"
yq -e '.target == "local" and .tunnel == null' "$local_report/run.json" >/dev/null ||
  fail 'direct profile report did not preserve a null tunnel field'

printf '%s\n' 'profile script tests: PASS'
