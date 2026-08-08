#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
operator_manifest_url=${ARKMQ_OPERATOR_MANIFEST_URL:-https://github.com/arkmq-org/arkmq-org-broker-operator/releases/download/v2.2.0/activemq-artemis-operator.yaml}
operator_manifest_sha256=${ARKMQ_OPERATOR_MANIFEST_SHA256:-ae8ce2672e1cb17dc888e249b076c08e5fb4c44f8cc90dcaef067e86bb4b49f3}

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

operator_chart_dir="$temp_dir/arkmq-operator"
cp -R "$repo_root/charts/arkmq-operator/." "$operator_chart_dir"
helm dependency build "$operator_chart_dir" >/dev/null

for environment in test nonprod prod; do
  ecr_repository=PLACEHOLDER_NONPROD_ECR_REPOSITORY
  if [[ "$environment" == prod ]]; then
    ecr_repository=PLACEHOLDER_PROD_ECR_REPOSITORY
  fi
  rendered="$temp_dir/artemis-$environment.yaml"
  broker_cr="$temp_dir/artemis-$environment-cr.yaml"
  helm template validation "$repo_root/charts/artemis-ha" \
    --values "$repo_root/environments/$environment/artemis-values.yaml" \
    > "$rendered"
  yq 'select(.kind == "ActiveMQArtemis")' "$rendered" > "$broker_cr"
  kubeconform -strict -schema-location "$schema" "$broker_cr" >/dev/null
  if [[ "$(yq -r '.spec.resourceTemplates | length' "$broker_cr")" != 1 ]] || \
     [[ "$(yq -r '.spec.resourceTemplates[0] | has("selector")' "$broker_cr")" != false ]]; then
    printf '%s broker CR must apply one unscoped resourceTemplate to operator-generated resources\n' \
      "$environment" >&2
    exit 1
  fi
  for required_label in app contact env fismaid; do
    if [[ "$(LABEL="$required_label" yq -r '.spec.resourceTemplates[0].labels[strenv(LABEL)] // ""' "$broker_cr")" == "" ]]; then
      printf '%s broker resourceTemplate is missing required label %s\n' \
        "$environment" "$required_label" >&2
      exit 1
    fi
  done
  broker_version=$(yq -r '.spec.version' "$broker_cr")
  compact_version=${broker_version//./}
  if [[ "$(yq -r '.spec.deploymentPlan | has("image") or has("initImage")' "$broker_cr")" != false ]]; then
    printf '%s broker CR must let the operator resolve images from spec.version\n' "$environment" >&2
    exit 1
  fi

  operator_rendered="$temp_dir/operator-$environment.yaml"
  helm template validation-operator "$operator_chart_dir" \
    --namespace example-platform \
    --set-string "global.requiredLabels.env=$environment" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.image.repository=$ecr_repository/arkmq-operator" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerInitRepository=$ecr_repository/activemq-artemis-broker-init" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerKubernetesRepository=$ecr_repository/activemq-artemis-broker-kubernetes" \
    > "$operator_rendered"
  kubeconform -strict -ignore-missing-schemas "$operator_rendered" >/dev/null

  if [[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$operator_rendered")" != "activemq-artemis-controller-manager-v2" ]] || \
     [[ "$(yq -r 'select(.kind == "Deployment") | .spec.selector.matchLabels | length' "$operator_rendered")" != 2 ]] || \
     [[ "$(yq -r 'select(.kind == "Deployment") | .spec.selector.matchLabels."control-plane"' "$operator_rendered")" != "controller-manager" ]] || \
     [[ "$(yq -r 'select(.kind == "Deployment") | .spec.selector.matchLabels.name' "$operator_rendered")" != "activemq-artemis-operator" ]]; then
    printf '%s operator Deployment must use the v2 identity and stable two-label selector\n' \
      "$environment" >&2
    exit 1
  fi

  for required_label in app contact env fismaid; do
    if [[ "$(LABEL="$required_label" yq -r 'select(.kind == "Deployment") | .metadata.labels[strenv(LABEL)] // ""' "$operator_rendered")" == "" ]] || \
       [[ "$(LABEL="$required_label" yq -r 'select(.kind == "Deployment") | .spec.template.metadata.labels[strenv(LABEL)] // ""' "$operator_rendered")" == "" ]]; then
      printf '%s operator Deployment is missing required label %s\n' \
        "$environment" "$required_label" >&2
      exit 1
    fi
    if [[ "$(LABEL="$required_label" yq -r 'select(.kind == "Deployment") | .spec.selector.matchLabels[strenv(LABEL)] // ""' "$operator_rendered")" != "" ]]; then
      printf '%s operator Deployment selector must exclude metadata-only label %s\n' \
        "$environment" "$required_label" >&2
      exit 1
    fi
  done

  init_env="RELATED_IMAGE_ActiveMQ_Artemis_Broker_Init_$compact_version"
  broker_env="RELATED_IMAGE_ActiveMQ_Artemis_Broker_Kubernetes_$compact_version"
  init_image=$(ENV_NAME="$init_env" yq -r \
    'select(.kind == "Deployment") | .spec.template.spec.containers[].env[] | select(.name == strenv(ENV_NAME)) | .value' \
    "$operator_rendered")
  broker_image=$(ENV_NAME="$broker_env" yq -r \
    'select(.kind == "Deployment") | .spec.template.spec.containers[].env[] | select(.name == strenv(ENV_NAME)) | .value' \
    "$operator_rendered")
  if [[ "$init_image" != "$ecr_repository/activemq-artemis-broker-init@sha256:"* ]]; then
    printf '%s operator init image does not resolve version %s to the private digest\n' \
      "$environment" "$broker_version" >&2
    exit 1
  fi
  if [[ "$broker_image" != "$ecr_repository/activemq-artemis-broker-kubernetes@sha256:"* ]]; then
    printf '%s operator broker image does not resolve version %s to the private digest\n' \
      "$environment" "$broker_version" >&2
    exit 1
  fi
done

printf '%s\n' 'operator contract validation: PASS (ArkMQ 2.2.0, 3 overlays)'
