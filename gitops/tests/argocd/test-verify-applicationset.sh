#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
verifier="$repo_root/scripts/verify-argocd-applicationset.sh"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-applicationset-test.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/bin"

cat > "$temp_dir/bin/kubectl" <<'EOF'
#!/bin/sh
case " $* " in
  *' auth can-i '*)
    if [ "${MOCK_OPERATOR_RBAC_DENIED:-false}" = true ] && \
       echo " $* " | grep -q ' list activemqartemises.broker.amq.io '; then
      printf '%s\n' 'no'
    else
      printf '%s\n' 'yes'
    fi
    ;;
  *' get deployment activemq-artemis-controller-manager-v2 '*)
    if [ "${MOCK_OPERATOR_UNAVAILABLE:-false}" = true ]; then
      available=0
    else
      available=2
    fi
    if [ "${MOCK_OPERATOR_MISSING_TOLERATION:-false}" = true ]; then
      tolerations='[]'
    else
      tolerations='[{"key":"eid-platform/node-lifecycle","operator":"Equal","value":"ondemand","effect":"NoSchedule"}]'
    fi
    if [ "${MOCK_OPERATOR_WATCH_NAMESPACE:-cluster}" = cluster ]; then
      watch_namespace=''
    else
      watch_namespace=$MOCK_OPERATOR_WATCH_NAMESPACE
    fi
    printf '{"spec":{"replicas":2,"template":{"spec":{"tolerations":%s,"containers":[{"name":"manager","env":[{"name":"WATCH_NAMESPACE","value":"%s"}]}]}}},"status":{"availableReplicas":%s}}\n' \
      "$tolerations" "$watch_namespace" "$available"
    ;;
  *' get deployment '*)
    printf '%s\n' '{"spec":{"replicas":1},"status":{"availableReplicas":1}}'
    ;;
  *' get applicationset '*)
    if [ "${MOCK_PARENT_INVALID_SELECTOR:-false}" = true ]; then
      parameters='[{"name":"ha.coordinationId","value":"{{.coordinationId}}"},{"name":"networkPolicy.managementSources[0].namespaceSelector","value":"{}"},{"name":"networkPolicy.managementSources[0].podSelector","value":"{}"}]'
    else
      parameters='[{"name":"ha.coordinationId","value":"{{.coordinationId}}"}]'
    fi
    printf '{"spec":{"template":{"spec":{"source":{"repoURL":"https://example.invalid/artemis.git","targetRevision":"main","path":"gitops/charts/artemis-ha","helm":{"valueFiles":["../../environments/{{.environment}}/artemis-values.yaml"],"parameters":%s}}}}},"status":{"conditions":[{"type":"ResourcesUpToDate","status":"True","message":"ok"}]}}\n' \
      "$parameters"
    ;;
  *' get appproject '*)
    printf '{"spec":{"destinations":[{"server":"https://kubernetes.default.svc","namespace":"%s"}]}}\n' \
      "${MOCK_PROJECT_NAMESPACE:-PLACEHOLDER_TEST_NAMESPACE_SKY}"
    ;;
  *' get activemqartemis '*)
    if [ "${MOCK_BROKER_NO_STATUS:-false}" = true ]; then
      conditions='[]'
    elif [ "${MOCK_BROKER_RESOURCE_ERROR:-false}" = true ]; then
      conditions='[{"type":"Deployed","status":"False","reason":"ResourceError","observedGeneration":3,"message":"StatefulSet creation denied"}]'
    else
      conditions='[{"type":"Valid","status":"True","reason":"ValidationSucceeded","observedGeneration":3,"message":"configuration is valid"},{"type":"Deployed","status":"True","reason":"Deployed","observedGeneration":3,"message":"broker resources created"}]'
    fi
    printf '{"metadata":{"generation":3},"status":{"conditions":%s}}\n' "$conditions"
    ;;
  *' get statefulset '*)
    if [ "${MOCK_STATEFULSET_MISSING:-false}" = true ]; then
      printf '%s\n' 'Error from server (NotFound): statefulset not found' >&2
      exit 1
    fi
    printf '%s\n' '{"spec":{"replicas":2},"status":{"currentReplicas":2,"readyReplicas":2}}'
    ;;
  *' get application '*)
    if [ "${MOCK_INVALID_SPEC:-false}" = true ]; then
      conditions='[{"type":"InvalidSpecError","message":"destination is not permitted"}]'
    elif [ "${MOCK_REPEATED_RESOURCE:-false}" = true ]; then
      conditions='[{"type":"RepeatedResourceWarning","message":"Resource broker.amq.io/ActiveMQArtemis/artemis/int-sky/test-sky-artemis-artemis-ha appeared 2 times among application resources."}]'
    else
      conditions='[]'
    fi
    if [ "${MOCK_PARENT_INVALID_SELECTOR:-false}" = true ]; then
      parameters='[{"name":"ha.coordinationId","value":"test-sky-01"},{"name":"networkPolicy.managementSources[0].namespaceSelector","value":"{}"},{"name":"networkPolicy.managementSources[0].podSelector","value":"{}"}]'
    elif [ "${MOCK_PARAMETER_DRIFT:-false}" = true ]; then
      parameters='[{"name":"ha.coordinationId","value":"test-sky-01"},{"name":"networkPolicy.managementSources[0].namespaceSelector","value":"{}"}]'
    else
      parameters='[{"name":"ha.coordinationId","value":"test-sky-01"}]'
    fi
    path=gitops/charts/artemis-ha
    if [ "${MOCK_SOURCE_DRIFT:-false}" = true ]; then
      path=gitops/charts/duplicate-artemis
    fi
    sources=''
    if [ "${MOCK_MULTI_SOURCE:-false}" = true ]; then
      sources=',"sources":[{"repoURL":"https://example.invalid/artemis.git","path":"gitops/charts/artemis-ha"},{"repoURL":"https://example.invalid/artemis.git","path":"gitops/charts/artemis-ha"}]'
    fi
    printf '{"metadata":{"ownerReferences":[{"kind":"ApplicationSet","name":"test-artemis-workloads"}]},"spec":{"source":{"repoURL":"https://example.invalid/artemis.git","targetRevision":"main","path":"%s","helm":{"valueFiles":["../../environments/test/artemis-values.yaml"],"parameters":%s}}%s,"destination":{"server":"https://kubernetes.default.svc","namespace":"PLACEHOLDER_TEST_NAMESPACE_SKY"}},"status":{"conditions":%s}}\n' \
      "$path" "$parameters" "$sources" "$conditions"
    ;;
  *)
    printf 'unexpected kubectl arguments: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$temp_dir/bin/kubectl"

PATH="$temp_dir/bin:$PATH" \
  "$verifier" \
    --context test-context \
    --argocd-namespace argocd \
    --environment test >"$temp_dir/pass.out"
grep -Fq 'Approved project destination: https://kubernetes.default.svc/PLACEHOLDER_TEST_NAMESPACE_SKY' "$temp_dir/pass.out"
grep -Fq 'ArkMQ operator: available (2/2 replicas)' "$temp_dir/pass.out"
grep -Fq 'ArkMQ operator watch scope: cluster-wide' "$temp_dir/pass.out"
grep -Fq 'Broker reconciliation conditions: PLACEHOLDER_TEST_NAMESPACE_SKY/test-sky-artemis-artemis-ha generation=3' "$temp_dir/pass.out"
grep -Fq 'Broker StatefulSet: PLACEHOLDER_TEST_NAMESPACE_SKY/test-sky-artemis-artemis-ha-ss desired=2 current=2 ready=2' "$temp_dir/pass.out"
grep -Fq 'ApplicationSet verification: PASS (1 enabled broker pairs)' "$temp_dir/pass.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_OPERATOR_UNAVAILABLE=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/operator-unavailable.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted an unavailable ArkMQ operator' >&2
  exit 1
fi
grep -Fq 'ArkMQ operator has 0 available replicas (desired: 2); a synced broker CR cannot produce a StatefulSet until the operator runs' \
  "$temp_dir/operator-unavailable.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_OPERATOR_MISSING_TOLERATION=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/operator-toleration.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted an operator without the platform lifecycle toleration' >&2
  exit 1
fi
grep -Fq 'ArkMQ operator Deployment does not contain exactly one eid-platform/node-lifecycle=ondemand:NoSchedule toleration' \
  "$temp_dir/operator-toleration.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_OPERATOR_WATCH_NAMESPACE=artemis-platform \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/operator-watch-namespace.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted a namespace-scoped ArkMQ operator' >&2
  exit 1
fi
grep -Fq "ArkMQ operator WATCH_NAMESPACE is 'artemis-platform'; this repository requires cluster-wide watch scope" \
  "$temp_dir/operator-watch-namespace.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_OPERATOR_RBAC_DENIED=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/operator-rbac.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted denied ArkMQ operator cluster RBAC' >&2
  exit 1
fi
grep -Fq 'ArkMQ operator authorization denied: list activemqartemises.broker.amq.io at cluster scope (no)' \
  "$temp_dir/operator-rbac.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_PROJECT_NAMESPACE=wrong-namespace \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/project-mismatch.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted a disallowed project destination' >&2
  exit 1
fi
grep -Fq 'does not allow destination https://kubernetes.default.svc namespace PLACEHOLDER_TEST_NAMESPACE_SKY' \
  "$temp_dir/project-mismatch.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_INVALID_SPEC=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/invalid-spec.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted an Application InvalidSpecError' >&2
  exit 1
fi
grep -Fq 'has InvalidSpecError: destination is not permitted' "$temp_dir/invalid-spec.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_MULTI_SOURCE=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/multi-source.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted a generated Application with multiple sources' >&2
  exit 1
fi
grep -Fq 'declares spec.sources with 2 entries; this can render the same ActiveMQArtemis identity more than once' \
  "$temp_dir/multi-source.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_REPEATED_RESOURCE=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/repeated-resource.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted RepeatedResourceWarning' >&2
  exit 1
fi
grep -Fq 'has RepeatedResourceWarning: Resource broker.amq.io/ActiveMQArtemis/artemis/int-sky/test-sky-artemis-artemis-ha appeared 2 times among application resources.' \
  "$temp_dir/repeated-resource.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_BROKER_NO_STATUS=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/broker-no-status.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted a broker CR the operator never processed' >&2
  exit 1
fi
grep -Fq 'has no status conditions; the ArkMQ operator has not processed generation 3' \
  "$temp_dir/broker-no-status.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_BROKER_RESOURCE_ERROR=true \
  MOCK_STATEFULSET_MISSING=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/broker-resource-error.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted a broker ResourceError without a StatefulSet' >&2
  exit 1
fi
grep -Fq 'reconciliation failed: Deployed=False reason=ResourceError: StatefulSet creation denied' \
  "$temp_dir/broker-resource-error.out"
grep -Fq 'has not created expected StatefulSet PLACEHOLDER_TEST_NAMESPACE_SKY/test-sky-artemis-artemis-ha-ss' \
  "$temp_dir/broker-resource-error.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_SOURCE_DRIFT=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/source-drift.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted generated Application source drift' >&2
  exit 1
fi
grep -Fq 'path differs from ApplicationSet test-artemis-workloads' \
  "$temp_dir/source-drift.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_PARAMETER_DRIFT=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/parameter-drift.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted an unmanaged Helm parameter' >&2
  exit 1
fi
grep -Fq 'Helm parameters differ from ApplicationSet test-artemis-workloads; unexpected: networkPolicy.managementSources[0].namespaceSelector' \
  "$temp_dir/parameter-drift.out"

if PATH="$temp_dir/bin:$PATH" \
  MOCK_PARENT_INVALID_SELECTOR=true \
    "$verifier" \
      --context test-context \
      --argocd-namespace argocd \
      --environment test >"$temp_dir/parent-selector.out" 2>&1; then
  printf '%s\n' 'ApplicationSet verifier accepted an empty selector override from its parent' >&2
  exit 1
fi
grep -Fq 'ApplicationSet argocd/test-artemis-workloads declares selector parameters with value {}; Helm parses {} as an array, not an object' \
  "$temp_dir/parent-selector.out"

printf '%s\n' 'ApplicationSet verification tests passed'
