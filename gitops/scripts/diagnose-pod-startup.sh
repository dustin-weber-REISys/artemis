#!/usr/bin/env bash
set -uo pipefail

events_file=
context=
namespace=
pod=
kube_system_namespace=kube-system
collection_failures=0

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
  command -v kubectl >/dev/null 2>&1 || { printf '%s\n' 'kubectl is required in live mode' >&2; exit 2; }
  if ! events=$(kubectl --context "$context" --namespace "$namespace" get events \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=$pod" \
    --sort-by=.metadata.creationTimestamp 2>&1); then
    printf 'could not collect events for Pod %s/%s:\n%s\n' "$namespace" "$pod" "$events" >&2
    exit 2
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

classification_exit=0
if grep -Fq 'failed to assign an IP address to container' <<<"$events" &&
   grep -Fq 'plugin type="aws-cni"' <<<"$events"; then
  print_aws_cni_diagnosis
  classification_exit=1
elif grep -Eq 'FailedCreatePodSandBox|FailedCreatePodSandbox' <<<"$events"; then
  cat <<'DIAGNOSIS'
classification=POD_SANDBOX_CREATION_FAILED_OTHER
startup_stage=pod-sandbox
application_container_started=false

The application container did not start. Inspect the complete sandbox event
and the node's CNI daemon before collecting application logs.
DIAGNOSIS
  classification_exit=1
elif grep -Eq 'FailedScheduling|[Uu]nschedulable' <<<"$events"; then
  cat <<'DIAGNOSIS'
classification=POD_SCHEDULING_FAILED
startup_stage=scheduling
application_container_started=false

The pod has not reached a node. Inspect the scheduler event for placement,
taint, topology, PVC binding, or resource-capacity constraints.
DIAGNOSIS
  classification_exit=1
elif grep -Eq 'ErrImagePull|ImagePullBackOff|Failed to pull image' <<<"$events"; then
  cat <<'DIAGNOSIS'
classification=CONTAINER_IMAGE_PULL_FAILED
startup_stage=image-pull
application_container_started=false

The pod reached a node but the image was not available. Inspect the exact image
reference, registry reachability, node architecture, and image-pull credentials.
DIAGNOSIS
  classification_exit=1
elif grep -Eq 'FailedMount|FailedAttachVolume|FailedBinding' <<<"$events"; then
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
