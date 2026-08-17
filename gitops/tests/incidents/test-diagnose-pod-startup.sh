#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gitops_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
diagnoser="$gitops_root/scripts/diagnose-pod-startup.sh"
fixture="$test_dir/fixtures/aws-cni-ip-allocation.events.txt"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-pod-startup-test.XXXXXX")
trap 'rm -rf -- "$temp_dir"' EXIT

if "$diagnoser" --events-file "$fixture" >"$temp_dir/diagnosis.out" 2>"$temp_dir/diagnosis.err"; then
  printf '%s\n' 'expected the captured AWS CNI failure to return a failing diagnosis' >&2
  exit 1
else
  exit_code=$?
fi

[[ "$exit_code" -eq 1 ]] || {
  printf 'expected diagnosis exit 1, got %s\n' "$exit_code" >&2
  exit 1
}
grep -Fq 'classification=EKS_VPC_CNI_POD_IP_ALLOCATION_FAILED' "$temp_dir/diagnosis.out"
grep -Fq 'startup_stage=pod-sandbox-network' "$temp_dir/diagnosis.out"
grep -Fq 'application_container_started=false' "$temp_dir/diagnosis.out"
grep -Fq '1. Worker subnet has too few available pod IP addresses.' "$temp_dir/diagnosis.out"
grep -Fq '2. The selected node exhausted its ENI/IP or delegated-prefix capacity.' "$temp_dir/diagnosis.out"
grep -Fq 'Do not restart or delete the ZooKeeper pod as a first response.' "$temp_dir/diagnosis.out"

cat >"$temp_dir/zookeeper-topology.events.txt" <<'EOF'
Warning FailedScheduling default-scheduler 0/4 nodes are available: 2 node(s) didn't match PersistentVolume's node affinity, 2 node(s) didn't match pod topology spread constraints. preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling.
EOF
if "$diagnoser" --events-file "$temp_dir/zookeeper-topology.events.txt" >"$temp_dir/zookeeper-topology.out"; then
  printf '%s\n' 'expected the retained-volume topology conflict to return a failing diagnosis' >&2
  exit 1
else
  exit_code=$?
fi
[[ "$exit_code" -eq 1 ]]
grep -Fq 'classification=ZOOKEEPER_RETAINED_VOLUME_TOPOLOGY_CONFLICT' "$temp_dir/zookeeper-topology.out"
grep -Fq 'Argo CD cannot move an EBS volume' "$temp_dir/zookeeper-topology.out"
grep -Fq 'Fewer than three eligible availability zones' "$temp_dir/zookeeper-topology.out"
grep -Fq "In test, confirm the desired StatefulSet has the repository's" "$temp_dir/zookeeper-topology.out"
grep -Fq 'prod, do not relax DoNotSchedule' "$temp_dir/zookeeper-topology.out"

printf '%s\n' 'Normal Pulled Container image already present' >"$temp_dir/healthy.events.txt"
"$diagnoser" --events-file "$temp_dir/healthy.events.txt" >"$temp_dir/healthy.out"
grep -Fq 'classification=NO_RECOGNIZED_POD_STARTUP_FAILURE' "$temp_dir/healthy.out"

mkdir -p "$temp_dir/bin"
cat >"$temp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$KUBECTL_LOG"
case " $* " in
  *' get events '*)
    if [[ "${MOCK_EVENT_MODE:-cni}" == topology-scaleout ]]; then
      printf '%s\n' "Normal NotTriggerScaleUp cluster-autoscaler pod didn't trigger scale-up: 4 node(s) didn't match pod topology spread constraints"
      printf '%s\n' "Warning FailedScheduling default-scheduler 0/5 nodes are available: 5 node(s) didn't match pod topology spread constraints. preemption: 0/5 nodes are available: 1 node(s) didn't match pod topology spread constraints, 4 No preemption victims found for incoming pod."
    elif [[ "${MOCK_EVENT_MODE:-cni}" == topology ]]; then
      printf '%s\n' "Warning FailedScheduling default-scheduler 0/5 nodes are available: 2 node(s) didn't match pod topology spread constraints, 3 node(s) didn't match PersistentVolume's node affinity."
    else
      printf '%s\n' 'Warning FailedCreatePodSandBox kubelet plugin type="aws-cni" name="aws-cni" failed (add): add cmd: failed to assign an IP address to container'
    fi
    ;;
  *' get pod '*' -o json '*)
    if [[ "${MOCK_EVENT_MODE:-cni}" == topology* ]]; then
      printf '%s\n' '{"metadata":{"labels":{"controller-revision-hash":"rev-old"},"ownerReferences":[{"apiVersion":"apps/v1","kind":"StatefulSet","name":"test-shared-zookeeper-zookeeper","controller":true}]},"spec":{"topologySpreadConstraints":[{"topologyKey":"topology.kubernetes.io/zone","whenUnsatisfiable":"DoNotSchedule"}]},"status":{"phase":"Pending"}}'
    else
      printf '%s\n' '{"metadata":{},"spec":{"nodeName":"ip-10-0-0-10.example.internal"},"status":{"phase":"Pending"}}'
    fi
    ;;
  *' get statefulset '*' -o json '*)
    printf '%s\n' '{"spec":{"updateStrategy":{"type":"RollingUpdate"},"template":{"spec":{"topologySpreadConstraints":[{"topologyKey":"topology.kubernetes.io/zone","whenUnsatisfiable":"ScheduleAnyway"}]}}},"status":{"currentRevision":"rev-old","updateRevision":"rev-new"}}'
    ;;
  *' jsonpath={.spec.nodeName} '*)
    if [[ "${MOCK_EVENT_MODE:-cni}" != topology* ]]; then
      printf '%s' 'ip-10-0-0-10.example.internal'
    fi
    ;;
  *' --selector k8s-app=aws-node --field-selector spec.nodeName=ip-10-0-0-10.example.internal -o name '*)
    printf '%s\n' 'pod/aws-node-example'
    ;;
  *)
    printf '%s\n' 'mock evidence'
    ;;
esac
EOF
chmod 755 "$temp_dir/bin/kubectl"

if PATH="$temp_dir/bin:$PATH" KUBECTL_LOG="$temp_dir/kubectl.log" "$diagnoser" \
  --context test-context \
  --namespace test-platform \
  --pod test-shared-zookeeper-zookeeper-2 >"$temp_dir/live.out"; then
  printf '%s\n' 'expected live captured AWS CNI failure to return exit 1' >&2
  exit 1
else
  exit_code=$?
fi
[[ "$exit_code" -eq 1 ]] || {
  printf 'expected live diagnosis exit 1, got %s\n' "$exit_code" >&2
  exit 1
}
grep -Fq 'classification=EKS_VPC_CNI_POD_IP_ALLOCATION_FAILED' "$temp_dir/live.out"
grep -Fq 'Evidence collection: COMPLETE' "$temp_dir/live.out"
grep -Fq -- '--context test-context --namespace kube-system logs pod/aws-node-example --container aws-node --since=30m --tail=300' "$temp_dir/kubectl.log"
if grep -Eq '(^| )(delete|patch|apply|replace|edit|rollout|scale|drain|cordon|exec)( |$)' "$temp_dir/kubectl.log"; then
  printf '%s\n' 'live diagnosis attempted a mutating kubectl command' >&2
  exit 1
fi

if MOCK_EVENT_MODE=topology PATH="$temp_dir/bin:$PATH" KUBECTL_LOG="$temp_dir/kubectl.log" "$diagnoser" \
  --context test-context \
  --namespace test-platform \
  --pod test-shared-zookeeper-zookeeper-2 >"$temp_dir/stale-topology.out"; then
  printf '%s\n' 'expected stale topology-constrained Pod to return exit 1' >&2
  exit 1
else
  exit_code=$?
fi
[[ "$exit_code" -eq 1 ]]
grep -Fq 'live_state=STALE_STATEFULSET_POD_REVISION' "$temp_dir/stale-topology.out"
grep -Fq 'recovery=DELETE_ONLY_THIS_PENDING_POD' "$temp_dir/stale-topology.out"
grep -Fq 'pod_revision=rev-old' "$temp_dir/stale-topology.out"
grep -Fq 'statefulset_update_revision=rev-new' "$temp_dir/stale-topology.out"
if grep -Eq '(^| )(delete|patch|apply|replace|edit|rollout|scale|drain|cordon|exec)( |$)' "$temp_dir/kubectl.log"; then
  printf '%s\n' 'stale-Pod diagnosis attempted a mutating kubectl command' >&2
  exit 1
fi

if MOCK_EVENT_MODE=topology-scaleout PATH="$temp_dir/bin:$PATH" KUBECTL_LOG="$temp_dir/kubectl.log" "$diagnoser" \
  --context test-context \
  --namespace test-platform \
  --pod test-shared-zookeeper-zookeeper-2 >"$temp_dir/topology-scaleout.out"; then
  printf '%s\n' 'expected topology-blocked autoscaler event to return exit 1' >&2
  exit 1
else
  exit_code=$?
fi
[[ "$exit_code" -eq 1 ]]
grep -Fq 'classification=TOPOLOGY_CONSTRAINT_PREVENTED_SCALE_UP' "$temp_dir/topology-scaleout.out"
grep -Fq 'live_state=STALE_STATEFULSET_POD_REVISION' "$temp_dir/topology-scaleout.out"
grep -Fq 'recovery=DELETE_ONLY_THIS_PENDING_POD' "$temp_dir/topology-scaleout.out"
grep -Fq 'Adding nodes in the same eligible zones will not make this Pod schedulable.' "$temp_dir/topology-scaleout.out"

if "$diagnoser" --events-file "$temp_dir/missing.events.txt" >"$temp_dir/missing.out" 2>&1; then
  printf '%s\n' 'expected a missing events file to fail usage validation' >&2
  exit 1
else
  exit_code=$?
fi
[[ "$exit_code" -eq 2 ]] || {
  printf 'expected missing-file exit 2, got %s\n' "$exit_code" >&2
  exit 1
}

printf '%s\n' 'pod startup diagnosis tests: PASS'
