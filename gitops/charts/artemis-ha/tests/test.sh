#!/usr/bin/env bash
set -euo pipefail

chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gitops_dir=$(CDPATH= cd -- "$chart_dir/../.." && pwd)
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-ha-tests.XXXXXX")
rendered="$temp_dir/default.yaml"
autocreate_rendered="$temp_dir/autocreate.yaml"
expiry_rendered="$temp_dir/expiry.yaml"
ports_rendered="$temp_dir/ports.yaml"
vault_rendered="$temp_dir/vault.yaml"
external_rendered="$temp_dir/external.yaml"
prod_rendered="$temp_dir/prod.yaml"
nonprod_rendered="$temp_dir/nonprod.yaml"
test_rendered="$temp_dir/test.yaml"
trap 'rm -rf "$temp_dir"' EXIT
schema_mode=${ARTEMIS_SCHEMA_MODE:-offline}
schema_args=(--mode "$schema_mode" --quiet-offline)
if [[ -n "${ARTEMIS_KUBERNETES_VERSION:-}" ]]; then
  schema_args+=(--kubernetes-version "$ARTEMIS_KUBERNETES_VERSION")
fi

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
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set-string 'commonLabels.contact=test@uscis.dhs.gov' >/dev/null 2>&1; then
  echo "expected an email address used as a label value to fail" >&2
  exit 1
fi
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set-string 'broker.adminUser=' >/dev/null 2>&1; then
  echo "expected an empty broker administrator username to fail" >&2
  exit 1
fi
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set 'acceptors.artemis.sslEnabled=true' >/dev/null 2>&1; then
  echo "expected a TLS acceptor without sslSecret to fail" >&2
  exit 1
fi
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set 'acceptors.artemis.needClientAuth=true' >/dev/null 2>&1; then
  echo "expected client certificate authentication without TLS to fail" >&2
  exit 1
fi
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set 'acceptors.artemis.protocols=OPENWIRE' >/dev/null 2>&1; then
  echo "expected removal of CORE from the operator peer acceptor to fail" >&2
  exit 1
fi
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set 'acceptors.amqp.port=61616' >/dev/null 2>&1; then
  echo "expected duplicate enabled acceptor ports to fail" >&2
  exit 1
fi
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set 'acceptors.amqp.supportAdvisory=true' >/dev/null 2>&1; then
  echo "expected OpenWire advisories on a non-OpenWire acceptor to fail" >&2
  exit 1
fi
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set-string 'authentication.jaasSecretName=invalid-secret-name' >/dev/null 2>&1; then
  echo "expected a JAAS Secret name without the operator suffix to fail" >&2
  exit 1
fi
if helm template invalid "$chart_dir" "${helm_args[@]}" \
  --set-string 'destinations.invalid.address=INVALID.ROUTING' \
  --set-string 'destinations.invalid.routingTypes[0]=ANYCAST' \
  --set-string 'destinations.invalid.queues[0].name=INVALID.ROUTING' \
  --set-string 'destinations.invalid.queues[0].routingType=MULTICAST' \
  --set 'destinations.invalid.queues[0].durable=true' \
  --set 'destinations.invalid.queues[0].maxConsumers=-1' \
  --set 'destinations.invalid.queues[0].purgeOnNoConsumers=false' >/dev/null 2>&1; then
  echo "expected a queue routing type absent from its address to fail" >&2
  exit 1
fi

removed_values=(
  'operator.version=2.2.0'
  'replicas=2'
  'ha.mode=competing-primary'
  'ha.automaticFailback=false'
  'ha.clusterName=my-cluster'
  'zookeeper.enabled=true'
  'persistence.enabled=true'
  'broker.requireLogin=true'
  'broker.terminationGracePeriodSeconds=120'
  'console.enabled=true'
  'console.port=8161'
  'console.ingress.tlsSecretName=obsolete-secret'
  'services.type=ClusterIP'
  'services.publishNotReadyAddresses=false'
)
for removed_value in "${removed_values[@]}"; do
  if helm template invalid "$chart_dir" --set "$removed_value" >/dev/null 2>&1; then
    echo "expected removed value to be rejected: $removed_value" >&2
    exit 1
  fi
done

for protected_override in \
  'journalSyncTransactional=false' \
  'journal-sync-non-transactional=false' \
  'persistIDCache=false' \
  'addressConfigurations.UNREVIEWED.routingTypes=ANYCAST' \
  'securityRoles.#.unreviewed.send=true' \
  'HAPolicyConfiguration.coordinationId=unsafe'; do
  if helm template invalid "$chart_dir" "${helm_args[@]}" \
    --set-string "brokerProperties.extra[0]=$protected_override" >/dev/null 2>&1; then
    echo "expected protected broker property override to fail: $protected_override" >&2
    exit 1
  fi
done

helm template artemis "$chart_dir" --namespace example-messaging "${helm_args[@]}" > "$rendered"

rg -q '^kind: ActiveMQArtemis$' "$rendered"
[[ "$(rg -c '^kind: ActiveMQArtemis$' "$rendered")" == "1" ]]

# Argo CD identifies resources by group/kind/namespace/name and rejects a
# render that repeats an identity, even when the duplicate uses another API
# version. Check the complete chart output using the release namespace Argo CD
# applies to resources without an explicit metadata.namespace.
duplicate_resource_identities=$(
  RELEASE_NAMESPACE=example-messaging yq eval -r '
    select(.kind != null and .metadata.name != null)
    | [(.apiVersion | split("/")[0]), .kind, (.metadata.namespace // strenv(RELEASE_NAMESPACE)), .metadata.name]
    | @tsv
  ' "$rendered" | sort | uniq -d
)
if [[ -n "$duplicate_resource_identities" ]]; then
  printf 'chart rendered duplicate Argo CD resource identities:\n%s\n' \
    "$duplicate_resource_identities" >&2
  exit 1
fi
for required_label in app contact env fismaid; do
  yq -e "select(.kind == \"ActiveMQArtemis\") | .metadata.labels.\"$required_label\" != null" \
    "$rendered" >/dev/null
  yq -e "select(.kind == \"ActiveMQArtemis\") | .spec.deploymentPlan.labels.\"$required_label\" != null" \
    "$rendered" >/dev/null
  yq -e "select(.kind == \"ActiveMQArtemis\") | .spec.resourceTemplates[0].labels.\"$required_label\" != null" \
    "$rendered" >/dev/null
done
yq -e 'select(.kind == "ActiveMQArtemis") |
  (.spec.resourceTemplates | length) == 1 and
  (.spec.resourceTemplates[0] | has("selector") | not)' \
  "$rendered" >/dev/null
rg -q 'HAPolicyConfiguration=REPLICATION_PRIMARY_LOCK_MANAGER' "$rendered"
rg -q 'HAPolicyConfiguration\.coordinationId=pair-id-test01' "$rendered"
rg -q 'HAPolicyConfiguration\.distributedManagerConfiguration\.properties\.namespace=artemis/example/example-pair' "$rendered"
rg -q 'journalSyncTransactional=true' "$rendered"
rg -q 'journalSyncNonTransactional=true' "$rendered"
rg -q 'journalDatasync=true' "$rendered"
rg -q 'largeMessageSync=true' "$rendered"
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
rg -q 'console/jolokia/read/org\.apache\.activemq\.artemis:broker=\*/Active' "$rendered"
rg -Fq 'Origin: http://localhost' "$rendered"
rg -Fq "| grep -Eq '\"Active\"[[:space:]]*:[[:space:]]*true'" "$rendered"
if rg -q 'console/jolokia/read/.*APPLICATION_NAME' "$rendered"; then
  echo "readiness probe must not assume the broker MBean name equals APPLICATION_NAME" >&2
  exit 1
fi
active_pattern_response='{"value":{"org.apache.activemq.artemis:broker=\"amq-broker\"":{"Active":true}},"status":200}'
passive_pattern_response='{"value":{"org.apache.activemq.artemis:broker=\"amq-broker\"":{"Active":false}},"status":200}'
printf '%s\n' "$active_pattern_response" | grep -Eq '"Active"[[:space:]]*:[[:space:]]*true'
if printf '%s\n' "$passive_pattern_response" | grep -Eq '"Active"[[:space:]]*:[[:space:]]*true'; then
  echo "readiness response check accepted a passive broker" >&2
  exit 1
fi
if rg -q 'vault.hashicorp.com/' "$rendered"; then
  echo "default chart unexpectedly enabled the incomplete Vault integration" >&2
  exit 1
fi
rg -q -- '-Dhawtio\.oidcConfig=/amq/extra/configmaps/artemis-artemis-ha-hawtio-oidc/hawtio-oidc\.properties' "$rendered"
rg -q -- '-Dzookeeper\.sasl\.client=false' "$rendered"
rg -q 'code_challenge_method = S256' "$rendered"
rg -q 'provider = https://keycloak.example.invalid/realms/example' "$rendered"
rg -q 'readOnlyRootFilesystem: true' "$rendered"
rg -q 'name: artemis-artemis-ha-artemis' "$rendered"
rg -q 'name: artemis-artemis-ha-amqp' "$rendered"
rg -q 'name: artemis-artemis-ha-stomp' "$rendered"
rg -q 'name: artemis-artemis-ha-mqtt' "$rendered"
rg -q 'name: artemis-artemis-ha-websocket' "$rendered"
rg -q 'name: artemis-artemis-ha-metrics' "$rendered"
rg -q 'kind: Ingress' "$rendered"
rg -q 'kind: NetworkPolicy' "$rendered"
rg -q 'kind: ServiceMonitor' "$rendered"
rg -q 'kind: PrometheusRule' "$rendered"
if rg -q 'ingress-nginx' "$rendered"; then
  echo "ALB configuration unexpectedly rendered the obsolete ingress-nginx NetworkPolicy source" >&2
  exit 1
fi
[[ "$(yq eval -r 'select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.alert == "ArtemisBrokerMetricsUnavailable") | .expr' "$rendered")" == 'absent(up{namespace="example-messaging",service="artemis-artemis-ha-metrics"})' ]]
[[ "$(yq eval -r 'select(.kind == "Ingress") | .spec.ingressClassName' "$rendered")" == "aws-lb-ingress" ]]
[[ "$(yq eval -r 'select(.kind == "Ingress") | .metadata.annotations."alb.ingress.kubernetes.io/group.name"' "$rendered")" == "shared-standard-group" ]]
[[ "$(yq eval -r 'select(.kind == "Ingress") | .metadata.annotations."alb.ingress.kubernetes.io/group.order"' "$rendered")" == "100" ]]
[[ "$(yq eval -r 'select(.kind == "Ingress") | .metadata.annotations."alb.ingress.kubernetes.io/listen-ports"' "$rendered")" == '[{"HTTP":80},{"HTTPS":443}]' ]]
[[ "$(yq eval -r 'select(.kind == "Ingress") | .metadata.annotations."alb.ingress.kubernetes.io/target-type"' "$rendered")" == "ip" ]]
[[ "$(yq eval -r 'select(.kind == "Ingress") | .spec | has("tls")' "$rendered")" == "false" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.size' "$rendered")" == "2" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.requireLogin' "$rendered")" == "true" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.persistenceEnabled' "$rendered")" == "true" ]]
[[ "$(yq eval -r 'select(.kind == "ActiveMQArtemis") | .spec.adminUser' "$rendered")" == "PLACEHOLDER_ARTEMIS_ADMIN_USERNAME" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec | has("adminPassword")' "$rendered")" == "false" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan | has("image") or has("initImage")' "$rendered")" == "false" ]]
[[ "$(yq eval 'select(.kind == "Service" and .metadata.name == "artemis-artemis-ha-console") | .spec.ports[0].port' "$rendered")" == "8161" ]]
[[ "$(yq eval 'select(.kind == "Service" and .metadata.name == "artemis-artemis-ha-metrics") | .spec.publishNotReadyAddresses' "$rendered")" == "true" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.startupProbe.tcpSocket.port' "$rendered")" == "8161" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.livenessProbe.tcpSocket.port' "$rendered")" == "8161" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.topologySpreadConstraints[] | select(.topologyKey == "topology.kubernetes.io/zone") | .minDomains' "$rendered")" == "2" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[] | select(.topologyKey == "topology.kubernetes.io/zone") | .labelSelector.matchLabels.ActiveMQArtemis' "$rendered")" == "artemis-artemis-ha" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.storage.storageClassName' "$rendered")" == "gp3" ]]
if rg -q '^kind: StorageClass$' "$rendered"; then
  echo "default chart unexpectedly rendered a StorageClass" >&2
  exit 1
fi

for environment in prod nonprod test; do
  environment_rendered="$temp_dir/$environment.yaml"
  helm template "artemis-$environment" "$chart_dir" --namespace example-messaging \
    "${helm_args[@]}" \
    -f "$chart_dir/../../environments/$environment/artemis-values.yaml" \
    > "$environment_rendered"
done

for environment_rendered in "$prod_rendered" "$nonprod_rendered" "$test_rendered"; do
  [[ "$(yq eval -r 'select(.kind == "ActiveMQArtemis") | .spec.adminUser' "$environment_rendered")" == "PLACEHOLDER_ARTEMIS_ADMIN_USERNAME" ]]
  if rg -q '^kind: StorageClass$' "$environment_rendered"; then
    echo "Artemis chart unexpectedly rendered a platform-owned StorageClass: $environment_rendered" >&2
    exit 1
  fi
done

custom_admin_rendered="$temp_dir/custom-admin.yaml"
helm template artemis-custom-admin "$chart_dir" --namespace example-messaging \
  "${helm_args[@]}" \
  --set-string 'broker.adminUser=admin' \
  > "$custom_admin_rendered"
[[ "$(yq eval -r 'select(.kind == "ActiveMQArtemis") | .spec.adminUser' "$custom_admin_rendered")" == "admin" ]]
for environment in prod nonprod test; do
  environment_rendered="$temp_dir/$environment.yaml"
  yq -e "select(.kind == \"ActiveMQArtemis\") |
    (.metadata.labels.env == \"$environment\") and
    (.spec.deploymentPlan.labels.env == \"$environment\") and
    (.spec.resourceTemplates[0].labels.env == \"$environment\")" \
    "$environment_rendered" >/dev/null
  yq -e 'select(.kind == "ActiveMQArtemis") |
    (.spec.deploymentPlan.tolerations | length) == 1 and
    .spec.deploymentPlan.tolerations[0].key == "eid-platform/node-lifecycle" and
    .spec.deploymentPlan.tolerations[0].operator == "Equal" and
    .spec.deploymentPlan.tolerations[0].value == "ondemand" and
    .spec.deploymentPlan.tolerations[0].effect == "NoSchedule"' \
    "$environment_rendered" >/dev/null
done
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.storage.storageClassName' "$prod_rendered")" == "PLACEHOLDER_PROD_GP3_STORAGE_CLASS" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.storage.storageClassName' "$nonprod_rendered")" == "PLACEHOLDER_NONPROD_GP3_STORAGE_CLASS" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.storage.storageClassName' "$test_rendered")" == "PLACEHOLDER_TEST_GP3_STORAGE_CLASS" ]]
for environment_rendered in "$prod_rendered" "$nonprod_rendered" "$test_rendered"; do
  [[ "$(yq eval -r 'select(.kind == "Ingress") | .spec.ingressClassName' "$environment_rendered")" == "aws-lb-ingress" ]]
  [[ "$(yq eval -r 'select(.kind == "Ingress") | .metadata.annotations."alb.ingress.kubernetes.io/group.name"' "$environment_rendered")" == "shared-standard-group" ]]
  [[ "$(yq eval -r 'select(.kind == "Ingress") | .metadata.annotations."alb.ingress.kubernetes.io/target-type"' "$environment_rendered")" == "ip" ]]
done

helm template artemis-ports "$chart_dir" --namespace example-messaging \
  "${helm_args[@]}" \
  --set 'acceptors.amqp.port=25672' \
  --set 'acceptors.stomp.enabled=false' \
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
[[ "$client_ports" == "1883,61614,61616,25672" ]]
[[ "$(yq eval 'select(.kind == "NetworkPolicy" and .metadata.name == "artemis-ports-artemis-ha-allow") | .spec.ingress[] | select(.from[0].podSelector.matchLabels.application == "artemis-ports-artemis-ha-app") | .ports[].port' "$ports_rendered")" == "61616" ]]
if rg -q 'name: artemis-ports-artemis-ha-stomp' "$ports_rendered"; then
  echo "disabled STOMP acceptor still rendered a client Service" >&2
  exit 1
fi

helm template artemis-external "$chart_dir" --namespace example-messaging \
  "${helm_args[@]}" \
  -f "$chart_dir/tests/fixtures/external-mtls-values.yaml" \
  > "$external_rendered"
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.acceptors[] | select(.name == "partner-openwire") | .port' "$external_rendered")" == "61617" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.acceptors[] | select(.name == "partner-openwire") | .sslEnabled' "$external_rendered")" == "true" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.acceptors[] | select(.name == "partner-openwire") | .needClientAuth' "$external_rendered")" == "true" ]]
[[ "$(yq eval -r 'select(.kind == "ActiveMQArtemis") | .spec.acceptors[] | select(.name == "partner-openwire") | .sslSecret' "$external_rendered")" == "partner-broker-tls" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.acceptors[] | select(.name == "partner-openwire") | .supportAdvisory' "$external_rendered")" == "true" ]]
[[ "$(yq eval 'select(.kind == "ActiveMQArtemis") | .spec.acceptors[] | select(.name == "partner-stomp") | .port' "$external_rendered")" == "61612" ]]
[[ "$(yq eval -r 'select(.kind == "ActiveMQArtemis") | .spec.deploymentPlan.extraMounts.secrets[0]' "$external_rendered")" == "partner-clients-jaas-config" ]]
rg -Fq 'addressConfigurations."PARTNER.REQUEST".queueConfigs."PARTNER.REQUEST".durable=true' "$external_rendered"
rg -Fq 'addressConfigurations."PARTNER.RESPONSE".queueConfigs."PARTNER.RESPONSE".maxConsumers=20' "$external_rendered"
rg -Fq 'securityRoles."PARTNER.REQUEST".partner-client.send=true' "$external_rendered"
rg -Fq 'securityRoles."PARTNER.RESPONSE\:\:PARTNER.RESPONSE".partner-client.consume=true' "$external_rendered"
rg -Fq 'securityRoles."ActiveMQ.Advisory.#".partner-client.consume=true' "$external_rendered"
rg -Fq 'securityRoles."mops.#".messaging-viewer.view=true' "$external_rendered"
rg -Fq 'securityRoles."PARTNER.#".messaging-admin.createDurableQueue=true' "$external_rendered"
rg -Fq 'acceptorConfigurations.partner-openwire.extraParams.openWireDestinationCacheSize=1024' "$external_rendered"

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

helm template artemis-vault "$chart_dir" --namespace example-messaging \
  "${helm_args[@]}" \
  --set 'vault.enabled=true' \
  > "$vault_rendered"
rg -q 'vault.hashicorp.com/agent-pre-populate-only: "true"' "$vault_rendered"
rg -q 'vault.hashicorp.com/agent-inject-secret-broker-credentials: kubernetes/example/example-messaging' "$vault_rendered"

if rg -n -i '^[[:space:]]*(password|token):[[:space:]]+[^<{]' "$rendered"; then
  echo "rendered output contains a literal credential-like value" >&2
  exit 1
fi

"$gitops_dir/scripts/validate-rendered-schema.sh" "${schema_args[@]}" "$rendered" "$prod_rendered" >/dev/null
if [[ "$schema_mode" == offline ]]; then
  echo "artemis-ha focused chart tests passed (Kubernetes schema: NOT_RUN/offline)"
else
  echo "artemis-ha focused chart tests passed (Kubernetes schema: PASS/network)"
fi
