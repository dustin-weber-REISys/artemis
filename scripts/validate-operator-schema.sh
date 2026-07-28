#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
operator_manifest_url=${ARKMQ_OPERATOR_MANIFEST_URL:-https://github.com/arkmq-org/arkmq-org-broker-operator/releases/download/v2.2.0/activemq-artemis-operator.yaml}
operator_manifest_sha256=${ARKMQ_OPERATOR_MANIFEST_SHA256:-ae8ce2672e1cb17dc888e249b076c08e5fb4c44f8cc90dcaef067e86bb4b49f3}
operator_chart=${ARKMQ_OPERATOR_CHART:-oci://quay.io/arkmq-org/helm-charts/arkmq-org-broker-operator}
operator_chart_version=${ARKMQ_OPERATOR_CHART_VERSION:-2.2.0}

for command_name in curl helm kubeconform yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-operator-schema.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
manifest="$temp_dir/activemq-artemis-operator.yaml"
schema="$temp_dir/activemqartemis-v1beta1.json"
operator_chart_dir="$temp_dir/arkmq-org-broker-operator"

curl -fsSL "$operator_manifest_url" -o "$manifest"
if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256=$(sha256sum "$manifest" | awk '{print $1}')
else
  actual_sha256=$(shasum -a 256 "$manifest" | awk '{print $1}')
fi
if [[ "$actual_sha256" != "$operator_manifest_sha256" ]]; then
  printf 'ArkMQ manifest checksum mismatch: expected %s, got %s\n' \
    "$operator_manifest_sha256" "$actual_sha256" >&2
  exit 1
fi

yq -o=json '
  select(.kind == "CustomResourceDefinition"
    and .metadata.name == "activemqartemises.broker.amq.io")
  | .spec.versions[]
  | select(.name == "v1beta1")
  | .schema.openAPIV3Schema
' "$manifest" > "$schema"

helm pull "$operator_chart" --version "$operator_chart_version" \
  --untar --untardir "$temp_dir" >/dev/null

for environment in test nonprod prod; do
  rendered="$temp_dir/artemis-$environment.yaml"
  broker_cr="$temp_dir/artemis-$environment-cr.yaml"
  helm template validation "$repo_root/charts/artemis-ha" \
    --values "$repo_root/environments/$environment/artemis-values.yaml" \
    > "$rendered"
  yq 'select(.kind == "ActiveMQArtemis")' "$rendered" > "$broker_cr"
  kubeconform -strict -schema-location "$schema" "$broker_cr" >/dev/null

  operator_rendered="$temp_dir/operator-$environment.yaml"
  helm template validation-operator "$operator_chart_dir" \
    --namespace example-platform \
    --values "$repo_root/environments/$environment/operator-values.yaml" \
    > "$operator_rendered"
  kubeconform -strict -ignore-missing-schemas "$operator_rendered" >/dev/null
done

printf '%s\n' 'operator contract validation: PASS (ArkMQ 2.2.0, 3 overlays)'
