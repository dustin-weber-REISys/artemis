#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gitops_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
verifier="$gitops_root/scripts/verify-argocd-applicationset.sh"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-health-test.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/bin"

cat > "$temp_dir/bin/kubectl" <<'EOF'
#!/bin/sh
case " $* " in
  *' get deployment argocd-applicationset-controller '*)
    printf '%s\n' '{"spec":{"replicas":1},"status":{"availableReplicas":1}}'
    ;;
  *' get deployment activemq-artemis-controller-manager-v2 '*)
    available=2
    [ "${MOCK_OPERATOR_UNAVAILABLE:-false}" = true ] && available=0
    printf '{"spec":{"replicas":2},"status":{"availableReplicas":%s}}\n' "$available"
    ;;
  *' get applicationset '*)
    if [ "${MOCK_APPLICATIONSET_ERROR:-false}" = true ]; then
      conditions='[{"type":"ErrorOccurred","status":"True","message":"template failed"}]'
    else
      conditions='[{"type":"ResourcesUpToDate","status":"True","message":"ok"}]'
    fi
    printf '{"status":{"conditions":%s}}\n' "$conditions"
    ;;
  *' get appproject '*)
    namespace=${MOCK_PROJECT_NAMESPACE:-PLACEHOLDER_TEST_NAMESPACE_SKY}
    printf '{"spec":{"destinations":[{"server":"https://kubernetes.default.svc","namespace":"%s"}]}}\n' "$namespace"
    ;;
  *' get application test-arkmq-operator '*)
    health=Healthy
    [ "${MOCK_OPERATOR_UNHEALTHY:-false}" = true ] && health=Degraded
    printf '{"spec":{"destination":{"server":"https://kubernetes.default.svc","namespace":"PLACEHOLDER_PLATFORM_NAMESPACE"}},"status":{"sync":{"status":"Synced","revision":"%s"},"health":{"status":"%s"},"conditions":[]}}\n' \
      "${MOCK_OPERATOR_REVISION:-remote-operator-revision}" "$health"
    ;;
  *' get application test-sky-artemis '*)
    if [ "${MOCK_REPEATED_RESOURCE:-false}" = true ]; then
      conditions='[{"type":"RepeatedResourceWarning","message":"duplicate broker identity"}]'
    else
      conditions='[]'
    fi
    printf '{"metadata":{"name":"test-sky-artemis","ownerReferences":[{"kind":"ApplicationSet","name":"test-artemis-workloads"}]},"spec":{"source":{"helm":{"releaseName":"test-sky-artemis"}},"destination":{"server":"https://kubernetes.default.svc","namespace":"PLACEHOLDER_TEST_NAMESPACE_SKY"}},"status":{"sync":{"status":"Synced","revision":"%s"},"health":{"status":"Healthy"},"conditions":%s}}\n' \
      "${MOCK_WORKLOAD_REVISION:-remote-workload-revision}" "$conditions"
    ;;
  *' get activemqartemis test-sky-artemis-artemis-ha '*)
    if [ "${MOCK_BROKER_NO_STATUS:-false}" = true ]; then
      conditions='[]'
    elif [ "${MOCK_BROKER_FAILED:-false}" = true ]; then
      conditions='[{"type":"Deployed","status":"False","reason":"ResourceError","observedGeneration":3,"message":"StatefulSet denied"}]'
    else
      conditions='[{"type":"Valid","status":"True","reason":"ValidationSucceeded","observedGeneration":3},{"type":"Deployed","status":"True","reason":"Deployed","observedGeneration":3}]'
    fi
    printf '{"metadata":{"generation":3},"status":{"conditions":%s}}\n' "$conditions"
    ;;
  *' get statefulset test-sky-artemis-artemis-ha-ss '*)
    ready=2
    [ "${MOCK_STATEFULSET_UNREADY:-false}" = true ] && ready=1
    printf '{"spec":{"replicas":2},"status":{"currentReplicas":2,"readyReplicas":%s}}\n' "$ready"
    ;;
  *)
    printf 'unexpected kubectl arguments: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$temp_dir/bin/kubectl"

run_verifier() {
  PATH="$temp_dir/bin:$PATH" "$verifier" \
    --context test-context \
    --argocd-namespace argocd \
    --environment test
}

run_verifier >"$temp_dir/pass.out"
grep -Fq 'Application test-arkmq-operator: Synced/Healthy revision=remote-operator-revision' "$temp_dir/pass.out"
grep -Fq 'Application test-sky-artemis: Synced/Healthy revision=remote-workload-revision' "$temp_dir/pass.out"
grep -Fq 'Broker StatefulSet PLACEHOLDER_TEST_NAMESPACE_SKY/test-sky-artemis-artemis-ha-ss: desired=2 current=2 ready=2' "$temp_dir/pass.out"
grep -Fq 'Live Artemis health: PASS (1 enabled broker pairs)' "$temp_dir/pass.out"

# A workstation checkout revision is deliberately irrelevant to live health.
MOCK_OPERATOR_REVISION=not-local-head \
MOCK_WORKLOAD_REVISION=also-not-local-head \
  run_verifier >"$temp_dir/remote-revision.out"
grep -Fq 'revision=not-local-head' "$temp_dir/remote-revision.out"
grep -Fq 'revision=also-not-local-head' "$temp_dir/remote-revision.out"
grep -Fq 'Live Artemis health: PASS' "$temp_dir/remote-revision.out"

assert_failure() {
  name=$1
  expected=$2
  shift 2
  if "$@" >"$temp_dir/$name.out" 2>&1; then
    printf 'expected failure for %s\n' "$name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$temp_dir/$name.out"
}

assert_failure operator-unavailable \
  'ArkMQ operator has 0 available replicas (desired: 2)' \
  env PATH="$temp_dir/bin:$PATH" MOCK_OPERATOR_UNAVAILABLE=true "$verifier" \
    --context test-context --argocd-namespace argocd --environment test

assert_failure operator-unhealthy \
  'Application argocd/test-arkmq-operator health is Degraded; expected Healthy' \
  env PATH="$temp_dir/bin:$PATH" MOCK_OPERATOR_UNHEALTHY=true "$verifier" \
    --context test-context --argocd-namespace argocd --environment test

assert_failure repeated-resource \
  'RepeatedResourceWarning: duplicate broker identity' \
  env PATH="$temp_dir/bin:$PATH" MOCK_REPEATED_RESOURCE=true "$verifier" \
    --context test-context --argocd-namespace argocd --environment test

assert_failure applicationset-error \
  'ApplicationSet argocd/test-artemis-workloads reports: template failed' \
  env PATH="$temp_dir/bin:$PATH" MOCK_APPLICATIONSET_ERROR=true "$verifier" \
    --context test-context --argocd-namespace argocd --environment test

assert_failure broker-no-status \
  'has no status conditions; operator has not processed generation 3' \
  env PATH="$temp_dir/bin:$PATH" MOCK_BROKER_NO_STATUS=true "$verifier" \
    --context test-context --argocd-namespace argocd --environment test

assert_failure broker-failed \
  'reconciliation failed: Deployed=False reason=ResourceError: StatefulSet denied' \
  env PATH="$temp_dir/bin:$PATH" MOCK_BROKER_FAILED=true "$verifier" \
    --context test-context --argocd-namespace argocd --environment test

assert_failure statefulset-unready \
  'has 1/2 ready replicas' \
  env PATH="$temp_dir/bin:$PATH" MOCK_STATEFULSET_UNREADY=true "$verifier" \
    --context test-context --argocd-namespace argocd --environment test

assert_failure project-destination \
  'does not allow https://kubernetes.default.svc namespace PLACEHOLDER_TEST_NAMESPACE_SKY' \
  env PATH="$temp_dir/bin:$PATH" MOCK_PROJECT_NAMESPACE=wrong-namespace "$verifier" \
    --context test-context --argocd-namespace argocd --environment test

printf '%s\n' 'Live Artemis health tests passed'
