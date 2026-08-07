#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

context=
argocd_namespace=
environment=
controller_deployment=argocd-applicationset-controller

usage() {
  cat <<'USAGE'
Usage: verify-argocd-applicationset.sh \
  --context CONTEXT \
  --argocd-namespace NAMESPACE \
  --environment test|nonprod|prod \
  [--controller-deployment NAME]

Read-only verification that the ApplicationSet controller is available, has
reported reconciliation status, and created one Argo CD Application for every
enabled broker pair in the environment topology.
USAGE
}

require_value() {
  option=$1
  value=${2-}
  [[ -n "$value" ]] || {
    printf '%s requires a value\n' "$option" >&2
    exit 2
  }
}

while (($#)); do
  case "$1" in
    --context)
      require_value "$1" "${2-}"
      context=$2
      shift 2
      ;;
    --argocd-namespace)
      require_value "$1" "${2-}"
      argocd_namespace=$2
      shift 2
      ;;
    --environment)
      require_value "$1" "${2-}"
      environment=$2
      shift 2
      ;;
    --controller-deployment)
      require_value "$1" "${2-}"
      controller_deployment=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$context" ]] || { printf '%s\n' '--context is required' >&2; exit 2; }
[[ -n "$argocd_namespace" ]] || { printf '%s\n' '--argocd-namespace is required' >&2; exit 2; }
case "$environment" in
  test|nonprod|prod) ;;
  *) printf '%s\n' '--environment must be test, nonprod, or prod' >&2; exit 2 ;;
esac

command -v kubectl >/dev/null 2>&1 || {
  printf '%s\n' 'kubectl is required' >&2
  exit 2
}
command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

topology="$repo_root/argocd/topology/$environment.yaml"
applicationset="$environment-artemis-workloads"
project=messaging-platform
local_server=https://kubernetes.default.svc
kubectl_args=(--context "$context" --namespace "$argocd_namespace")
errors=0

error() {
  printf 'ERROR: %s\n' "$*" >&2
  errors=$((errors + 1))
}

controller_json=
if ! controller_json=$(kubectl "${kubectl_args[@]}" get deployment "$controller_deployment" -o json); then
  error "ApplicationSet controller Deployment $argocd_namespace/$controller_deployment is not readable; confirm it is installed in the Argo CD namespace"
else
  available=$(yq -r '.status.availableReplicas // 0' <<<"$controller_json")
  desired=$(yq -r '.spec.replicas // 1' <<<"$controller_json")
  if [[ "$available" -lt 1 ]]; then
    error "ApplicationSet controller has $available available replicas (desired: $desired)"
  else
    printf 'ApplicationSet controller: available (%s/%s replicas)\n' "$available" "$desired"
  fi
fi

applicationset_json=
declared_parameter_names=
if ! applicationset_json=$(kubectl "${kubectl_args[@]}" get applicationset "$applicationset" -o json); then
  error "ApplicationSet $argocd_namespace/$applicationset is not readable"
else
  condition_count=$(yq -r '.status.conditions // [] | length' <<<"$applicationset_json")
  if [[ "$condition_count" -eq 0 ]]; then
    error "ApplicationSet has no status conditions; its controller has not reconciled it"
  else
    printf '%s\n' 'ApplicationSet conditions:'
    yq -r '.status.conditions[] | "  \(.type)=\(.status): \(.message // \"\")"' <<<"$applicationset_json"
    error_count=$(yq -r '[.status.conditions[] | select(.type == "ErrorOccurred" and .status == "True")] | length' <<<"$applicationset_json")
    [[ "$error_count" -eq 0 ]] || error 'ApplicationSet reports ErrorOccurred=True'
  fi
  declared_parameter_names=$(yq -r \
    '.spec.template.spec.source.helm.parameters // [] | map(.name) | sort | .[]' \
    <<<"$applicationset_json")
  invalid_empty_selector_parameters=$(yq -r '
    [.spec.template.spec.source.helm.parameters[]?
      | select(
          (.value == "{}") and
          (.name | test("^networkPolicy\\.(clientSources|managementSources|monitoringSources)\\[[0-9]+\\]\\.(namespaceSelector|podSelector)$"))
        )
      | .name
    ] | sort | .[]
  ' <<<"$applicationset_json")
  if [[ -n "$invalid_empty_selector_parameters" ]]; then
    error "ApplicationSet $argocd_namespace/$applicationset declares selector parameters with value {}; Helm parses {} as an array, not an object: $(paste -sd, <<<"$invalid_empty_selector_parameters")"
  fi
fi

project_json=
if ! project_json=$(kubectl "${kubectl_args[@]}" get appproject "$project" -o json); then
  error "AppProject $argocd_namespace/$project is not readable"
fi

enabled_pairs=()
while IFS= read -r enabled_pair; do
  enabled_pairs[${#enabled_pairs[@]}]=$enabled_pair
done < <(
  yq -r '.brokerPairs[] | select(.enabled == "true") | [.brokerPairName, .workloadNamespace] | @tsv' "$topology"
)
if [[ "${#enabled_pairs[@]}" -eq 0 ]]; then
  error "$environment topology has no enabled broker pairs"
fi

for enabled_pair in "${enabled_pairs[@]}"; do
  IFS=$'\t' read -r broker_pair workload_namespace <<<"$enabled_pair"
  application="$broker_pair-artemis"

  if [[ -n "$project_json" ]]; then
    destination_count=$(SERVER="$local_server" NAMESPACE="$workload_namespace" yq -r '
      [.spec.destinations[]?
        | select(.server == strenv(SERVER) and .namespace == strenv(NAMESPACE))
      ] | length
    ' <<<"$project_json")
    if [[ "$destination_count" -ne 1 ]]; then
      error "AppProject $argocd_namespace/$project does not allow destination $local_server namespace $workload_namespace for enabled broker pair $broker_pair"
    else
      printf 'Approved project destination: %s/%s\n' "$local_server" "$workload_namespace"
    fi
  fi

  application_json=
  if ! application_json=$(kubectl "${kubectl_args[@]}" get application "$application" -o json); then
    error "enabled broker pair $broker_pair did not produce Application $argocd_namespace/$application"
    continue
  fi

  owner_count=$(APPLICATIONSET="$applicationset" yq -r \
    '[.metadata.ownerReferences[]? | select(.kind == "ApplicationSet" and .name == strenv(APPLICATIONSET))] | length' \
    <<<"$application_json")
  if [[ "$owner_count" -ne 1 ]]; then
    error "Application $argocd_namespace/$application is not owned by ApplicationSet $applicationset"
  else
    printf 'Generated Application: %s/%s\n' "$argocd_namespace" "$application"
  fi

  if [[ -n "$applicationset_json" ]]; then
    actual_parameter_names=$(yq -r \
      '.spec.source.helm.parameters // [] | map(.name) | sort | .[]' \
      <<<"$application_json")
    if [[ "$actual_parameter_names" != "$declared_parameter_names" ]]; then
      unexpected_parameter_names=$(comm -13 \
        <(printf '%s\n' "$declared_parameter_names" | sed '/^$/d') \
        <(printf '%s\n' "$actual_parameter_names" | sed '/^$/d'))
      missing_parameter_names=$(comm -23 \
        <(printf '%s\n' "$declared_parameter_names" | sed '/^$/d') \
        <(printf '%s\n' "$actual_parameter_names" | sed '/^$/d'))
      parameter_drift=''
      if [[ -n "$unexpected_parameter_names" ]]; then
        parameter_drift=" unexpected: $(paste -sd, <<<"$unexpected_parameter_names")"
      fi
      if [[ -n "$missing_parameter_names" ]]; then
        parameter_drift="$parameter_drift missing: $(paste -sd, <<<"$missing_parameter_names")"
      fi
      error "Application $argocd_namespace/$application Helm parameters differ from ApplicationSet $applicationset;$parameter_drift"
    fi
  fi

  actual_server=$(yq -r '.spec.destination.server // ""' <<<"$application_json")
  actual_namespace=$(yq -r '.spec.destination.namespace // ""' <<<"$application_json")
  if [[ "$actual_server" != "$local_server" || "$actual_namespace" != "$workload_namespace" ]]; then
    error "Application $argocd_namespace/$application targets $actual_server namespace $actual_namespace; expected $local_server namespace $workload_namespace"
  fi

  invalid_spec_count=$(yq -r '
    [.status.conditions[]? | select(.type == "InvalidSpecError")]
    | length
  ' <<<"$application_json")
  if [[ "$invalid_spec_count" -ne 0 ]]; then
    invalid_spec_message=$(yq -r '
      [.status.conditions[]? | select(.type == "InvalidSpecError") | .message]
      | join("; ")
    ' <<<"$application_json")
    error "Application $argocd_namespace/$application has InvalidSpecError: $invalid_spec_message"
  fi
done

if [[ "$errors" -ne 0 ]]; then
  printf 'ApplicationSet verification: FAIL (%s errors)\n' "$errors" >&2
  exit 1
fi

printf 'ApplicationSet verification: PASS (%s enabled broker pairs)\n' "${#enabled_pairs[@]}"
