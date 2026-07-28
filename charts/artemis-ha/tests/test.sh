#!/usr/bin/env bash
set -euo pipefail

chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rendered=$(mktemp /tmp/artemis-ha-test.XXXXXX.yaml)
trap 'rm -f "$rendered"' EXIT

helm_args=(
  --set 'ha.coordinationId=pair-id-test01'
  --set-string 'zookeeper.connectString=zookeeper-0.zookeeper-headless:2181\,zookeeper-1.zookeeper-headless:2181\,zookeeper-2.zookeeper-headless:2181'
)

helm lint "$chart_dir" "${helm_args[@]}" >/dev/null

if helm template invalid "$chart_dir" >/dev/null 2>&1; then
  echo "expected missing HA identity and ZooKeeper connection to fail" >&2
  exit 1
fi

helm template artemis "$chart_dir" --namespace example-messaging "${helm_args[@]}" > "$rendered"

rg -q '^kind: ActiveMQArtemis$' "$rendered"
rg -q 'HAPolicyConfiguration=REPLICATION_PRIMARY_LOCK_MANAGER' "$rendered"
rg -q 'HAPolicyConfiguration\.coordinationId=pair-id-test01' "$rendered"
rg -q 'console/jolokia/read/org\.apache\.activemq\.artemis:broker=%22\$\{APPLICATION_NAME\}%22/Active' "$rendered"
rg -q 'vault.hashicorp.com/agent-pre-populate-only: "true"' "$rendered"
rg -q 'readOnlyRootFilesystem: true' "$rendered"
rg -q 'name: artemis-artemis-ha-openwire' "$rendered"
rg -q 'name: artemis-artemis-ha-amqp' "$rendered"
rg -q 'name: artemis-artemis-ha-stomp' "$rendered"
rg -q 'name: artemis-artemis-ha-mqtt' "$rendered"
rg -q 'name: artemis-artemis-ha-websocket' "$rendered"
rg -q 'kind: Ingress' "$rendered"
rg -q 'kind: NetworkPolicy' "$rendered"
rg -q 'kind: ServiceMonitor' "$rendered"
rg -q 'kind: PrometheusRule' "$rendered"

if rg -n -i '^[[:space:]]*(password|token):[[:space:]]+[^<{]' "$rendered"; then
  echo "rendered output contains a literal credential-like value" >&2
  exit 1
fi

kubeconform -strict -ignore-missing-schemas -summary "$rendered" >/dev/null
echo "artemis-ha focused chart tests passed"
