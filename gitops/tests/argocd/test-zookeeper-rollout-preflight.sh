#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gitops_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
preflight="$gitops_root/scripts/check-zookeeper-rollout.sh"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-zookeeper-rollout-test.XXXXXX")
trap 'rm -rf -- "$temp_dir"' EXIT
snapshot_dir="$temp_dir/snapshot"
mkdir -p "$snapshot_dir" "$temp_dir/bin"

cat >"$snapshot_dir/statefulset.json" <<'EOF'
{
  "metadata":{"name":"test-shared-zookeeper-zookeeper","generation":1},
  "spec":{
    "replicas":3,
    "selector":{"matchLabels":{"app.kubernetes.io/instance":"test-shared-zookeeper"}},
    "template":{"spec":{
      "affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"topologyKey":"kubernetes.io/hostname"}]}},
      "topologySpreadConstraints":[{"maxSkew":1,"topologyKey":"topology.kubernetes.io/zone","whenUnsatisfiable":"ScheduleAnyway"}]
    }},
    "volumeClaimTemplates":[{"metadata":{"name":"data"}}]
  },
  "status":{"readyReplicas":3,"currentRevision":"rev-1","updateRevision":"rev-1","observedGeneration":1}
}
EOF

cat >"$snapshot_dir/pods.json" <<'EOF'
{"items":[
  {"metadata":{"name":"test-shared-zookeeper-zookeeper-0"},"spec":{"nodeName":"node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
  {"metadata":{"name":"test-shared-zookeeper-zookeeper-1"},"spec":{"nodeName":"node-b"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
  {"metadata":{"name":"test-shared-zookeeper-zookeeper-2"},"spec":{"nodeName":"node-c"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}
]}
EOF

cat >"$snapshot_dir/pvcs.json" <<'EOF'
{"items":[
  {"metadata":{"name":"data-test-shared-zookeeper-zookeeper-0"},"spec":{"volumeName":"pv-a","storageClassName":"gp3"},"status":{"phase":"Bound"}},
  {"metadata":{"name":"data-test-shared-zookeeper-zookeeper-1"},"spec":{"volumeName":"pv-b","storageClassName":"gp3"},"status":{"phase":"Bound"}},
  {"metadata":{"name":"data-test-shared-zookeeper-zookeeper-2"},"spec":{"volumeName":"pv-c","storageClassName":"gp3"},"status":{"phase":"Bound"}}
]}
EOF

cat >"$snapshot_dir/pvs.json" <<'EOF'
{"items":[
  {"metadata":{"name":"pv-a"},"spec":{"nodeAffinity":{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"topology.ebs.csi.aws.com/zone","values":["zone-a"]}]}]}}}},
  {"metadata":{"name":"pv-b"},"spec":{"nodeAffinity":{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"topology.ebs.csi.aws.com/zone","values":["zone-b"]}]}]}}}},
  {"metadata":{"name":"pv-c"},"spec":{"nodeAffinity":{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"topology.ebs.csi.aws.com/zone","values":["zone-c"]}]}]}}}}
]}
EOF

cat >"$snapshot_dir/nodes.json" <<'EOF'
{"items":[
  {"metadata":{"name":"node-a","labels":{"topology.kubernetes.io/zone":"zone-a"}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
  {"metadata":{"name":"node-b","labels":{"topology.kubernetes.io/zone":"zone-b"}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
  {"metadata":{"name":"node-c","labels":{"topology.kubernetes.io/zone":"zone-c"}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
  {"metadata":{"name":"node-d","labels":{"topology.kubernetes.io/zone":"zone-b"}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}
]}
EOF

printf '%s\n' '{"items":[{"metadata":{"name":"gp3"},"volumeBindingMode":"WaitForFirstConsumer"}]}' >"$snapshot_dir/storageclasses.json"
printf '%s\n' '{"spec":{"maxUnavailable":1}}' >"$snapshot_dir/pdb.json"
printf '%s\n' '{"spec":{"syncPolicy":{"automated":{"enabled":false}}},"status":{"health":{"status":"Healthy"},"sync":{"status":"OutOfSync"},"operationState":{"phase":"Succeeded"}}}' >"$snapshot_dir/application.json"

cat >"$temp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$KUBECTL_LOG"
case " $* " in
  *' get statefulset '*) file=statefulset.json ;;
  *' get pods '*) file=pods.json ;;
  *' get pvc '*) file=pvcs.json ;;
  *' get pv '*) file=pvs.json ;;
  *' get nodes '*) file=nodes.json ;;
  *' get storageclass '*) file=storageclasses.json ;;
  *' get poddisruptionbudget '*) file=pdb.json ;;
  *' get application '*) file=application.json ;;
  *) printf 'unexpected kubectl call: %s\n' "$*" >&2; exit 2 ;;
esac
cat "$SNAPSHOT_DIR/$file"
EOF
chmod 755 "$temp_dir/bin/kubectl"

run_preflight() {
  local environment=${1:-test}
  PATH="$temp_dir/bin:$PATH" \
  KUBECTL=kubectl \
  KUBECTL_LOG="$temp_dir/kubectl.log" \
  SNAPSHOT_DIR="$snapshot_dir" \
    "$preflight" --context test-context --environment "$environment"
}

if ! run_preflight >"$temp_dir/pass.out"; then
  cat "$temp_dir/pass.out" >&2
  printf '%s\n' 'expected healthy three-zone snapshot to pass rollout preflight' >&2
  exit 1
fi
grep -Fq 'READY: ZooKeeper baseline is ready' "$temp_dir/pass.out"
grep -Fq 'best-effort three-zone spread policy is active for test' "$temp_dir/pass.out"
grep -Fq 'retained voter volumes occupy 3 distinct availability zones' "$temp_dir/pass.out"
grep -Fq 'ZooKeeper automatic sync is disabled' "$temp_dir/pass.out"

jq '(.spec.template.spec.topologySpreadConstraints[0].minDomains) = 3' \
  "$snapshot_dir/statefulset.json" >"$snapshot_dir/statefulset-invalid.json"
mv "$snapshot_dir/statefulset-invalid.json" "$snapshot_dir/statefulset.json"
if run_preflight >"$temp_dir/invalid-spread.out"; then
  printf '%s\n' 'expected ScheduleAnyway with minDomains to fail rollout preflight' >&2
  exit 1
else
  exit_code=$?
fi
[[ "$exit_code" -eq 1 ]]
grep -Fq 'invalid or unexpected ScheduleAnyway zone-spread constraint' "$temp_dir/invalid-spread.out"
jq 'del(.spec.template.spec.topologySpreadConstraints[0].minDomains)' \
  "$snapshot_dir/statefulset.json" >"$snapshot_dir/statefulset-valid.json"
mv "$snapshot_dir/statefulset-valid.json" "$snapshot_dir/statefulset.json"

jq '(.items[] | select(.metadata.name == "pv-c")
  | .spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]) = "zone-b"' \
  "$snapshot_dir/pvs.json" >"$snapshot_dir/pvs-duplicate.json"
mv "$snapshot_dir/pvs-duplicate.json" "$snapshot_dir/pvs.json"
jq '(.items[] | select(.metadata.name == "test-shared-zookeeper-zookeeper-2")
  | .spec.nodeName) = "node-d"' \
  "$snapshot_dir/pods.json" >"$snapshot_dir/pods-duplicate.json"
mv "$snapshot_dir/pods-duplicate.json" "$snapshot_dir/pods.json"

if ! run_preflight >"$temp_dir/test-duplicate.out"; then
  cat "$temp_dir/test-duplicate.out" >&2
  printf '%s\n' 'expected test best-effort spread to accept duplicate retained-volume zones' >&2
  exit 1
fi
grep -Fq 'retained test voter volumes occupy 2 distinct zones' "$temp_dir/test-duplicate.out"
grep -Fq 'current test voters occupy 2 distinct zones' "$temp_dir/test-duplicate.out"
grep -Fq 'READY:' "$temp_dir/test-duplicate.out"

for snapshot in statefulset.json pods.json pvcs.json; do
  sed 's/test-shared/nonprod-shared/g' "$snapshot_dir/$snapshot" >"$snapshot_dir/$snapshot.nonprod"
  mv "$snapshot_dir/$snapshot.nonprod" "$snapshot_dir/$snapshot"
done
jq '(.spec.template.spec.topologySpreadConstraints[0].whenUnsatisfiable) = "DoNotSchedule" |
  (.spec.template.spec.topologySpreadConstraints[0].minDomains) = 3' \
  "$snapshot_dir/statefulset.json" >"$snapshot_dir/statefulset-hard.json"
mv "$snapshot_dir/statefulset-hard.json" "$snapshot_dir/statefulset.json"

if run_preflight nonprod >"$temp_dir/fail.out"; then
  printf '%s\n' 'expected duplicate retained-volume zones to block a nonprod rollout' >&2
  exit 1
else
  exit_code=$?
fi
[[ "$exit_code" -eq 1 ]]
grep -Fq 'retained voter volumes occupy 2 distinct zones; 3 are required' "$temp_dir/fail.out"
grep -Fq 'BLOCKED:' "$temp_dir/fail.out"

if grep -Eq '(^| )(delete|patch|apply|replace|edit|rollout|scale|drain|cordon|exec|sync)( |$)' "$temp_dir/kubectl.log"; then
  printf '%s\n' 'ZooKeeper rollout preflight attempted a mutating kubectl command' >&2
  exit 1
fi

printf '%s\n' 'ZooKeeper rollout preflight tests: PASS'
