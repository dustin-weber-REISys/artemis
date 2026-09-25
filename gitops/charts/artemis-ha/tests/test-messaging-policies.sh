#!/usr/bin/env bash
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gitops_dir=$(cd "$chart_dir/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
args=(--set ha.coordinationId=policy-test01 --set zookeeper.connectString=example:2181
  -f "$gitops_dir/argocd/profiles/application-messaging/values.yaml")
example="$gitops_dir/workloads/test/test-sky2/artemis-values.yaml"
helm template policies "$chart_dir" "${args[@]}" -f "$example" > "$tmp/render.yaml"
for property in \
  'addressSettings."EXAMPLE.ORDERS".maxDeliveryAttempts=8' \
  'addressSettings."EXAMPLE.ORDERS".redeliveryDelay=10000' \
  'addressSettings."EXAMPLE.ORDERS".expiryDelay=-1' \
  'addressSettings."EXAMPLE.NOTIFICATIONS".maxDeliveryAttempts=3' \
  'addressSettings."EXAMPLE.NOTIFICATIONS".expiryDelay=60000' \
  'addressSettings."EXAMPLE.ORDERS".autoDeleteQueues=false' \
  'addressSettings."EXAMPLE.ORDERS".autoCreateQueues=false' \
  'addressSettings."EXAMPLE.ORDERS".autoCreateDeadLetterResources=true' \
  'addressSettings."EXAMPLE.NOTIFICATIONS".autoCreateExpiryResources=true' \
  'addressSettings.#.maxDeliveryAttempts=1'; do
  grep -Fq -- "$property" "$tmp/render.yaml"
done
# Removing a local override restores the selected policy default.
yq 'del(.destinations.example-orders.policyOverrides)' "$example" > "$tmp/default.yaml"
helm template policies "$chart_dir" "${args[@]}" -f "$tmp/default.yaml" > "$tmp/default-render.yaml"
grep -Fq 'addressSettings."EXAMPLE.ORDERS".maxDeliveryAttempts=5' "$tmp/default-render.yaml"
reject() {
  local expression=$1 expected=$2
  yq "$expression" "$example" > "$tmp/invalid.yaml"
  if helm template policies "$chart_dir" "${args[@]}" -f "$tmp/invalid.yaml" > "$tmp/error" 2>&1; then
    echo "accepted invalid messaging policy: $expression" >&2; exit 1
  fi
  grep -Fq "$expected" "$tmp/error"
}
reject '.destinations.example-orders.messagingPolicy = "missing"' 'unknown messagingPolicy'
reject '.destinations.example-orders.policyOverrides.expiryDelay = 10000' 'does not permit override expiryDelay'
reject 'del(.destinations.example-orders.messagingPolicy)' 'policyOverrides requires messagingPolicy'
reject '.destinations.example-orders.policyOverrides.maxDeliveryAttempts = -1' 'minimum'
reject '.destinations.example-orders.policyOverrides.maxDeliveryAttempts = 21' 'maximum'
reject '.destinations.example-orders.policyOverrides.redeliveryDelay = 0' 'minimum'
reject '.destinations.example-notifications.policyOverrides.expiryDelay = 0' 'schema'
reject '.destinations.example-notifications.policyOverrides.expiryDelay = 604800001' 'schema'
reject '.destinations.example-orders.policyOverrides.autoDeleteQueues = true' 'additional properties'
reject '.destinations.example-orders.policyOverrides.deadLetterAddress = "OTHER"' 'additional properties'
reject '.destinations.example-orders.queues[0].durable = false' 'must be durable'
reject '.destinations.example-orders.queues[0].purgeOnNoConsumers = true' 'must be durable'
reject '.destinations.example-orders.address = "APP.DLA"' 'must differ'
reject '.brokerProperties.extra = ["addressSettings.#.maxDeliveryAttempts=-1"]' 'cannot override protected'
echo 'messaging policy rendering and rejection checks: PASS'
