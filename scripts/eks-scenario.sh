#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
scenario_file="$repo_root/tests/e2e/scenarios.yaml"
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

usage() {
  printf '%s\n' 'Usage: eks-scenario.sh --scenario ID --context CONTEXT --cluster CLUSTER --namespace NAMESPACE [options]'
  printf '%s\n' 'Default mode prints a plan. Use --execute plus exact confirmation flags for mutation.'
}

while (($#)); do
  case "$1" in
    --scenario) scenario=$2; shift 2 ;;
    --context) context=$2; shift 2 ;;
    --cluster) cluster=$2; shift 2 ;;
    --namespace) namespace=$2; shift 2 ;;
    --execute) mode=execute; shift ;;
    --confirm-context) confirm_context=$2; shift 2 ;;
    --confirm-cluster) confirm_cluster=$2; shift 2 ;;
    --confirm-namespace) confirm_namespace=$2; shift 2 ;;
    --target-pod) target_pod=$2; shift 2 ;;
    --target-pods) target_pods=$2; shift 2 ;;
    --target-node) target_node=$2; shift 2 ;;
    --zone) zone=$2; shift 2 ;;
    --broker-selector) broker_selector=$2; shift 2 ;;
    --console-url) console_url=$2; shift 2 ;;
    --argo-app) argo_app=$2; shift 2 ;;
    --argo-action) argo_action=$2; shift 2 ;;
    --argo-revision) argo_revision=$2; shift 2 ;;
    --load-manifest) load_manifest=$2; shift 2 ;;
    --rotation-ready) rotation_ready=1; shift ;;
    --allow-node-drain) allow_node_drain=1; shift ;;
    --cleanup) cleanup=1; shift ;;
    --report) report=$2; shift 2 ;;
    --help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$scenario" =~ ^[a-z0-9-]+$ ]] || { printf '%s\n' '--scenario must use lowercase letters, digits, and hyphens' >&2; exit 2; }
[[ -n "$context" && -n "$cluster" && -n "$namespace" ]] || { usage >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { printf '%s\n' 'yq is required' >&2; exit 2; }

scenario_exists=$(SCENARIO_ID=$scenario yq -r '[.scenarios[] | select(.id == strenv(SCENARIO_ID))] | length' "$scenario_file")
[[ "$scenario_exists" == 1 ]] || { printf 'unknown scenario: %s\n' "$scenario" >&2; exit 2; }
destructive=$(SCENARIO_ID=$scenario yq -r '.scenarios[] | select(.id == strenv(SCENARIO_ID)) | .destructive' "$scenario_file")
claim=$(SCENARIO_ID=$scenario yq -r '.scenarios[] | select(.id == strenv(SCENARIO_ID)) | .claim' "$scenario_file")
action=$(SCENARIO_ID=$scenario yq -r '.scenarios[] | select(.id == strenv(SCENARIO_ID)) | .action' "$scenario_file")

if [[ "$mode" == execute ]]; then
  if [[ "$destructive" == true ]]; then
    [[ "$confirm_context" == "$context" ]] || { printf '%s\n' 'destructive execution requires --confirm-context matching --context' >&2; exit 2; }
    [[ "$confirm_cluster" == "$cluster" ]] || { printf '%s\n' 'destructive execution requires --confirm-cluster matching --cluster' >&2; exit 2; }
    [[ "$confirm_namespace" == "$namespace" ]] || { printf '%s\n' 'destructive execution requires --confirm-namespace matching --namespace' >&2; exit 2; }
  fi
  command -v kubectl >/dev/null 2>&1 || { printf '%s\n' 'kubectl is required for execution' >&2; exit 2; }
  actual_context=$(kubectl config current-context)
  [[ "$actual_context" == "$context" ]] || { printf 'current context %s does not match %s\n' "$actual_context" "$context" >&2; exit 2; }
  actual_cluster=$(kubectl config view --minify --context "$context" -o jsonpath='{.clusters[0].name}')
  [[ "$actual_cluster" == "$cluster" ]] || { printf 'selected context maps to cluster %s, not %s\n' "$actual_cluster" "$cluster" >&2; exit 2; }
  kubectl --context "$context" get namespace "$namespace" >/dev/null
fi

planned="$action"
status=DRY_RUN
target_description=manual

delete_pod() {
  [[ -n "$target_pod" ]] || { printf '%s\n' '--target-pod is required for this scenario' >&2; exit 2; }
  target_description=$target_pod
  planned="delete the explicitly supplied target pod"
  kubectl --context "$context" --namespace "$namespace" delete pod "$target_pod" --wait=false
  status=EXECUTED
}

case "$scenario" in
  active-broker-process-kill)
    [[ -n "$target_pod" ]] || { printf '%s\n' '--target-pod is required for this scenario' >&2; exit 2; }
    target_description=$target_pod
    planned="kill PID 1 in the explicitly supplied active broker pod"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" --namespace "$namespace" exec "$target_pod" -- kill -TERM 1
      status=EXECUTED
    fi
    ;;
  active-broker-pod-delete|zookeeper-one-member-loss)
    target_description=${target_pod:-unspecified}
    [[ "$mode" == execute ]] && delete_pod
    ;;
  zookeeper-quorum-loss)
    [[ "$target_pods" == *,* ]] || { printf '%s\n' '--target-pods must contain at least two comma-separated pods' >&2; exit 2; }
    IFS=',' read -r -a pods <<< "$target_pods"
    ((${#pods[@]} >= 2)) || { printf '%s\n' 'quorum loss requires at least two target pods' >&2; exit 2; }
    target_description=$target_pods
    planned="delete the explicitly supplied ZooKeeper target pods"
    if [[ "$mode" == execute ]]; then
      for pod in "${pods[@]}"; do
        kubectl --context "$context" --namespace "$namespace" delete pod "$pod" --wait=false
      done
      status=EXECUTED
    fi
    ;;
  active-broker-node-drain)
    [[ -n "$target_node" ]] || { printf '%s\n' '--target-node is required for this scenario' >&2; exit 2; }
    [[ "$allow_node_drain" == 1 ]] || { printf '%s\n' '--allow-node-drain is required for node drain' >&2; exit 2; }
    target_description=$target_node
    planned="drain the explicitly supplied node with the broker PDB enforced"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" drain "$target_node" --ignore-daemonsets --grace-period=60 --timeout=15m
      status=EXECUTED
    fi
    ;;
  active-broker-az-loss-guidance)
    [[ -n "$zone" ]] || { printf '%s\n' '--zone is required for AZ simulation guidance' >&2; exit 2; }
    target_description=$zone
    planned="inspect and, under an approved EKS change window, drain all test nodes in the supplied zone"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" get nodes -l "topology.kubernetes.io/zone=$zone" -o name
      status=MANUAL
    fi
    ;;
  broker-replication-isolation|broker-zookeeper-isolation)
    if [[ "$scenario" == broker-replication-isolation ]]; then
      manifest="$manifest_root/replication-isolation-deny.yaml"
    else
      manifest="$manifest_root/zookeeper-isolation-deny.yaml"
    fi
    target_description=$manifest
    if [[ "$cleanup" == 1 ]]; then
      planned="delete temporary network policy $manifest"
      if [[ "$mode" == execute ]]; then
        kubectl --context "$context" --namespace "$namespace" delete -f "$manifest" --ignore-not-found
        status=EXECUTED
      fi
    else
      planned="apply temporary network policy $manifest"
      if [[ "$mode" == execute ]]; then
        kubectl --context "$context" --namespace "$namespace" apply -f "$manifest"
        status=EXECUTED
      fi
    fi
    ;;
  vault-credential-rotation)
    [[ "$rotation_ready" == 1 ]] || { printf '%s\n' '--rotation-ready is required after Vault rotation approval' >&2; exit 2; }
    target_description=$broker_selector
    planned="restart broker stateful pods one at a time after Vault has rendered the rotated credential"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" --namespace "$namespace" rollout restart statefulset --selector "$broker_selector"
      status=EXECUTED
    fi
    ;;
  keycloak-hawtio-authorization)
    [[ "$console_url" =~ ^https?:// ]] || { printf '%s\n' '--console-url must be an http(s) URL' >&2; exit 2; }
    target_description=$console_url
    planned="check that the console returns an authentication challenge or approved redirect"
    if [[ "$mode" == execute ]]; then
      command -v curl >/dev/null 2>&1 || { printf '%s\n' 'curl is required for the console check' >&2; exit 2; }
      http_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 "$console_url")
      case "$http_code" in
        200|301|302|303|307|308|401|403) status=EXECUTED ;;
        *) printf 'unexpected console HTTP status: %s\n' "$http_code" >&2; status=FAIL ;;
      esac
    fi
    ;;
  argo-managed-upgrade-rollback|failed-upgrade-rollback)
    [[ -n "$argo_app" ]] || { printf '%s\n' '--argo-app is required for Argo scenarios' >&2; exit 2; }
    case "$argo_action" in status|sync|rollback) ;; *) printf '%s\n' '--argo-action must be status, sync, or rollback' >&2; exit 2 ;; esac
    target_description=$argo_app
    planned="argocd app $argo_action $argo_app"
    if [[ "$mode" == execute ]]; then
      command -v argocd >/dev/null 2>&1 || { printf '%s\n' 'argocd is required for Argo scenarios' >&2; exit 2; }
      case "$argo_action" in
        status) argocd app get "$argo_app" ;;
        sync) [[ -n "$argo_revision" ]] || { printf '%s\n' '--argo-revision is required for sync' >&2; exit 2; }; argocd app sync "$argo_app" --revision "$argo_revision" ;;
        rollback) [[ -n "$argo_revision" ]] || { printf '%s\n' '--argo-revision is required for rollback' >&2; exit 2; }; argocd app rollback "$argo_app" "$argo_revision" ;;
      esac
      status=EXECUTED
    fi
    ;;
  sustained-load)
    [[ -n "$load_manifest" ]] || { printf '%s\n' '--load-manifest is required to execute load' >&2; exit 2; }
    [[ -f "$load_manifest" ]] || { printf 'load manifest not found: %s\n' "$load_manifest" >&2; exit 2; }
    target_description=$load_manifest
    planned="apply the supplied validation load Job manifest"
    if [[ "$mode" == execute ]]; then
      kubectl --context "$context" --namespace "$namespace" apply -f "$load_manifest"
      status=EXECUTED
    fi
    ;;
  *)
    target_description=manual
    planned="$action"
    if [[ "$mode" == execute ]]; then
      status=MANUAL
      printf '%s\n' 'This scenario is declarative/manual; follow the matching runbook and attach evidence.' >&2
    fi
    ;;
esac

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"
escaped_action=$(printf '%s' "$action" | sed 's/[\\"]/\\&/g')
escaped_planned=$(printf '%s' "$planned" | sed 's/[\\"]/\\&/g')
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","scenario":"%s","claim":"%s","mode":"%s","status":"%s","target":"%s","action":"%s","planned":"%s","rpo":"zero-for-acknowledged-durable","note":"Destructive execution required exact context, cluster, and namespace confirmation."}\n' \
  "$scenario" "$claim" "$mode" "$status" "$target_description" "$escaped_action" "$escaped_planned" > "$report"
printf '%s\n' "scenario=$scenario mode=$mode status=$status"
printf '%s\n' "planned: $planned"
[[ "$status" != FAIL ]]
