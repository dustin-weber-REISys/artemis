#!/usr/bin/env bash
set -uo pipefail

context=
environment=
namespace=artemis-platform
argocd_namespace=argocd
statefulset=
application=
kubectl_bin=${KUBECTL:-kubectl}
errors=0

usage() {
  cat <<'USAGE'
Usage:
  check-zookeeper-rollout.sh \
    --context CONTEXT --environment test|nonprod|prod \
    [--namespace artemis-platform] [--argocd-namespace argocd]

Performs read-only checks before a controlled Argo CD ZooKeeper sync. It
validates the stable three-voter baseline, retained PVC/PV availability-zone
placement, eligible node capacity, WaitForFirstConsumer storage, disruption
budget, environment placement policy, and the Argo CD Application state.

No resource is patched, deleted, restarted, synced, or otherwise mutated.
USAGE
}

require_value() {
  [[ -n "${2-}" ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
}

while (($#)); do
  case "$1" in
    --context) require_value "$1" "${2-}"; context=$2; shift 2 ;;
    --environment) require_value "$1" "${2-}"; environment=$2; shift 2 ;;
    --namespace) require_value "$1" "${2-}"; namespace=$2; shift 2 ;;
    --argocd-namespace) require_value "$1" "${2-}"; argocd_namespace=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$context" ]] || { printf '%s\n' '--context is required' >&2; exit 2; }
case "$environment" in
  test|nonprod|prod) ;;
  '') printf '%s\n' '--environment is required' >&2; exit 2 ;;
  *) printf 'unsupported environment: %s\n' "$environment" >&2; exit 2 ;;
esac
for command_name in "$kubectl_bin" jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done

statefulset="${environment}-shared-zookeeper-zookeeper"
application="${environment}-shared-zookeeper"

collect() {
  local description=$1
  shift
  local output
  if ! output=$("$kubectl_bin" --context "$context" "$@" 2>&1); then
    printf 'could not collect %s:\n%s\n' "$description" "$output" >&2
    exit 2
  fi
  printf '%s' "$output"
}

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1"
  errors=$((errors + 1))
}

warn() {
  printf 'WARN  %s\n' "$1"
}

section() {
  printf '\n%s\n' "$1"
}

statefulset_json=$(collect "StatefulSet $namespace/$statefulset" \
  --namespace "$namespace" get statefulset "$statefulset" -o json)
selector=$(jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' \
  <<<"$statefulset_json")
[[ -n "$selector" ]] || { printf '%s\n' 'StatefulSet selector is empty' >&2; exit 2; }

pods_json=$(collect 'ZooKeeper Pods' \
  --namespace "$namespace" get pods --selector "$selector" -o json)
pvcs_json=$(collect 'platform PVCs' --namespace "$namespace" get pvc -o json)
pvs_json=$(collect 'persistent volumes' get pv -o json)
nodes_json=$(collect 'cluster nodes' get nodes -o json)
storageclasses_json=$(collect 'storage classes' get storageclass -o json)
pdb_json=$(collect "PodDisruptionBudget $namespace/$statefulset" \
  --namespace "$namespace" get poddisruptionbudget "$statefulset" -o json)
application_json=$(collect "Argo CD Application $argocd_namespace/$application" \
  --namespace "$argocd_namespace" get application "$application" -o json)

section 'StatefulSet and quorum baseline'
replicas=$(jq -r '.spec.replicas // 0' <<<"$statefulset_json")
ready_replicas=$(jq -r '.status.readyReplicas // 0' <<<"$statefulset_json")
current_revision=$(jq -r '.status.currentRevision // ""' <<<"$statefulset_json")
update_revision=$(jq -r '.status.updateRevision // ""' <<<"$statefulset_json")
observed_generation=$(jq -r '.status.observedGeneration // 0' <<<"$statefulset_json")
generation=$(jq -r '.metadata.generation // 0' <<<"$statefulset_json")

[[ "$replicas" -eq 3 ]] && pass 'StatefulSet requests exactly three voters' || \
  fail "StatefulSet requests $replicas voters; the supported quorum size is 3"
[[ "$ready_replicas" -eq "$replicas" ]] && pass "all $replicas voters are Ready" || \
  fail "only $ready_replicas of $replicas voters are Ready; do not start another rollout"
[[ -n "$current_revision" && "$current_revision" == "$update_revision" ]] && \
  pass "StatefulSet is stable at revision $current_revision" || \
  fail "StatefulSet rollout is already in progress (current=$current_revision update=$update_revision)"
[[ "$observed_generation" -ge "$generation" ]] && pass 'StatefulSet controller observed the current generation' || \
  fail "StatefulSet generation $generation has not been observed (observed=$observed_generation)"

pod_count=$(jq '.items | length' <<<"$pods_json")
ready_pod_count=$(jq '[.items[] | select(
  .metadata.deletionTimestamp == null and
  any(.status.conditions[]?; .type == "Ready" and .status == "True")
)] | length' <<<"$pods_json")
[[ "$pod_count" -eq "$replicas" && "$ready_pod_count" -eq "$replicas" ]] && \
  pass 'all voter Pods exist, are not terminating, and report Ready' || \
  fail "Pod baseline is not stable (pods=$pod_count ready=$ready_pod_count expected=$replicas)"

expected_zone_schedule=DoNotSchedule
if [[ "$environment" == test ]]; then
  expected_zone_schedule=ScheduleAnyway
fi
spread_ok=$(jq --arg schedule "$expected_zone_schedule" -r '[.spec.template.spec.topologySpreadConstraints[]? | select(
  .topologyKey == "topology.kubernetes.io/zone" and
  .maxSkew == 1 and .whenUnsatisfiable == $schedule and
  (($schedule == "DoNotSchedule" and .minDomains == 3) or
   ($schedule == "ScheduleAnyway" and (has("minDomains") | not)))
)] | length' <<<"$statefulset_json")
host_anti_affinity_ok=$(jq -r '[
  .spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[]?
  | select(.topologyKey == "kubernetes.io/hostname")
] | length' <<<"$statefulset_json")
if [[ "$spread_ok" -eq 1 ]]; then
  if [[ "$environment" == test ]]; then
    pass 'best-effort three-zone spread policy is active for test'
  else
    pass 'hard one-per-zone spread policy is active'
  fi
else
  fail "StatefulSet has an invalid or unexpected $expected_zone_schedule zone-spread constraint"
fi
[[ "$host_anti_affinity_ok" -ge 1 ]] && pass 'hard one-per-node anti-affinity is active' || \
  fail 'StatefulSet does not enforce required hostname anti-affinity'

section 'Persistent-volume placement'
declare -a pv_zones=()
checked_storageclasses='|'
claim_templates=$(jq -r '.spec.volumeClaimTemplates[].metadata.name' <<<"$statefulset_json")
while IFS= read -r claim_template; do
  [[ -n "$claim_template" ]] || continue
  for ((ordinal=0; ordinal<replicas; ordinal++)); do
    pvc_name="${claim_template}-${statefulset}-${ordinal}"
    pvc=$(PVC_NAME="$pvc_name" jq -c '.items[] | select(.metadata.name == env.PVC_NAME)' <<<"$pvcs_json")
    if [[ -z "$pvc" ]]; then
      fail "PVC $namespace/$pvc_name does not exist"
      continue
    fi
    phase=$(jq -r '.status.phase // ""' <<<"$pvc")
    pv_name=$(jq -r '.spec.volumeName // ""' <<<"$pvc")
    storageclass=$(jq -r '.spec.storageClassName // ""' <<<"$pvc")
    if [[ "$phase" != Bound || -z "$pv_name" ]]; then
      fail "PVC $pvc_name is not Bound (phase=${phase:-unknown})"
      continue
    fi
    pv=$(PV_NAME="$pv_name" jq -c '.items[] | select(.metadata.name == env.PV_NAME)' <<<"$pvs_json")
    if [[ -z "$pv" ]]; then
      fail "bound PV $pv_name for PVC $pvc_name was not returned"
      continue
    fi
    volume_zones=()
    while IFS= read -r volume_zone; do
      [[ -n "$volume_zone" ]] && volume_zones+=("$volume_zone")
    done < <(jq -r '
      [.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?
       | select(.key | test("(^|/)zone$")) | .values[]?] | unique[]
    ' <<<"$pv")
    if [[ "${#volume_zones[@]}" -ne 1 ]]; then
      fail "PV $pv_name must resolve to exactly one availability zone (found ${#volume_zones[@]})"
      continue
    fi
    zone=${volume_zones[0]}
    pv_zones+=("$zone")
    printf 'INFO  ordinal=%s pvc=%s pv=%s zone=%s\n' "$ordinal" "$pvc_name" "$pv_name" "$zone"

    node_count=$(ZONE="$zone" jq '[.items[] | select(
      .spec.unschedulable != true and
      .metadata.labels["topology.kubernetes.io/zone"] == env.ZONE and
      any(.status.conditions[]?; .type == "Ready" and .status == "True")
    )] | length' <<<"$nodes_json")
    [[ "$node_count" -ge 1 ]] || fail "PV zone $zone has no Ready, schedulable node"

    pod_name="${statefulset}-${ordinal}"
    pod_node=$(POD_NAME="$pod_name" jq -r '.items[] | select(.metadata.name == env.POD_NAME) | .spec.nodeName // ""' \
      <<<"$pods_json")
    if [[ -n "$pod_node" ]]; then
      pod_zone=$(NODE_NAME="$pod_node" jq -r '.items[] | select(.metadata.name == env.NODE_NAME) | .metadata.labels["topology.kubernetes.io/zone"] // ""' \
        <<<"$nodes_json")
      [[ "$pod_zone" == "$zone" ]] || \
        fail "Pod $pod_name is in zone ${pod_zone:-unknown}, but its PV is restricted to $zone"
    fi

    if [[ -n "$storageclass" && "$checked_storageclasses" != *"|$storageclass|"* ]]; then
      checked_storageclasses="${checked_storageclasses}${storageclass}|"
      binding_mode=$(SC_NAME="$storageclass" jq -r '.items[] | select(.metadata.name == env.SC_NAME) | .volumeBindingMode // ""' \
        <<<"$storageclasses_json")
      [[ "$binding_mode" == WaitForFirstConsumer ]] && \
        pass "StorageClass $storageclass uses WaitForFirstConsumer" || \
        fail "StorageClass $storageclass uses ${binding_mode:-unknown}; require WaitForFirstConsumer"
    fi
  done
done <<<"$claim_templates"

unique_pv_zones=$(printf '%s\n' "${pv_zones[@]-}" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
if [[ "$unique_pv_zones" -eq "$replicas" ]]; then
  pass "retained voter volumes occupy $unique_pv_zones distinct availability zones"
elif [[ "$environment" == test ]]; then
  warn "retained test voter volumes occupy $unique_pv_zones distinct zones; ScheduleAnyway permits recovery but zone-loss quorum is reduced"
else
  fail "retained voter volumes occupy $unique_pv_zones distinct zones; $replicas are required before a hard three-zone rollout"
fi

running_zones=$(jq -r --slurpfile nodes <(printf '%s' "$nodes_json") '[
  .items[] | select(.spec.nodeName != null) | .spec.nodeName as $name
  | $nodes[0].items[] | select(.metadata.name == $name)
  | .metadata.labels["topology.kubernetes.io/zone"]
] | unique | length' <<<"$pods_json")
if [[ "$running_zones" -eq "$replicas" ]]; then
  pass 'current voters occupy three distinct availability zones'
elif [[ "$environment" == test ]]; then
  warn "current test voters occupy $running_zones distinct zones; member loss remains tolerated but some zone loss can remove quorum"
else
  fail "current voters occupy $running_zones distinct zones; do not restart a voter"
fi

section 'Disruption and Argo CD gates'
max_unavailable=$(jq -r '.spec.maxUnavailable // ""' <<<"$pdb_json")
[[ "$max_unavailable" == 1 ]] && pass 'PodDisruptionBudget permits at most one unavailable voter' || \
  fail "PodDisruptionBudget maxUnavailable is ${max_unavailable:-unset}; expected 1"

automated_enabled=$(jq -r '
  if (.spec.syncPolicy.automated | type) == "object" and
     (.spec.syncPolicy.automated | has("enabled"))
  then .spec.syncPolicy.automated.enabled
  else true
  end
' <<<"$application_json")
health=$(jq -r '.status.health.status // "Unknown"' <<<"$application_json")
sync_status=$(jq -r '.status.sync.status // "Unknown"' <<<"$application_json")
operation_phase=$(jq -r '.status.operationState.phase // ""' <<<"$application_json")
[[ "$automated_enabled" == false ]] && pass 'ZooKeeper automatic sync is disabled' || \
  fail 'ZooKeeper automatic sync is enabled; a Git change could restart a voter before preflight'
[[ "$health" == Healthy ]] && pass 'Argo CD reports the ZooKeeper Application Healthy' || \
  fail "Argo CD Application health is $health"
case "$operation_phase" in
  ''|Succeeded) pass 'no failed or running Argo CD operation is active' ;;
  *) fail "Argo CD operation phase is $operation_phase" ;;
esac
printf 'INFO  Argo CD sync status=%s\n' "$sync_status"

section 'Result'
if ((errors > 0)); then
  printf 'BLOCKED: %d rollout preflight check(s) failed. Do not sync %s.\n' "$errors" "$application"
  if [[ "$environment" == test ]]; then
    printf '%s\n' 'Correct readiness, storage, or node capacity first. The desired test StatefulSet must retain ScheduleAnyway and hard hostname anti-affinity.'
  else
    printf '%s\n' 'Correct node/AZ capacity or migrate one retained voter volume at a time under the ZooKeeper recovery runbook; do not relax quorum placement.'
  fi
  exit 1
fi

printf 'READY: ZooKeeper baseline is ready for a controlled one-voter-at-a-time StatefulSet rollout.\n'
printf 'Next: review the Argo diff, sync %s without selective sync, and wait for Healthy before promotion.\n' "$application"
