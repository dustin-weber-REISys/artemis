#!/usr/bin/env bash
set -euo pipefail

chart_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repository_dir=$(CDPATH= cd -- "$chart_dir/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zookeeper-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
schema_mode=${ARTEMIS_SCHEMA_MODE:-offline}
schema_args=(--mode "$schema_mode" --quiet-offline)
if [[ -n "${ARTEMIS_KUBERNETES_VERSION:-}" ]]; then
  schema_args+=(--kubernetes-version "$ARTEMIS_KUBERNETES_VERSION")
fi

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required' >&2
  exit 2
}

helm lint "$chart_dir" >/dev/null
if helm template invalid "$chart_dir" --set replicaCount=2 >/dev/null 2>&1; then
  printf '%s\n' 'expected a two-member quorum to fail' >&2
  exit 1
fi
if helm template invalid "$chart_dir" --set enabled=false >/dev/null 2>&1; then
  printf '%s\n' 'expected the removed disabled-chart composition to fail' >&2
  exit 1
fi
if helm template invalid "$chart_dir" \
  --set-string 'commonLabels.contact=ELISSkynet@uscis.dhs.gov' >/dev/null 2>&1; then
  printf '%s\n' 'expected an email address used as a label value to fail' >&2
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
image_digest=$(yq -r '.image.digest // ""' "$chart_dir/values.yaml")
if [[ ! "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf '%s\n' 'ZooKeeper chart values must define a sha256 image digest' >&2
  exit 1
fi
helm template zookeeper "$chart_dir" --namespace example-platform > "$rendered"
rg -q '^kind: StatefulSet$' "$rendered"
for required_label in app contact env fismaid; do
  yq -e "select(.kind == \"StatefulSet\") | .metadata.labels.\"$required_label\" != null" \
    "$rendered" >/dev/null
  yq -e "select(.kind == \"StatefulSet\") | .spec.template.metadata.labels.\"$required_label\" != null" \
    "$rendered" >/dev/null
done
rg -q 'replicas: 3' "$rendered"
rg -q 'server\.1=zookeeper-zookeeper-0\.zookeeper-zookeeper-headless' "$rendered"
rg -q 'server\.3=zookeeper-zookeeper-2\.zookeeper-zookeeper-headless' "$rendered"
rg -q 'name: wait-for-peer-dns' "$rendered"
rg -q 'peer=zookeeper-zookeeper-0\.zookeeper-zookeeper-headless\.example-platform\.svc\.cluster\.local' "$rendered"
rg -q 'peer=zookeeper-zookeeper-2\.zookeeper-zookeeper-headless\.example-platform\.svc\.cluster\.local' "$rendered"
rg -q 'until getent hosts "\$peer"' "$rendered"
rg -q 'standaloneEnabled=false' "$rendered"
rg -q '/data/data/myid' "$rendered"
yq -e 'select(.kind == "StatefulSet") |
  .spec.template.spec.containers[] |
  select(.name == "zookeeper") |
  .readinessProbe.initialDelaySeconds == 30' "$rendered" >/dev/null
yq -e 'select(.kind == "StatefulSet") |
  .spec.template.spec.containers[] |
  select(.name == "zookeeper") |
  .livenessProbe.initialDelaySeconds == 30' "$rendered" >/dev/null
rg -q 'key: ActiveMQArtemis' "$rendered"
rg -q 'operator: Exists' "$rendered"
rg -q 'maxUnavailable: 1' "$rendered"
rg -q 'minDomains: 3' "$rendered"
rg -q 'topologyKey: "topology.kubernetes.io/zone"' "$rendered"
"$repository_dir/scripts/validate-rendered-schema.sh" "${schema_args[@]}" "$rendered" >/dev/null

scheduling_rendered="$work_dir/scheduling.yaml"
helm template zookeeper "$chart_dir" --namespace example-platform \
  --set-string scheduling.nodeSelector.nodepool=messaging \
  --set-string 'scheduling.tolerations[0].key=dedicated' \
  --set-string 'scheduling.tolerations[0].operator=Equal' \
  --set-string 'scheduling.tolerations[0].value=messaging' \
  --set-string 'scheduling.tolerations[0].effect=NoSchedule' > "$scheduling_rendered"
yq -e 'select(.kind == "StatefulSet") |
  .spec.template.spec.nodeSelector.nodepool == "messaging" and
  .spec.template.spec.tolerations[0].key == "dedicated" and
  .spec.template.spec.tolerations[0].operator == "Equal" and
  .spec.template.spec.tolerations[0].value == "messaging" and
  .spec.template.spec.tolerations[0].effect == "NoSchedule"' \
  "$scheduling_rendered" >/dev/null
"$repository_dir/scripts/validate-rendered-schema.sh" "${schema_args[@]}" "$scheduling_rendered" >/dev/null

for environment in test nonprod prod; do
  values="$repository_dir/environments/$environment/zookeeper-values.yaml"
  ecr_repository=PLACEHOLDER_NONPROD_ECR_REPOSITORY
  if [[ "$environment" == prod ]]; then
    ecr_repository=PLACEHOLDER_PROD_ECR_REPOSITORY
  fi
  environment_rendered="$work_dir/$environment.yaml"
  helm lint "$chart_dir" \
    --set-string "image.repository=$ecr_repository/zookeeper" \
    --values "$values" >/dev/null
  helm template "$environment-zookeeper" "$chart_dir" \
    --namespace example-platform \
    --set-string "image.repository=$ecr_repository/zookeeper" \
    --values "$values" > "$environment_rendered"
  rg -q 'replicas: 3' "$environment_rendered"
  rg -q 'volumeClaimTemplates:' "$environment_rendered"
  rg -q 'storageClassName: "PLACEHOLDER_.*_GP3_STORAGE_CLASS"' "$environment_rendered"
  rg -q 'kind: NetworkPolicy' "$environment_rendered"
  rg -q 'kind: ServiceMonitor' "$environment_rendered"
  rg -q 'kind: PrometheusRule' "$environment_rendered"
  rg -q '@sha256:[0-9a-f]{64}' "$environment_rendered"
  yq -e "select(.kind == \"StatefulSet\") | .metadata.labels.env == \"$environment\"" \
    "$environment_rendered" >/dev/null
  yq -e "select(.kind == \"StatefulSet\") | .spec.template.metadata.labels.env == \"$environment\"" \
    "$environment_rendered" >/dev/null
  expected_zone_domains=3
  if [[ "$environment" == test ]]; then
    expected_zone_domains=2
    yq -e 'select(.kind == "StatefulSet") |
      (.spec.template.spec.tolerations | length) == 1 and
      .spec.template.spec.tolerations[0].key == "eid-platform/node-lifecycle" and
      .spec.template.spec.tolerations[0].operator == "Equal" and
      .spec.template.spec.tolerations[0].value == "ondemand" and
      .spec.template.spec.tolerations[0].effect == "NoSchedule"' \
      "$environment_rendered" >/dev/null
  fi
  yq -e "select(.kind == \"StatefulSet\") |
    .spec.template.spec.topologySpreadConstraints[] |
    select(.topologyKey == \"topology.kubernetes.io/zone\") |
    .minDomains == $expected_zone_domains" \
    "$environment_rendered" >/dev/null
  yq -e 'select(.kind == "StatefulSet") |
    .spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[] |
    select(.topologyKey == "kubernetes.io/hostname")' \
    "$environment_rendered" >/dev/null
  "$repository_dir/scripts/validate-rendered-schema.sh" "${schema_args[@]}" "$environment_rendered" >/dev/null
done

if [[ "$schema_mode" == offline ]]; then
  printf '%s\n' 'zookeeper focused chart tests passed (Kubernetes schema: NOT_RUN/offline)'
else
  printf '%s\n' 'zookeeper focused chart tests passed (Kubernetes schema: PASS/network)'
fi
