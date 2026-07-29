#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
acceptance_plan="$repo_root/tests/e2e/acceptance-plan.yaml"
manifest_root="$repo_root/tests/e2e/manifests"
scenario=''
context=''
cluster=''
namespace=''
mode=dry-run
report="$repo_root/reports/eks-scenario.json"
confirm_context=''
confirm_cluster=''
confirm_namespace=''
target_pod=''
target_pods=''
target_node=''
zone=''
broker_selector='app.kubernetes.io/component=broker'
console_url=''
argo_app=''
argo_action=status
argo_revision=''
load_manifest=''
rotation_ready=0
allow_node_drain=0
cleanup=0
list_actions=0

list_runner_actions() {
  printf '%s\t%s\n' \
    terminate-pod-process 'Send TERM to PID 1 in one explicitly named pod.' \
    delete-single-pod 'Delete one explicitly named pod without waiting for replacement.' \
    delete-multiple-pods 'Delete at least two explicitly named comma-separated pods.' \
    drain-node 'Drain one explicitly named node with the broker PDB enforced.' \
    inspect-zone-nodes 'List nodes in one zone; the operator performs any approved AZ disruption manually.' \
    manage-replication-isolation-policy 'Apply or remove the temporary broker replication NetworkPolicy.' \
    manage-zookeeper-isolation-policy 'Apply or remove the temporary broker-to-ZooKeeper NetworkPolicy.' \
    operate-argocd-application 'Get, sync, or roll back one explicitly named Argo CD application.' \
    restart-broker-statefulsets 'Request a rolling restart after separately approved credential rotation.' \
    check-console-http-access 'Request the console URL and record its HTTP status; role verification remains manual.' \
    apply-load-job 'Apply an operator-supplied Kubernetes Job manifest; load verification remains manual.'
}

usage() {
  printf '%s\n' 'Usage: eks-scenario.sh --scenario ID --context CONTEXT --cluster CLUSTER --namespace NAMESPACE [options]'
  printf '%s\n' '       eks-scenario.sh --list-actions'
  printf '%s\n' 'Default mode reports the planned action. --execute runs only runner-assisted actions.'
  printf '%s\n' 'Manual procedures and repository checks are never reported as executed by this runner.'
  printf '%s\n' 'Runner actions:'
  list_runner_actions | while IFS=$'\t' read -r action_id action_description; do
    printf '  %-39s %s\n' "$action_id" "$action_description"
  done
}

require_option_value() {
  local option=$1
  local value=${2-}
  [[ -n "$value" ]] || { printf '%s requires a value\n' "$option" >&2; exit 2; }
}

while (($#)); do
  case "$1" in
    --scenario) require_option_value "$1" "${2-}"; scenario=$2; shift 2 ;;
    --context) require_option_value "$1" "${2-}"; context=$2; shift 2 ;;
    --cluster) require_option_value "$1" "${2-}"; cluster=$2; shift 2 ;;
    --namespace) require_option_value "$1" "${2-}"; namespace=$2; shift 2 ;;
    --execute) mode=execute; shift ;;
    --confirm-context) require_option_value "$1" "${2-}"; confirm_context=$2; shift 2 ;;
    --confirm-cluster) require_option_value "$1" "${2-}"; confirm_cluster=$2; shift 2 ;;
    --confirm-namespace) require_option_value "$1" "${2-}"; confirm_namespace=$2; shift 2 ;;
    --target-pod) require_option_value "$1" "${2-}"; target_pod=$2; shift 2 ;;
    --target-pods) require_option_value "$1" "${2-}"; target_pods=$2; shift 2 ;;
    --target-node) require_option_value "$1" "${2-}"; target_node=$2; shift 2 ;;
    --zone) require_option_value "$1" "${2-}"; zone=$2; shift 2 ;;
    --broker-selector) require_option_value "$1" "${2-}"; broker_selector=$2; shift 2 ;;
    --console-url) require_option_value "$1" "${2-}"; console_url=$2; shift 2 ;;
    --argo-app) require_option_value "$1" "${2-}"; argo_app=$2; shift 2 ;;
    --argo-action) require_option_value "$1" "${2-}"; argo_action=$2; shift 2 ;;
    --argo-revision) require_option_value "$1" "${2-}"; argo_revision=$2; shift 2 ;;
    --load-manifest) require_option_value "$1" "${2-}"; load_manifest=$2; shift 2 ;;
    --rotation-ready) rotation_ready=1; shift ;;
    --allow-node-drain) allow_node_drain=1; shift ;;
    --cleanup) cleanup=1; shift ;;
    --report) require_option_value "$1" "${2-}"; report=$2; shift 2 ;;
    --list-actions) list_actions=1; shift ;;
    --help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$list_actions" == 1 ]]; then
  [[ -z "$scenario" ]] || { printf '%s\n' '--list-actions cannot be combined with --scenario' >&2; exit 2; }
  list_runner_actions
  exit 0
fi

[[ "$scenario" =~ ^[a-z0-9-]+$ ]] || { printf '%s\n' '--scenario must use lowercase letters, digits, and hyphens' >&2; exit 2; }
[[ -n "$context" && -n "$cluster" && -n "$namespace" ]] || { usage >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { printf '%s\n' 'yq is required' >&2; exit 2; }

scenario_exists=$(SCENARIO_ID=$scenario yq -r '[.cases[] | select(.id == strenv(SCENARIO_ID))] | length' "$acceptance_plan")
[[ "$scenario_exists" == 1 ]] || { printf 'unknown acceptance case: %s\n' "$scenario" >&2; exit 2; }
destructive=$(SCENARIO_ID=$scenario yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .destructive' "$acceptance_plan")
claim=$(SCENARIO_ID=$scenario yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .claim' "$acceptance_plan")
action=$(SCENARIO_ID=$scenario yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .action' "$acceptance_plan")
execution_kind=$(SCENARIO_ID=$scenario yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .execution.kind' "$acceptance_plan")
runner_action=$(SCENARIO_ID=$scenario yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .execution.runnerAction // ""' "$acceptance_plan")
repository_command=$(SCENARIO_ID=$scenario yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .execution.command // ""' "$acceptance_plan")

planned="$action"
status=ACTION_PLANNED
target_description=unspecified
observation=''
safeguard='not-required'

write_report() {
  local report_dir
  local temp_report
  if [[ "$report" != /* ]]; then
    report="$repo_root/$report"
  fi
  report_dir=$(dirname -- "$report")
  mkdir -p "$report_dir"
  temp_report=$(mktemp "$report_dir/.eks-scenario-report.XXXXXX")
  trap 'rm -f -- "$temp_report"' EXIT
  REPORT_SCENARIO=$scenario \
  REPORT_CLAIM=$claim \
  REPORT_MODE=$mode \
  REPORT_STATUS=$status \
  REPORT_EXECUTION_KIND=$execution_kind \
  REPORT_RUNNER_ACTION=$runner_action \
  REPORT_TARGET=$target_description \
  REPORT_ACTION=$action \
  REPORT_PLANNED=$planned \
  REPORT_OBSERVATION=$observation \
  REPORT_SAFEGUARD=$safeguard \
    yq -n -o=json -I=0 '{
      "schemaVersion": "validation.artemis.apache.org/acceptance-action-report/v1",
      "kind": "AcceptanceActionReport",
      "acceptanceCase": strenv(REPORT_SCENARIO),
      "claim": strenv(REPORT_CLAIM),
      "mode": strenv(REPORT_MODE),
      "status": strenv(REPORT_STATUS),
      "acceptanceResult": "NOT_EVALUATED",
      "executionKind": strenv(REPORT_EXECUTION_KIND),
      "runnerAction": strenv(REPORT_RUNNER_ACTION),
      "target": strenv(REPORT_TARGET),
      "action": strenv(REPORT_ACTION),
      "planned": strenv(REPORT_PLANNED),
      "observation": strenv(REPORT_OBSERVATION),
      "destructiveSafeguard": strenv(REPORT_SAFEGUARD),
      "rpo": "zero-for-acknowledged-durable"
    }' > "$temp_report"
  mv -- "$temp_report" "$report"
  trap - EXIT
}

finish() {
  local exit_code=$1
  write_report
  printf '%s\n' "acceptanceCase=$scenario mode=$mode status=$status acceptanceResult=NOT_EVALUATED"
  printf '%s\n' "planned: $planned"
  [[ -z "$observation" ]] || printf '%s\n' "observation: $observation"
  exit "$exit_code"
}

case "$execution_kind" in
  runner-assisted)
    [[ -n "$runner_action" ]] || { printf '%s has no runner action\n' "$scenario" >&2; exit 2; }
    ;;
  manual-procedure)
    target_description=manual-acceptance-plan
    planned="follow gitops/tests/e2e/acceptance-plan.yaml and attach all required evidence"
    if [[ "$mode" == execute ]]; then
      status=MANUAL_REQUIRED
      printf 'acceptance case %s is a manual procedure; no action was executed\n' "$scenario" >&2
      finish 3
    fi
    status=MANUAL_PLAN
    finish 0
    ;;
  repository-check)
    target_description=$repository_command
    planned="run repository check: $repository_command"
    if [[ "$mode" == execute ]]; then
      status=REPOSITORY_CHECK_REQUIRED
      printf 'acceptance case %s uses repository check %s; this runner did not execute it\n' "$scenario" "$repository_command" >&2
      finish 3
    fi
    status=REPOSITORY_CHECK_PLAN
    finish 0
    ;;
  *)
    printf 'unsupported execution kind for %s: %s\n' "$scenario" "$execution_kind" >&2
    exit 2
    ;;
esac

if [[ "$mode" == execute ]]; then
  if [[ "$destructive" == true ]]; then
    [[ "$confirm_context" == "$context" ]] || { printf '%s\n' 'destructive execution requires --confirm-context matching --context' >&2; exit 2; }
    [[ "$confirm_cluster" == "$cluster" ]] || { printf '%s\n' 'destructive execution requires --confirm-cluster matching --cluster' >&2; exit 2; }
    [[ "$confirm_namespace" == "$namespace" ]] || { printf '%s\n' 'destructive execution requires --confirm-namespace matching --namespace' >&2; exit 2; }
    safeguard='exact-context-cluster-namespace-confirmations-validated'
  fi
  command -v kubectl >/dev/null 2>&1 || { printf '%s\n' 'kubectl is required for execution' >&2; exit 2; }
  actual_context=$(kubectl config current-context)
  [[ "$actual_context" == "$context" ]] || { printf 'current context %s does not match %s\n' "$actual_context" "$context" >&2; exit 2; }
  actual_cluster=$(kubectl config view --minify --context "$context" -o jsonpath='{.clusters[0].name}')
  [[ "$actual_cluster" == "$cluster" ]] || { printf 'selected context maps to cluster %s, not %s\n' "$actual_cluster" "$cluster" >&2; exit 2; }
  kubectl --context "$context" get namespace "$namespace" >/dev/null
elif [[ "$destructive" == true ]]; then
  safeguard='exact-context-cluster-namespace-confirmations-required-for-execution'
fi

case "$runner_action" in
  terminate-pod-process)
    [[ -n "$target_pod" ]] || { printf '%s\n' '--target-pod is required for this action' >&2; exit 2; }
    target_description=$target_pod
    planned="send TERM to PID 1 in the explicitly supplied pod"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" --namespace "$namespace" exec "$target_pod" -- kill -TERM 1
      status=ACTION_EXECUTED
    fi
    ;;
  delete-single-pod)
    [[ -n "$target_pod" ]] || { printf '%s\n' '--target-pod is required for this action' >&2; exit 2; }
    target_description=$target_pod
    planned="delete the explicitly supplied pod without waiting for replacement"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" --namespace "$namespace" delete pod "$target_pod" --wait=false
      status=ACTION_EXECUTED
    fi
    ;;
  delete-multiple-pods)
    [[ "$target_pods" == *,* ]] || { printf '%s\n' '--target-pods must contain at least two comma-separated pods' >&2; exit 2; }
    IFS=',' read -r -a pods <<< "$target_pods"
    ((${#pods[@]} >= 2)) || { printf '%s\n' 'this action requires at least two target pods' >&2; exit 2; }
    for pod in "${pods[@]}"; do
      [[ -n "$pod" ]] || { printf '%s\n' '--target-pods cannot contain an empty pod name' >&2; exit 2; }
    done
    target_description=$target_pods
    planned="delete the explicitly supplied pods without waiting for replacement"
    if [[ "$mode" == execute ]]; then
      for pod in "${pods[@]}"; do
        kubectl --context "$context" --namespace "$namespace" delete pod "$pod" --wait=false
      done
      status=ACTION_EXECUTED
    fi
    ;;
  drain-node)
    [[ -n "$target_node" ]] || { printf '%s\n' '--target-node is required for this action' >&2; exit 2; }
    [[ "$allow_node_drain" == 1 ]] || { printf '%s\n' '--allow-node-drain is required for node drain' >&2; exit 2; }
    target_description=$target_node
    planned="drain the explicitly supplied node with the broker PDB enforced"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" drain "$target_node" --ignore-daemonsets --grace-period=60 --timeout=15m
      status=ACTION_EXECUTED
    fi
    ;;
  inspect-zone-nodes)
    [[ -n "$zone" ]] || { printf '%s\n' '--zone is required for this action' >&2; exit 2; }
    target_description=$zone
    planned="list nodes in the supplied zone; no AZ disruption is performed"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" get nodes -l "topology.kubernetes.io/zone=$zone" -o name
      status=ACTION_EXECUTED
      observation='node inventory emitted to standard output; AZ simulation remains manual'
    fi
    ;;
  manage-replication-isolation-policy|manage-zookeeper-isolation-policy)
    if [[ "$runner_action" == manage-replication-isolation-policy ]]; then
      manifest="$manifest_root/replication-isolation-deny.yaml"
    else
      manifest="$manifest_root/zookeeper-isolation-deny.yaml"
    fi
    target_description=$manifest
    if [[ "$cleanup" == 1 ]]; then
      planned="delete temporary network policy $manifest"
      if [[ "$mode" == execute ]]; then
        kubectl --context "$context" --namespace "$namespace" delete -f "$manifest" --ignore-not-found
        status=ACTION_EXECUTED
      fi
    else
      planned="apply temporary network policy $manifest"
      if [[ "$mode" == execute ]]; then
        kubectl --context "$context" --namespace "$namespace" apply -f "$manifest"
        status=ACTION_EXECUTED
      fi
    fi
    ;;
  operate-argocd-application)
    [[ -n "$argo_app" ]] || { printf '%s\n' '--argo-app is required for this action' >&2; exit 2; }
    case "$argo_action" in status|sync|rollback) ;; *) printf '%s\n' '--argo-action must be status, sync, or rollback' >&2; exit 2 ;; esac
    if [[ "$argo_action" != status && -z "$argo_revision" ]]; then
      printf '%s\n' '--argo-revision is required for sync and rollback' >&2
      exit 2
    fi
    target_description=$argo_app
    planned="run argocd app $argo_action for the explicitly supplied application"
    if [[ "$mode" == execute ]]; then
      command -v argocd >/dev/null 2>&1 || { printf '%s\n' 'argocd is required for this action' >&2; exit 2; }
      case "$argo_action" in
        status) argocd app get "$argo_app" ;;
        sync) argocd app sync "$argo_app" --revision "$argo_revision" ;;
        rollback) argocd app rollback "$argo_app" "$argo_revision" ;;
      esac
      status=ACTION_EXECUTED
    fi
    ;;
  restart-broker-statefulsets)
    [[ "$rotation_ready" == 1 ]] || { printf '%s\n' '--rotation-ready is required after Vault rotation approval' >&2; exit 2; }
    target_description=$broker_selector
    planned="request a rolling restart of matching StatefulSets after external credential rotation"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" --namespace "$namespace" rollout restart statefulset --selector "$broker_selector"
      status=ACTION_EXECUTED
    fi
    ;;
  check-console-http-access)
    [[ "$console_url" =~ ^https?:// ]] || { printf '%s\n' '--console-url must be an http(s) URL' >&2; exit 2; }
    target_description=$console_url
    planned="request the console URL and record its HTTP status without evaluating role authorization"
    if [[ "$mode" == execute ]]; then
      command -v curl >/dev/null 2>&1 || { printf '%s\n' 'curl is required for this action' >&2; exit 2; }
      http_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 "$console_url")
      [[ "$http_code" =~ ^[1-5][0-9][0-9]$ ]] || { printf 'invalid console HTTP status: %s\n' "$http_code" >&2; exit 1; }
      observation="console HTTP status $http_code; OIDC and viewer/admin authorization remain manual"
      status=ACTION_EXECUTED
    fi
    ;;
  apply-load-job)
    [[ -n "$load_manifest" ]] || { printf '%s\n' '--load-manifest is required for this action' >&2; exit 2; }
    [[ -f "$load_manifest" ]] || { printf 'load manifest not found: %s\n' "$load_manifest" >&2; exit 2; }
    target_description=$load_manifest
    planned="apply the supplied load Job manifest; the profile and acceptance evidence remain external"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" --namespace "$namespace" apply -f "$load_manifest"
      status=ACTION_EXECUTED
    fi
    ;;
  *)
    printf 'acceptance case %s references unsupported runner action: %s\n' "$scenario" "$runner_action" >&2
    exit 2
    ;;
esac

finish 0
