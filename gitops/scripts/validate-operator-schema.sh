#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
release_file="$repo_root/releases/current.yaml"
schema_mode=offline
local_manifest=''

while (($#)); do
  case "$1" in
    --network) schema_mode=network; shift ;;
    --manifest) schema_mode=local; local_manifest=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for command_name in helm yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done
if [[ "$schema_mode" != offline ]]; then
  command -v kubeconform >/dev/null 2>&1 || {
    printf '%s\n' 'kubeconform is required for --manifest or --network schema validation' >&2
    exit 2
  }
fi
if [[ "$schema_mode" == network ]]; then
  command -v curl >/dev/null 2>&1 || {
    printf '%s\n' 'curl is required for --network schema validation' >&2
    exit 2
  }
fi

operator_version=$(yq -r '.operator.version' "$release_file")
operator_image_tag=$(yq -r '.operator.image.tag' "$release_file")
broker_version=$(yq -r '.broker.version' "$release_file")
broker_init_image_tag=$(yq -r '.broker.images.init.tag' "$release_file")
broker_runtime_image_tag=$(yq -r '.broker.images.runtime.tag' "$release_file")
operator_manifest_url=${ARKMQ_OPERATOR_MANIFEST_URL:-$(yq -r '.operator.manifest.url' "$release_file")}
operator_manifest_sha256=${ARKMQ_OPERATOR_MANIFEST_SHA256:-$(yq -r '.operator.manifest.sha256' "$release_file")}

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-operator-schema.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
schema="$temp_dir/activemqartemis-v1beta1.json"

if [[ "$schema_mode" != offline ]]; then
  manifest="$temp_dir/activemq-artemis-operator.yaml"
  if [[ "$schema_mode" == network ]]; then
    curl -fsSL "$operator_manifest_url" -o "$manifest"
  else
    [[ -f "$local_manifest" ]] || {
      printf 'operator manifest not found: %s\n' "$local_manifest" >&2
      exit 1
    }
    cp "$local_manifest" "$manifest"
  fi
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
  [[ -s "$schema" ]] || {
    printf '%s\n' 'ActiveMQArtemis v1beta1 schema was not found in the operator manifest' >&2
    exit 1
  }
fi

operator_rendered_count=0

if [[ "${ARTEMIS_RELEASE_GATE:-false}" == true && -z "${ARKMQ_UPSTREAM_CHART:-}" ]]; then
  printf '%s\n' 'release-gate operator validation requires ARKMQ_UPSTREAM_CHART' >&2
  exit 2
fi

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
  if [[ "$schema_mode" != offline ]]; then
    kubeconform -strict -schema-location "$schema" "$broker_cr" >/dev/null
  fi
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
  if [[ -n "${ARKMQ_UPSTREAM_CHART:-}" ]]; then
    "$repo_root/scripts/render-arkmq-operator.sh" --environment "$environment" \
      --artifact "$ARKMQ_UPSTREAM_CHART" > "$operator_rendered"
  elif [[ "$schema_mode" == network ]]; then
    "$repo_root/scripts/render-arkmq-operator.sh" --environment "$environment" \
      > "$operator_rendered"
  else
    continue
  fi
  operator_rendered_count=$((operator_rendered_count + 1))
  if [[ "$schema_mode" != offline ]]; then
    kubeconform -strict -ignore-missing-schemas "$operator_rendered" >/dev/null
  fi

  if [[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$operator_rendered")" != "activemq-artemis-controller-manager-v2" ]] || \
     [[ "$(yq -r 'select(.kind == "Deployment") | .spec.selector.matchLabels | length' "$operator_rendered")" != 2 ]] || \
     [[ "$(yq -r 'select(.kind == "Deployment") | .spec.selector.matchLabels."control-plane"' "$operator_rendered")" != "controller-manager" ]] || \
     [[ "$(yq -r 'select(.kind == "Deployment") | .spec.selector.matchLabels.name' "$operator_rendered")" != "activemq-artemis-operator" ]]; then
    printf '%s operator Deployment must use the v2 identity and stable two-label selector\n' \
      "$environment" >&2
    exit 1
  fi

  if [[ "$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "manager") | .image' "$operator_rendered")" != "$ecr_repository/arkmq-operator:$operator_image_tag" ]]; then
    printf '%s operator Deployment must resolve the private ECR image by its centrally selected tag\n' \
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
  if [[ "$init_image" != "$ecr_repository/activemq-artemis-broker-init:$broker_init_image_tag" ]]; then
    printf '%s operator init image does not resolve version %s to the selected private mirror tag\n' \
      "$environment" "$broker_version" >&2
    exit 1
  fi
  if [[ "$broker_image" != "$ecr_repository/activemq-artemis-broker-kubernetes:$broker_runtime_image_tag" ]]; then
    printf '%s operator broker image does not resolve version %s to the selected private mirror tag\n' \
      "$environment" "$broker_version" >&2
    exit 1
  fi
done

if [[ "$schema_mode" == offline ]]; then
  printf '%s\n' 'operator CRD schema validation: NOT_RUN (offline default; use --manifest FILE or --network)'
else
  printf 'operator CRD schema validation: PASS (%s source)\n' "$schema_mode"
fi
if [[ "$operator_rendered_count" -eq 3 ]]; then
  printf 'operator contract validation: PASS (ArkMQ %s, 3 Kustomize overlays)\n' "$operator_version"
else
  printf '%s\n' 'operator rendered contract validation: NOT_RUN (set ARKMQ_UPSTREAM_CHART or use --network)'
  if [[ "${ARTEMIS_RELEASE_GATE:-false}" == true ]]; then
    exit 1
  fi
fi
