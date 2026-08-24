#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
gitops_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd)
script="$gitops_dir/scripts/import-chef-activemq.py"
fixture="$test_dir/fixtures/environment.json"
policy="$test_dir/fixtures/policy.json"
chart="$gitops_dir/charts/artemis-ha"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-chef-import.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' 'python3 is required for Chef import tests' >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  printf '%s\n' 'jq is required for Chef import tests' >&2
  exit 2
}
command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required for Chef import tests' >&2
  exit 2
}
command -v helm >/dev/null 2>&1 || {
  printf '%s\n' 'helm is required for Chef import tests' >&2
  exit 2
}

output="$temp_dir/output"
python3 -B "$script" \
  --input "$fixture" \
  --output-dir "$output" \
  --policy "$policy" \
  --ssl-secret-name sample-broker-tls \
  --trust-secret-name sample-client-ca \
  --authenticated-broker sample-external \
  --jaas-secret-name sample-clients-jaas-config >/dev/null

internal="$output/sample-internal.artemis-values.candidate.yaml"
external="$output/sample-external.artemis-values.candidate.yaml"
report="$output/migration-report.json"

[[ -f "$internal" && -f "$external" && -f "$report" && -f "$output/migration-review.md" ]]
yq -e '.acceptors.artemis.port == 61616 and .acceptors.artemis.protocols == "CORE,OPENWIRE"' "$internal" >/dev/null
yq -e '.acceptors.websocket.extraParams.httpEnabled == "true"' "$internal" >/dev/null
yq -e '.acceptors | has("mqtt") | not' "$internal" >/dev/null
yq -e '.destinations."app-request".address == "APP.REQUEST"' "$internal" >/dev/null
yq -e '[.destinations[].address | select(. == "DLQ.APP.REQUEST")] | length == 0' "$internal" >/dev/null
yq -e '[.destinations[].address | select(. == "OLD.REQUEST")] | length == 0' "$internal" >/dev/null
yq -e '[.destinations[].address | select(. == "APP.EVENTS")] | length == 1' "$internal" >/dev/null
yq -e '.authorization.rules | length == 0' "$internal" >/dev/null
yq -e '. | has("authentication") | not' "$internal" >/dev/null
yq -e '.acceptors."partner-ssl".sslEnabled == true and .acceptors."partner-ssl".needClientAuth == true' "$external" >/dev/null
yq -e '.acceptors."partner-ssl".sslSecret == "sample-broker-tls" and .acceptors."partner-ssl".trustSecret == "sample-client-ca"' "$external" >/dev/null
yq -e '
  .acceptors.amqp.enabled == false and
  .acceptors.stomp.enabled == false and
  .acceptors.mqtt.enabled == false and
  .acceptors.websocket.enabled == false
' "$external" >/dev/null
yq -e '.authentication.jaasSecretName == "sample-clients-jaas-config"' "$external" >/dev/null
yq -e '[.authorization.rules[].match | select(. == "PARTNER.REQUEST")] | length == 1' "$external" >/dev/null
yq -e '[.authorization.rules[].match | select(. == "OLD.#")] | length == 0' "$external" >/dev/null

if rg -q 'fixture-database-password|CN=fixture-client|fixture-ca-alias|guests' "$internal" "$external"; then
  printf '%s\n' 'candidate leaked a secret, certificate identity, alias, or dropped role' >&2
  exit 1
fi
if jq -e '.. | strings | select(contains("fixture-database-password") or contains("CN=fixture-client") or contains("fixture-ca-alias"))' "$report" >/dev/null; then
  printf '%s\n' 'redacted report leaked a source value' >&2
  exit 1
fi
jq -e '
  .status == "REVIEW_REQUIRED" and
  .secretValuesEmitted == false and
  .sensitiveSourceInventory.paths == ["override_attributes.activemq.brokers.sample-internal.dbPassword"] and
  ([.items[] | select(.disposition == "retired")] | length) >= 3 and
  ([.items[] | select(.disposition == "manual")] | length) >= 3 and
  ([.items[] | select(.disposition == "policy-excluded")] | length) == 3
' "$report" >/dev/null

helm_args=(
  --set 'ha.coordinationId=pair-id-test01'
  --set-string 'zookeeper.connectString=zookeeper-0.zookeeper-headless:2181\,zookeeper-1.zookeeper-headless:2181\,zookeeper-2.zookeeper-headless:2181'
)
helm template chef-import "$chart" "${helm_args[@]}" -f "$internal" >/dev/null
helm template chef-import "$chart" "${helm_args[@]}" -f "$external" \
  --set-string 'workloadCell.trafficClass=external' \
  --set 'workloadCell.enabled=true' \
  >/dev/null

second="$temp_dir/second"
python3 -B "$script" \
  --input "$fixture" \
  --output-dir "$second" \
  --policy "$policy" \
  --ssl-secret-name sample-broker-tls \
  --trust-secret-name sample-client-ca \
  --authenticated-broker sample-external \
  --jaas-secret-name sample-clients-jaas-config >/dev/null
cmp -s "$internal" "$second/sample-internal.artemis-values.candidate.yaml"
cmp -s "$external" "$second/sample-external.artemis-values.candidate.yaml"

missing_secret="$temp_dir/missing-secret"
python3 -B "$script" \
  --input "$fixture" \
  --output-dir "$missing_secret" \
  --broker sample-external >/dev/null
yq -e '. | has("acceptors") | not' "$missing_secret/sample-external.artemis-values.candidate.yaml" >/dev/null
jq -e '[.items[] | select(.disposition == "manual" and (.reason | contains("--ssl-secret-name")))] | length == 1' \
  "$missing_secret/migration-report.json" >/dev/null

if python3 -B "$script" --input "$fixture" --output-dir "$output" >/dev/null 2>&1; then
  printf '%s\n' 'expected non-empty output protection to fail without --force' >&2
  exit 1
fi
python3 -B "$script" \
  --input "$fixture" \
  --output-dir "$output" \
  --broker sample-internal \
  --policy "$policy" \
  --force >/dev/null
[[ -f "$output/sample-internal.artemis-values.candidate.yaml" ]]
[[ ! -e "$output/sample-external.artemis-values.candidate.yaml" ]]

printf '%s\n' 'Chef ActiveMQ import tests passed'
