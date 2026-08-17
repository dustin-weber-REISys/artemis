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
grep -Fq 'Argo CD cannot move an EBS volume between zones' "$temp_dir/zookeeper-topology.out"
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
    printf '%s\n' 'Warning FailedCreatePodSandBox kubelet plugin type="aws-cni" name="aws-cni" failed (add): add cmd: failed to assign an IP address to container'
    ;;
  *' jsonpath={.spec.nodeName} '*)
    printf '%s' 'ip-10-0-0-10.example.internal'
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
