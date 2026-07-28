#!/usr/bin/env bash
set -euo pipefail

chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-ha-tests.XXXXXX")
rendered="$temp_dir/default.yaml"
autocreate_rendered="$temp_dir/autocreate.yaml"
expiry_rendered="$temp_dir/expiry.yaml"
ports_rendered="$temp_dir/ports.yaml"
trap 'rm -rf "$temp_dir"' EXIT

helm_args=(
  --set 'ha.coordinationId=pair-id-test01'
  --set-string 'zookeeper.connectString=zookeeper-0.zookeeper-headless:2181\,zookeeper-1.zookeeper-headless:2181\,zookeeper-2.zookeeper-headless:2181'
)

helm lint "$chart_dir" "${helm_args[@]}" >/dev/null

if helm template invalid "$chart_dir" \
  --set 'ha.coordinationId=' \
  --set 'zookeeper.connectString=' >/dev/null 2>&1; then
  echo "expected missing HA identity and ZooKeeper connection to fail" >&2
  exit 1
fi

removed_values=(
  'operator.version=2.2.0'
  'replicas=2'
  'ha.mode=competing-primary'
  'ha.automaticFailback=false'
  'zookeeper.enabled=true'
  'persistence.enabled=true'
  'broker.requireLogin=true'
  'console.enabled=true'
  'console.port=8161'
  'services.type=ClusterIP'
  'services.publishNotReadyAddresses=false'
)
for removed_value in "${removed_values[@]}"; do
  if helm template invalid "$chart_dir" --set "$removed_value" >/dev/null 2>&1; then
    echo "expected removed value to be rejected: $removed_value" >&2
    exit 1
  fi
done

helm template artemis "$chart_dir" --namespace example-messaging "${helm_args[@]}" > "$rendered"

rg -q '^kind: ActiveMQArtemis$' "$rendered"
rg -q 'HAPolicyConfiguration=REPLICATION_PRIMARY_LOCK_MANAGER' "$rendered"
rg -q 'HAPolicyConfiguration\.coordinationId=pair-id-test01' "$rendered"
rg -q 'HAPolicyConfiguration\.distributedManagerConfiguration\.properties\.namespace=artemis/example/example-pair' "$rendered"
rg -q 'addressSettings\.#\.maxDeliveryAttempts=1' "$rendered"
rg -q 'addressSettings\.#\.redeliveryDelay=0' "$rendered"
rg -q 'addressSettings\.#\.deadLetterAddress=DLA' "$rendered"
rg -q 'addressSettings\.#\.autoCreateDeadLetterResources=true' "$rendered"
rg -q 'addressSettings\.#\.deadLetterQueuePrefix=DLQ\.' "$rendered"
rg -q 'addressSettings\.#\.deadLetterQueueSuffix=' "$rendered"
rg -q 'addressSettings\.#\.autoDeleteQueues=false' "$rendered"
rg -q 'addressSettings\.#\.autoDeleteAddresses=false' "$rendered"
rg -q 'addressSettings\.#\.autoCreateQueues=false' "$rendered"
rg -q 'addressSettings\.#\.autoCreateAddresses=false' "$rendered"
if rg -q 'addressSettings\.#\.(expiryAddress|autoCreateExpiryResources|expiryQueuePrefix|expiryQueueSuffix)=' "$rendered"; then
  echo "message-expiry properties rendered while expiry is disabled" >&2
  exit 1
fi
rg -q 'console/jolokia/read/org\.apache\.activemq\.artemis:broker=%22\$\{APPLICATION_NAME\}%22/Active' "$rendered"
rg -q 'vault.hashicorp.com/agent-pre-populate-only: "true"' "$rendered"
rg -q -- '-Dhawtio\.oidcConfig=/amq/extra/configmaps/artemis-artemis-ha-hawtio-oidc/hawtio-oidc\.properties' "$rendered"
rg -q 'code_challenge_method = S256' "$rendered"
rg -q 'provider = https://keycloak.example.invalid/realms/example' "$rendered"
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
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.size' "$rendered")" == "2" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.requireLogin' "$rendered")" == "true" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.persistenceEnabled' "$rendered")" == "true" ]]
[[ "$(yq eval 'select(.kind == "Service" and .metadata.name == "artemis-artemis-ha-console") | .spec.ports[0].port' "$rendered")" == "8161" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.startupProbe.tcpSocket.port' "$rendered")" == "8161" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.livenessProbe.tcpSocket.port' "$rendered")" == "8161" ]]

helm template artemis-ports "$chart_dir" --namespace example-messaging \
  "${helm_args[@]}" \
  --set 'acceptors.amqp.port=25672' \
  --set 'acceptors.openwire.enabled=false' \
  --set 'networkPolicy.clientSources[0].namespaceSelector.matchLabels.test=client' \
  --set 'networkPolicy.clientSources[0].podSelector.matchLabels.test=client' \
  > "$ports_rendered"

[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.acceptors[] | select(.name == "amqp") | .port' "$ports_rendered")" == "25672" ]]
[[ "$(yq eval 'select(.kind == "Service" and .metadata.name == "artemis-ports-artemis-ha-amqp") | .spec.ports[0].port' "$ports_rendered")" == "25672" ]]
client_ports=$(
  yq eval 'select(.kind == "NetworkPolicy" and .metadata.name == "artemis-ports-artemis-ha-allow") | .spec.ingress[] | select(.from[0].namespaceSelector.matchLabels.test == "client") | .ports[].port' "$ports_rendered" |
    sort -n |
    paste -sd, -
)
[[ "$client_ports" == "1883,25672,61613,61614" ]]
[[ "$(yq eval 'select(.kind == "NetworkPolicy" and .metadata.name == "artemis-ports-artemis-ha-allow") | .spec.ingress[] | select(.from[0].podSelector.matchLabels.application == "artemis-ports-artemis-ha-app") | .ports[].port' "$ports_rendered")" == "61616" ]]
if rg -q 'name: artemis-ports-artemis-ha-openwire' "$ports_rendered"; then
  echo "disabled OpenWire acceptor still rendered a client Service" >&2
  exit 1
fi

helm template artemis-autocreate "$chart_dir" --namespace example-messaging \
  "${helm_args[@]}" \
  --set 'brokerProperties.addressSettings.autoCreateQueues=true' \
  --set 'brokerProperties.addressSettings.autoCreateAddresses=true' \
  > "$autocreate_rendered"
rg -q 'addressSettings\.#\.autoCreateQueues=true' "$autocreate_rendered"
rg -q 'addressSettings\.#\.autoCreateAddresses=true' "$autocreate_rendered"
rg -q 'addressSettings\.#\.autoCreateDeadLetterResources=true' "$autocreate_rendered"

helm template artemis-expiry "$chart_dir" --namespace example-messaging \
  "${helm_args[@]}" \
  --set 'brokerProperties.addressSettings.expiry.enabled=true' \
  > "$expiry_rendered"
rg -q 'addressSettings\.#\.expiryAddress=ExpiryQueue' "$expiry_rendered"
rg -q 'addressSettings\.#\.autoCreateExpiryResources=true' "$expiry_rendered"
rg -q 'addressSettings\.#\.expiryQueuePrefix=EXP\.' "$expiry_rendered"
rg -q 'addressSettings\.#\.expiryQueueSuffix=' "$expiry_rendered"

if rg -n -i '^[[:space:]]*(password|token):[[:space:]]+[^<{]' "$rendered"; then
  echo "rendered output contains a literal credential-like value" >&2
  exit 1
fi

kubeconform -strict -ignore-missing-schemas -summary "$rendered" >/dev/null
echo "artemis-ha focused chart tests passed"
