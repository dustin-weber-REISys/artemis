#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
gitops_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

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

Read-only desired-state check for the Argo CD ApplicationSet, ArkMQ operator,
and every Workload Cell enabled in the selected local catalog. It compares
that local inventory with live cluster state. Run repository validation first.

The reconciled Git revisions are reported for evidence. They are intentionally
not a hard equality check because the local directory may not contain Git
metadata. If a reported revision is not the GitHub revision being verified,
record and review that drift before treating the result as promotion evidence.
USAGE
}

require_value() {
  [[ -n "${2-}" ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
}

while (($#)); do
  case "$1" in
    --context) require_value "$1" "${2-}"; context=$2; shift 2 ;;
    --argocd-namespace) require_value "$1" "${2-}"; argocd_namespace=$2; shift 2 ;;
    --environment) require_value "$1" "${2-}"; environment=$2; shift 2 ;;
    --controller-deployment) require_value "$1" "${2-}"; controller_deployment=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$context" ]] || { printf '%s\n' '--context is required' >&2; exit 2; }
[[ -n "$argocd_namespace" ]] || { printf '%s\n' '--argocd-namespace is required' >&2; exit 2; }
case "$environment" in
  test|nonprod|prod) ;;
  *) printf '%s\n' '--environment must be test, nonprod, or prod' >&2; exit 2 ;;
esac

for command_name in kubectl yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done

topology="$gitops_root/argocd/catalogs/$environment.yaml"
[[ -f "$topology" ]] || { printf 'effective topology file not found: %s\n' "$topology" >&2; exit 2; }

applicationset="$environment-artemis-workloads"
operator_application="$environment-arkmq-operator"
project=messaging-platform
local_server=https://kubernetes.default.svc
platform_namespace=$(yq -r '.platformNamespace // ""' "$topology")
operator_deployment=activemq-artemis-controller-manager-v2
errors=0

error() {
  printf 'ERROR: %s\n' "$*" >&2
  errors=$((errors + 1))
}

check_deployment() {
  local namespace=$1
  local name=$2
  local label=$3
  local deployment_json=
  local available
  local desired
  if ! deployment_json=$(kubectl --context "$context" --namespace "$namespace" get deployment "$name" -o json); then
    error "$label Deployment $namespace/$name is not readable"
    return
  fi
  available=$(yq -r '.status.availableReplicas // 0' <<<"$deployment_json")
  desired=$(yq -r '.spec.replicas // 1' <<<"$deployment_json")
  if [[ "$available" -lt 1 ]]; then
    error "$label has $available available replicas (desired: $desired)"
  else
    printf '%s: available (%s/%s replicas)\n' "$label" "$available" "$desired"
  fi
}

check_application_status() {
  local name=$1
  local application_json=$2
  local sync_status
  local health_status
  local revision
  local blocking_conditions
  sync_status=$(yq -r '.status.sync.status // "Unknown"' <<<"$application_json")
  health_status=$(yq -r '.status.health.status // "Unknown"' <<<"$application_json")
  revision=$(yq -r '.status.sync.revision // "unknown"' <<<"$application_json")
  [[ "$sync_status" == Synced ]] || error "Application $argocd_namespace/$name sync status is $sync_status; expected Synced"
  [[ "$health_status" == Healthy ]] || error "Application $argocd_namespace/$name health is $health_status; expected Healthy"

  blocking_conditions=$(yq -r '
    [.status.conditions[]?
      | select(.type == "InvalidSpecError" or .type == "RepeatedResourceWarning")
      | .type + ": " + (.message // "")
    ] | join("; ")
  ' <<<"$application_json")
  [[ -z "$blocking_conditions" ]] || error "Application $argocd_namespace/$name reports $blocking_conditions"
  printf 'Application %s: %s/%s revision=%s\n' "$name" "$sync_status" "$health_status" "$revision"
}

[[ -n "$platform_namespace" ]] || error "$environment topology does not declare platformNamespace"
check_deployment "$argocd_namespace" "$controller_deployment" 'ApplicationSet controller'

applicationset_json=
if ! applicationset_json=$(kubectl --context "$context" --namespace "$argocd_namespace" \
  get applicationset "$applicationset" -o json); then
  error "ApplicationSet $argocd_namespace/$applicationset is not readable"
else
  condition_count=$(yq -r '.status.conditions // [] | length' <<<"$applicationset_json")
  [[ "$condition_count" -gt 0 ]] || error "ApplicationSet $argocd_namespace/$applicationset has no status conditions"
  applicationset_errors=$(yq -r '
    [.status.conditions[]? | select(.type == "ErrorOccurred" and .status == "True")
      | .message // "unspecified controller error"] | join("; ")
  ' <<<"$applicationset_json")
  [[ -z "$applicationset_errors" ]] || error "ApplicationSet $argocd_namespace/$applicationset reports: $applicationset_errors"
  printf 'ApplicationSet %s: reconciled (%s conditions)\n' "$applicationset" "$condition_count"
fi

operator_application_json=
if ! operator_application_json=$(kubectl --context "$context" --namespace "$argocd_namespace" \
  get application "$operator_application" -o json); then
  error "ArkMQ operator Application $argocd_namespace/$operator_application is not readable"
else
  check_application_status "$operator_application" "$operator_application_json"
  operator_server=$(yq -r '.spec.destination.server // ""' <<<"$operator_application_json")
  operator_namespace=$(yq -r '.spec.destination.namespace // ""' <<<"$operator_application_json")
  if [[ "$operator_server" != "$local_server" || "$operator_namespace" != "$platform_namespace" ]]; then
    error "ArkMQ operator Application targets $operator_server namespace $operator_namespace; expected $local_server namespace $platform_namespace"
  fi
fi

if [[ -n "$platform_namespace" ]]; then
  check_deployment "$platform_namespace" "$operator_deployment" 'ArkMQ operator'
fi

project_json=
if ! project_json=$(kubectl --context "$context" --namespace "$argocd_namespace" \
  get appproject "$project" -o json); then
  error "AppProject $argocd_namespace/$project is not readable"
fi

enabled_cells=()
while IFS= read -r enabled_cell; do
  enabled_cells[${#enabled_cells[@]}]=$enabled_cell
done < <(yq -r '.workloadCells[] | select(.enabled == "true") | [.workloadCellName, .workloadNamespace] | @tsv' "$topology")
[[ "${#enabled_cells[@]}" -gt 0 ]] || error "$environment catalog has no enabled Workload Cells"

for enabled_cell in "${enabled_cells[@]}"; do
  IFS=$'\t' read -r workload_cell workload_namespace <<<"$enabled_cell"
  application="$workload_cell-artemis"

  if [[ -n "$project_json" ]]; then
    destination_count=$(SERVER="$local_server" NAMESPACE="$workload_namespace" yq -r '
      [.spec.destinations[]?
        | select(.server == strenv(SERVER))
        | select(.namespace == strenv(NAMESPACE) or (.namespace == "artemis-*" and strenv(NAMESPACE) | test("^artemis-")))
      ] | length
    ' <<<"$project_json")
    [[ "$destination_count" -eq 1 ]] || \
      error "AppProject $argocd_namespace/$project does not allow $local_server namespace $workload_namespace"
  fi

  application_json=
  if ! application_json=$(kubectl --context "$context" --namespace "$argocd_namespace" \
    get application "$application" -o json); then
    error "enabled Workload Cell $workload_cell did not produce Application $argocd_namespace/$application"
    continue
  fi
  check_application_status "$application" "$application_json"

  owner_count=$(APPLICATIONSET="$applicationset" yq -r '
    [.metadata.ownerReferences[]? | select(.kind == "ApplicationSet" and .name == strenv(APPLICATIONSET))] | length
  ' <<<"$application_json")
  [[ "$owner_count" -eq 1 ]] || error "Application $argocd_namespace/$application is not owned by ApplicationSet $applicationset"

  actual_server=$(yq -r '.spec.destination.server // ""' <<<"$application_json")
  actual_namespace=$(yq -r '.spec.destination.namespace // ""' <<<"$application_json")
  if [[ "$actual_server" != "$local_server" || "$actual_namespace" != "$workload_namespace" ]]; then
    error "Application $argocd_namespace/$application targets $actual_server namespace $actual_namespace; expected $local_server namespace $workload_namespace"
  fi

  release_name=$(yq -r '.spec.source.helm.releaseName // .metadata.name // ""' <<<"$application_json")
  [[ -n "$release_name" ]] || release_name=$application
  broker_cr="${release_name}-artemis-ha"
  if ((${#broker_cr} > 63)); then
    broker_cr=${broker_cr:0:63}
    broker_cr=${broker_cr%-}
  fi

  broker_json=
  if ! broker_json=$(kubectl --context "$context" --namespace "$workload_namespace" \
    get activemqartemis "$broker_cr" -o json); then
    error "Application $application did not produce readable ActiveMQArtemis $workload_namespace/$broker_cr"
    continue
  fi
  generation=$(yq -r '.metadata.generation // 0' <<<"$broker_json")
  condition_count=$(yq -r '.status.conditions // [] | length' <<<"$broker_json")
  [[ "$condition_count" -gt 0 ]] || error "ActiveMQArtemis $workload_namespace/$broker_cr has no status conditions; operator has not processed generation $generation"
  failed_conditions=$(GENERATION="$generation" yq -r '
    [.status.conditions[]?
      | select((.observedGeneration // env(GENERATION)) == env(GENERATION))
      | select(.status == "False" and (.type == "Valid" or .type == "Deployed"))
      | .type + "=False reason=" + (.reason // "unknown") + ": " + (.message // "")
    ] | join("; ")
  ' <<<"$broker_json")
  [[ -z "$failed_conditions" ]] || error "ActiveMQArtemis $workload_namespace/$broker_cr reconciliation failed: $failed_conditions"
  printf 'Broker CR %s/%s: generation=%s conditions=%s\n' \
    "$workload_namespace" "$broker_cr" "$generation" "$condition_count"

  statefulset="$broker_cr-ss"
  statefulset_json=
  if ! statefulset_json=$(kubectl --context "$context" --namespace "$workload_namespace" \
    get statefulset "$statefulset" -o json); then
    error "ArkMQ operator has not created StatefulSet $workload_namespace/$statefulset"
    continue
  fi
  desired=$(yq -r '.spec.replicas // 0' <<<"$statefulset_json")
  current=$(yq -r '.status.currentReplicas // 0' <<<"$statefulset_json")
  ready=$(yq -r '.status.readyReplicas // 0' <<<"$statefulset_json")
  [[ "$ready" -eq "$desired" ]] || error "StatefulSet $workload_namespace/$statefulset has $ready/$desired ready replicas"
  printf 'Broker StatefulSet %s/%s: desired=%s current=%s ready=%s\n' \
    "$workload_namespace" "$statefulset" "$desired" "$current" "$ready"
done

if [[ "$errors" -ne 0 ]]; then
  printf 'Live Artemis health: FAIL (%s errors)\n' "$errors" >&2
  exit 1
fi

printf 'Live Artemis health: PASS (%s enabled Workload Cells)\n' "${#enabled_cells[@]}"
