#!/usr/bin/env bash
set -uo pipefail

events_file=
context=
namespace=
pod=
kube_system_namespace=kube-system
collection_failures=0
pod_json=
statefulset_json=
owner_statefulset=

usage() {
  cat <<'USAGE'
Usage:
  diagnose-pod-startup.sh --events-file FILE
  diagnose-pod-startup.sh \
    --context CONTEXT --namespace NAMESPACE --pod POD \
    [--kube-system-namespace NAMESPACE]

Classify pod-startup events. File mode replays previously captured events and
does not contact a cluster. Live mode performs read-only kubectl queries for the
pod, its node, and the AWS VPC CNI daemon on that node.

Exit codes:
  0  no recognized startup failure
  1  a recognized startup failure was found
  2  invalid input or evidence could not be collected
USAGE
}

require_value() {
  [[ -n "${2-}" ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
}

while (($#)); do
  case "$1" in
    --events-file) require_value "$1" "${2-}"; events_file=$2; shift 2 ;;
    --context) require_value "$1" "${2-}"; context=$2; shift 2 ;;
    --namespace) require_value "$1" "${2-}"; namespace=$2; shift 2 ;;
    --pod) require_value "$1" "${2-}"; pod=$2; shift 2 ;;
    --kube-system-namespace) require_value "$1" "${2-}"; kube_system_namespace=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

live_mode=0
if [[ -n "$events_file" ]]; then
  [[ -z "$context" && -z "$namespace" && -z "$pod" ]] || {
    printf '%s\n' '--events-file cannot be combined with live-cluster options' >&2
    exit 2
  }
  [[ -f "$events_file" ]] || { printf 'events file not found: %s\n' "$events_file" >&2; exit 2; }
  events=$(<"$events_file")
else
  live_mode=1
  [[ -n "$context" ]] || { printf '%s\n' '--context is required in live mode' >&2; exit 2; }
  [[ -n "$namespace" ]] || { printf '%s\n' '--namespace is required in live mode' >&2; exit 2; }
  [[ -n "$pod" ]] || { printf '%s\n' '--pod is required in live mode' >&2; exit 2; }
  for command_name in kubectl jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf '%s is required in live mode\n' "$command_name" >&2
      exit 2
    }
  done
  if ! events=$(kubectl --context "$context" --namespace "$namespace" get events \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=$pod" \
    --sort-by=.metadata.creationTimestamp 2>&1); then
    printf 'could not collect events for Pod %s/%s:\n%s\n' "$namespace" "$pod" "$events" >&2
    exit 2
  fi
  if ! pod_json=$(kubectl --context "$context" --namespace "$namespace" get pod "$pod" -o json 2>&1); then
    printf 'could not collect Pod %s/%s:\n%s\n' "$namespace" "$pod" "$pod_json" >&2
    exit 2
  fi
  owner_statefulset=$(jq -r '
    [.metadata.ownerReferences[]? | select(.kind == "StatefulSet" and .controller == true) | .name][0] // ""
  ' <<<"$pod_json")
  if [[ -n "$owner_statefulset" ]]; then
    if ! statefulset_json=$(kubectl --context "$context" --namespace "$namespace" \
      get statefulset "$owner_statefulset" -o json 2>&1); then
      printf 'could not collect StatefulSet %s/%s:\n%s\n' \
        "$namespace" "$owner_statefulset" "$statefulset_json" >&2
      exit 2
    fi
  fi
fi

print_aws_cni_diagnosis() {
  cat <<'DIAGNOSIS'
classification=EKS_VPC_CNI_POD_IP_ALLOCATION_FAILED
startup_stage=pod-sandbox-network
application_container_started=false
owner_boundary=EKS/platform-networking

The kubelet asked the AWS VPC CNI to create the pod network, but IPAM could not
assign an address. PVC attachment can succeed before this step; neither result
tests the ZooKeeper image, configuration, probes, DNS, or quorum.

Ranked hypotheses and discriminating evidence:
1. Worker subnet has too few available pod IP addresses.
   Check the node's subnet AvailableIpAddressCount and whether failures span
   nodes in the same subnet/AZ.
2. The selected node exhausted its ENI/IP or delegated-prefix capacity.
   Compare scheduled pod count and CNI allocation state on this node with a
   healthy node of the same instance type.
3. The node's aws-node/IPAM daemon is unhealthy or cannot call the EC2 API.
   Check aws-node readiness and recent logs for EC2 API, IAM, timeout, or IPAM
   allocation errors while subnet capacity is still available.
4. The node has stale local CNI state.
   Consider this only after subnet, node capacity, and aws-node/API health are
   shown healthy; failures should be isolated to this node.

Do not restart or delete the ZooKeeper pod as a first response. Kubernetes will
keep retrying sandbox creation, and a restart does not create IP capacity.
DIAGNOSIS
}

print_live_statefulset_topology_comparison() {
  if [[ "$live_mode" -eq 1 && -n "$statefulset_json" ]]; then
    local pod_phase pod_revision pod_zone_schedule update_strategy
    local current_revision update_revision desired_zone_schedule
    pod_phase=$(jq -r '.status.phase // "Unknown"' <<<"$pod_json")
    pod_revision=$(jq -r '.metadata.labels["controller-revision-hash"] // ""' <<<"$pod_json")
    pod_zone_schedule=$(jq -r '[.spec.topologySpreadConstraints[]? |
      select(.topologyKey == "topology.kubernetes.io/zone") | .whenUnsatisfiable] | join(",")' \
      <<<"$pod_json")
    update_strategy=$(jq -r '.spec.updateStrategy.type // "RollingUpdate"' <<<"$statefulset_json")
    current_revision=$(jq -r '.status.currentRevision // ""' <<<"$statefulset_json")
    update_revision=$(jq -r '.status.updateRevision // ""' <<<"$statefulset_json")
    desired_zone_schedule=$(jq -r '[.spec.template.spec.topologySpreadConstraints[]? |
      select(.topologyKey == "topology.kubernetes.io/zone") | .whenUnsatisfiable] | join(",")' \
      <<<"$statefulset_json")

    printf '\nLive StatefulSet comparison:\n'
    printf 'pod_phase=%s\n' "$pod_phase"
    printf 'pod_revision=%s\n' "${pod_revision:-unset}"
    printf 'pod_zone_schedule=%s\n' "${pod_zone_schedule:-unset}"
    printf 'statefulset_current_revision=%s\n' "${current_revision:-unset}"
    printf 'statefulset_update_revision=%s\n' "${update_revision:-unset}"
    printf 'statefulset_desired_zone_schedule=%s\n' "${desired_zone_schedule:-unset}"

    if [[ "$pod_phase" == Pending && "$update_strategy" == RollingUpdate &&
          "$pod_zone_schedule" == *DoNotSchedule* &&
          "$desired_zone_schedule" == *ScheduleAnyway* &&
          -n "$pod_revision" && -n "$update_revision" && "$pod_revision" != "$update_revision" ]]; then
      printf '%s\n' 'live_state=STALE_STATEFULSET_POD_REVISION'
      printf '%s\n' 'recovery=DELETE_ONLY_THIS_PENDING_POD'
      printf '%s\n' 'The StatefulSet has the corrected template, but this Pending Pod still has the previous hard constraint.'
      printf 'After reviewing this evidence, recreate only this Pending ordinal with:\n'
      printf 'kubectl --context %q --namespace %q delete pod %q\n' "$context" "$namespace" "$pod"
      printf '%s\n' 'Do not delete its PVC, force-delete the Pod, or restart another voter.'
    elif [[ "$desired_zone_schedule" == *DoNotSchedule* ]]; then
      printf '%s\n' 'live_state=STATEFULSET_POLICY_NOT_UPDATED'
      printf '%s\n' 'recovery=FIX_ARGO_TARGET_REVISION_OR_SYNC'
    elif [[ "$pod_zone_schedule" == *DoNotSchedule* && "$pod_revision" == "$update_revision" ]]; then
      printf '%s\n' 'live_state=POD_SPEC_DIFFERS_FROM_MATCHING_STATEFULSET_REVISION'
      printf '%s\n' 'recovery=CHECK_ADMISSION_MUTATION'
    elif [[ "$pod_zone_schedule" == *ScheduleAnyway* ]]; then
      printf '%s\n' 'live_state=CURRENT_POD_POLICY_IS_SOFT'
      printf '%s\n' 'recovery=CHECK_EVENT_TIMESTAMPS_AND_OTHER_CONSTRAINTS'
    else
      printf '%s\n' 'live_state=INCONCLUSIVE_REVISION_COMPARISON'
      printf '%s\n' 'recovery=COLLECT_CONTROLLER_AND_ADMISSION_EVENTS'
    fi
  elif [[ "$live_mode" -eq 1 ]]; then
    printf '%s\n' 'live_state=POD_HAS_NO_STATEFULSET_CONTROLLER_OWNER'
    printf '%s\n' 'recovery=VERIFY_WORKLOAD_OWNERSHIP'
  fi
}

classification_exit=0
classification=NO_RECOGNIZED_POD_STARTUP_FAILURE
if grep -Eq "NotTriggerScaleUp|didn't trigger scale-up" <<<"$events" &&
   grep -Fq "didn't match pod topology spread constraints" <<<"$events"; then
  classification=TOPOLOGY_CONSTRAINT_PREVENTED_SCALE_UP
  cat <<'DIAGNOSIS'
classification=TOPOLOGY_CONSTRAINT_PREVENTED_SCALE_UP
startup_stage=scheduling
application_container_started=false
owner_boundary=Kubernetes-scheduling-and-node-autoscaling

Cluster Autoscaler evaluated its node groups and concluded that scale-out
would not satisfy this Pod's topology-spread constraint.
Adding nodes in the same eligible zones will not make this Pod schedulable.
Desired capacity is therefore not increased. This is different from an Auto
Scaling Group launch failure.

For the two-AZ test cluster, the desired ZooKeeper StatefulSet must use the
repository's ScheduleAnyway zone policy while retaining hard hostname
anti-affinity. Compare this Pending Pod's immutable spec and controller
revision with the current StatefulSet template before changing node capacity.
DIAGNOSIS
  print_live_statefulset_topology_comparison
  classification_exit=1
elif grep -Fq "didn't match PersistentVolume's node affinity" <<<"$events" &&
   grep -Fq "didn't match pod topology spread constraints" <<<"$events"; then
  classification=ZOOKEEPER_RETAINED_VOLUME_TOPOLOGY_CONFLICT
  cat <<'DIAGNOSIS'
classification=ZOOKEEPER_RETAINED_VOLUME_TOPOLOGY_CONFLICT
startup_stage=scheduling
application_container_started=false
owner_boundary=EKS/storage-and-node-topology

The replacement pod can run only in the availability zone of its retained
volume, and its current Pod spec contains a hard topology-spread constraint
that rejects the compatible nodes. Argo CD cannot move an EBS volume between
zones or repair an already-created Pod spec by retrying the sync.

Most likely causes:
1. Fewer than three eligible availability zones currently have worker capacity.
2. The three retained ZooKeeper volumes are not distributed one per zone.
3. A node-pool label, taint, toleration, or capacity change made a volume's zone
   ineligible even though the volume remains bound there.

Run the read-only ZooKeeper rollout preflight and do not delete a PVC or restart
another voter. In test, confirm the desired StatefulSet has the repository's
ScheduleAnyway policy and apply it through a reviewed Argo sync. In nonprod or
prod, do not relax DoNotSchedule: restore eligible per-zone capacity and, if
necessary, migrate one retained voter volume at a time under a reviewed
ZooKeeper recovery procedure.
DIAGNOSIS
  print_live_statefulset_topology_comparison
  classification_exit=1
elif grep -Fq 'failed to assign an IP address to container' <<<"$events" &&
   grep -Fq 'plugin type="aws-cni"' <<<"$events"; then
  classification=EKS_VPC_CNI_POD_IP_ALLOCATION_FAILED
  print_aws_cni_diagnosis
  classification_exit=1
elif grep -Eq 'FailedCreatePodSandBox|FailedCreatePodSandbox' <<<"$events"; then
  classification=POD_SANDBOX_CREATION_FAILED_OTHER
  cat <<'DIAGNOSIS'
classification=POD_SANDBOX_CREATION_FAILED_OTHER
startup_stage=pod-sandbox
application_container_started=false

The application container did not start. Inspect the complete sandbox event
and the node's CNI daemon before collecting application logs.
DIAGNOSIS
  classification_exit=1
elif grep -Eq 'FailedScheduling|[Uu]nschedulable' <<<"$events"; then
  classification=POD_SCHEDULING_FAILED
  cat <<'DIAGNOSIS'
classification=POD_SCHEDULING_FAILED
startup_stage=scheduling
application_container_started=false

The pod has not reached a node. Inspect the scheduler event for placement,
taint, topology, PVC binding, or resource-capacity constraints.
DIAGNOSIS
  classification_exit=1
elif grep -Eq 'ErrImagePull|ImagePullBackOff|Failed to pull image' <<<"$events"; then
  classification=CONTAINER_IMAGE_PULL_FAILED
  cat <<'DIAGNOSIS'
classification=CONTAINER_IMAGE_PULL_FAILED
startup_stage=image-pull
application_container_started=false

The pod reached a node but the image was not available. Inspect the exact image
reference, registry reachability, node architecture, and image-pull credentials.
DIAGNOSIS
  classification_exit=1
elif grep -Eq 'FailedMount|FailedAttachVolume|FailedBinding' <<<"$events"; then
  classification=POD_STORAGE_PRESTART_FAILED
  cat <<'DIAGNOSIS'
classification=POD_STORAGE_PRESTART_FAILED
startup_stage=storage
application_container_started=false

The pod is blocked before application startup by volume binding, attachment, or
mounting. Preserve the PVC/PV identity and inspect CSI and node events.
DIAGNOSIS
  classification_exit=1
else
  printf '%s\n' 'classification=NO_RECOGNIZED_POD_STARTUP_FAILURE'
  printf '%s\n' 'Inspect container status, probe failures, and application logs next.'
fi

if [[ "$live_mode" -eq 0 ]]; then
  exit "$classification_exit"
fi

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
    collection_failures=$((collection_failures + 1))
    printf '[command failed with exit %s; collection continued]\n' "$exit_code"
    return 0
  fi
}

section 'pod events used for classification'
printf '%s\n' "$events"

section 'pod and node placement'
capture kubectl --context "$context" --namespace "$namespace" get pod "$pod" -o wide
capture kubectl --context "$context" --namespace "$namespace" describe pod "$pod"
node=$(kubectl --context "$context" --namespace "$namespace" get pod "$pod" \
  -o 'jsonpath={.spec.nodeName}' 2>/dev/null || true)

if [[ -z "$node" ]]; then
  printf '%s\n' 'Pod has no assigned node; node-local CNI evidence is unavailable.'
else
  section 'selected node capacity'
  capture kubectl --context "$context" get node "$node" -o wide
  capture kubectl --context "$context" describe node "$node"

  section 'AWS VPC CNI status and non-secret tuning'
  capture kubectl --context "$context" --namespace "$kube_system_namespace" get daemonset aws-node -o wide
  capture kubectl --context "$context" --namespace "$kube_system_namespace" get pods \
    --selector k8s-app=aws-node --field-selector "spec.nodeName=$node" -o wide
  capture kubectl --context "$context" --namespace "$kube_system_namespace" get daemonset aws-node \
    -o 'jsonpath={range .spec.template.spec.containers[?(@.name=="aws-node")].env[*]}{.name}={.value}{"\n"}{end}'

  aws_node_resource=$(kubectl --context "$context" --namespace "$kube_system_namespace" get pods \
    --selector k8s-app=aws-node --field-selector "spec.nodeName=$node" -o name 2>/dev/null || true)
  aws_node_resource=$(sed -n '1p' <<<"$aws_node_resource")
  if [[ -n "$aws_node_resource" ]]; then
    section 'AWS VPC CNI recent logs'
    capture kubectl --context "$context" --namespace "$kube_system_namespace" logs \
      "$aws_node_resource" --container aws-node --since=30m --tail=300
  else
    collection_failures=$((collection_failures + 1))
    printf 'No aws-node pod was found on node %s.\n' "$node"
  fi
fi

section reminder
printf '%s\n' 'Review output for account IDs, instance IDs, IPs, hostnames, and internal endpoints before sharing.'
if ((collection_failures > 0)); then
  printf 'Evidence collection: PARTIAL (%d command failures)\n' "$collection_failures"
  exit 2
fi
printf '%s\n' 'Evidence collection: COMPLETE'
exit "$classification_exit"
