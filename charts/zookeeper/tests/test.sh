#!/usr/bin/env bash
set -euo pipefail

chart_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repository_dir=$(CDPATH= cd -- "$chart_dir/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zookeeper-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

helm lint "$chart_dir" >/dev/null
if helm template invalid "$chart_dir" --set replicaCount=2 >/dev/null 2>&1; then
  printf '%s\n' 'expected a two-member quorum to fail' >&2
  exit 1
fi
if helm template invalid "$chart_dir" --set enabled=false >/dev/null 2>&1; then
  printf '%s\n' 'expected the removed disabled-chart composition to fail' >&2
  exit 1
fi
for unsafe_override in \
  persistence.enabled=false \
  podDisruptionBudget.enabled=false \
  networkPolicy.enabled=false \
  metrics.enabled=false; do
  if helm template invalid "$chart_dir" --set "$unsafe_override" >/dev/null 2>&1; then
    printf 'expected unsafe override to fail: %s\n' "$unsafe_override" >&2
    exit 1
  fi
done
if helm template invalid "$chart_dir" \
  --set tls.client.enabled=true \
  --set tls.client.secretName= >/dev/null 2>&1; then
  printf '%s\n' 'expected client TLS without a Secret name to fail' >&2
  exit 1
fi

rendered="$work_dir/default.yaml"
helm template zookeeper "$chart_dir" --namespace example-platform > "$rendered"
rg -q '^kind: StatefulSet$' "$rendered"
rg -q 'replicas: 3' "$rendered"
rg -q 'server\.1=zookeeper-zookeeper-0\.zookeeper-zookeeper-headless' "$rendered"
rg -q 'server\.3=zookeeper-zookeeper-2\.zookeeper-zookeeper-headless' "$rendered"
rg -q 'standaloneEnabled=false' "$rendered"
rg -q '/data/data/myid' "$rendered"
rg -q 'key: ActiveMQArtemis' "$rendered"
rg -q 'operator: Exists' "$rendered"
rg -q 'maxUnavailable: 1' "$rendered"
rg -q 'topologyKey: "topology.kubernetes.io/zone"' "$rendered"
kubeconform -strict -ignore-missing-schemas -summary "$rendered" >/dev/null

for environment in test nonprod prod; do
  values="$repository_dir/environments/$environment/zookeeper-values.yaml"
  environment_rendered="$work_dir/$environment.yaml"
  helm lint "$chart_dir" --values "$values" >/dev/null
  helm template "$environment-zookeeper" "$chart_dir" \
    --namespace example-platform \
    --values "$values" > "$environment_rendered"
  rg -q 'replicas: 3' "$environment_rendered"
  rg -q 'volumeClaimTemplates:' "$environment_rendered"
  rg -q 'storageClassName: "PLACEHOLDER_.*_GP3_STORAGE_CLASS"' "$environment_rendered"
  rg -q 'kind: NetworkPolicy' "$environment_rendered"
  rg -q 'kind: ServiceMonitor' "$environment_rendered"
  rg -q 'kind: PrometheusRule' "$environment_rendered"
  rg -q '@sha256:[0-9a-f]{64}' "$environment_rendered"
  kubeconform -strict -ignore-missing-schemas -summary "$environment_rendered" >/dev/null
done

printf '%s\n' 'zookeeper focused chart tests passed'
