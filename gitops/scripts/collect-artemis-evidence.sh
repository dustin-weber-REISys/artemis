#!/usr/bin/env bash
set -uo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
gitops_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

context=
argocd_namespace=
environment=
log_tail=200
failures=0

usage() {
  cat <<'USAGE'
Usage: collect-artemis-evidence.sh \
  --context CONTEXT \
  --argocd-namespace NAMESPACE \
  --environment test|nonprod|prod \
  [--log-tail LINES]

Collect a read-only, text evidence bundle on stdout. Redirect it to a file:

  ./gitops/scripts/collect-artemis-evidence.sh ... > artemis-evidence.txt

The bundle omits Secret data. Review logs and manifests for environment-specific
information before sharing outside the authorized team.
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
    --log-tail) require_value "$1" "${2-}"; log_tail=$2; shift 2 ;;
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
[[ "$log_tail" =~ ^[0-9]+$ ]] || { printf '%s\n' '--log-tail must be a non-negative integer' >&2; exit 2; }
for command_name in kubectl yq; do
  command -v "$command_name" >/dev/null 2>&1 || { printf '%s is required\n' "$command_name" >&2; exit 2; }
done

topology="$gitops_root/argocd/topology/$environment.yaml"
[[ -f "$topology" ]] || { printf 'effective topology file not found: %s\n' "$topology" >&2; exit 2; }
platform_namespace=$(yq -r '.platformNamespace // ""' "$topology")
[[ -n "$platform_namespace" ]] || { printf 'platformNamespace is missing from %s\n' "$topology" >&2; exit 2; }

section() {
  printf '\n===== %s =====\n' "$1"
}

capture() {
  local exit_code
  printf '$'
  printf ' %q' "$@"
  printf '\n'
  if "$@" 2>&1; then
    return 0
  else
    exit_code=$?
    failures=$((failures + 1))
    printf '[command failed with exit %s; collection continued]\n' "$exit_code"
    return 0
  fi
}

section metadata
printf 'collected_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'context=%s\nenvironment=%s\nargocd_namespace=%s\nplatform_namespace=%s\n' \
  "$context" "$environment" "$argocd_namespace" "$platform_namespace"
capture kubectl --context "$context" version

section argocd
capture kubectl --context "$context" --namespace "$argocd_namespace" get \
  applicationset "$environment-artemis-workloads" -o yaml
capture kubectl --context "$context" --namespace "$argocd_namespace" get \
  application "$environment-arkmq-operator" -o yaml
capture kubectl --context "$context" --namespace "$argocd_namespace" get \
  deployment argocd-applicationset-controller -o wide

section operator
capture kubectl --context "$context" --namespace "$platform_namespace" get \
  deployment activemq-artemis-controller-manager-v2 -o yaml
capture kubectl --context "$context" --namespace "$platform_namespace" logs \
  -l control-plane=controller-manager --all-containers=true --prefix=true --tail="$log_tail"
capture kubectl --context "$context" auth can-i list activemqartemises.broker.amq.io \
  --all-namespaces --as="system:serviceaccount:$platform_namespace:activemq-artemis-controller-manager"

while IFS=$'\t' read -r workload_cell workload_namespace; do
  [[ -n "$workload_cell" ]] || continue
  application="$workload_cell-artemis"
  application_json=$(kubectl --context "$context" --namespace "$argocd_namespace" \
    get application "$application" -o json 2>/dev/null || true)
  release_name=$(yq -r '.spec.source.helm.releaseName // .metadata.name // ""' <<<"$application_json" 2>/dev/null || true)
  [[ -n "$release_name" ]] || release_name=$application
  live_namespace=$(yq -r '.spec.destination.namespace // ""' <<<"$application_json" 2>/dev/null || true)
  [[ -z "$live_namespace" || "$live_namespace" == "$workload_namespace" ]] || \
    printf 'WARNING: local topology namespace %s differs from live Application destination %s\n' \
      "$workload_namespace" "$live_namespace"
  broker_cr="$release_name-artemis-ha"
  if ((${#broker_cr} > 63)); then
    broker_cr=${broker_cr:0:63}
    broker_cr=${broker_cr%-}
  fi

  section "Workload Cell $workload_cell"
  capture kubectl --context "$context" --namespace "$argocd_namespace" get application "$application" -o yaml
  capture kubectl --context "$context" auth can-i create statefulsets.apps \
    --namespace "$workload_namespace" --as="system:serviceaccount:$platform_namespace:activemq-artemis-controller-manager"
  capture kubectl --context "$context" --namespace "$workload_namespace" get activemqartemis "$broker_cr" -o yaml
  capture kubectl --context "$context" --namespace "$workload_namespace" get \
    statefulset,pod,pvc,service,configmap -l "ActiveMQArtemis=$broker_cr" -o wide
  capture kubectl --context "$context" --namespace "$workload_namespace" describe \
    statefulset "$broker_cr-ss"
  capture kubectl --context "$context" --namespace "$workload_namespace" get events \
    --sort-by=.metadata.creationTimestamp
done < <(yq -r '.workloadCells[] | select(.enabled == "true") | [.workloadCellName, .workloadNamespace] | @tsv' "$topology")

section reminder
printf '%s\n' 'No Secret objects were requested. Review this bundle before sharing it.'
if ((failures > 0)); then
  printf 'Evidence collection: PARTIAL (%d command failures)\n' "$failures"
  exit 1
fi
printf '%s\n' 'Evidence collection: COMPLETE'
