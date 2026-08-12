#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
report="$repo_root/reports/static-validation.json"
schema_mode=${ARTEMIS_SCHEMA_MODE:-offline}
kubernetes_version=${ARTEMIS_KUBERNETES_VERSION:-}

while (($#)); do
  case "$1" in
    --report) report=$2; shift 2 ;;
    --schema-mode) schema_mode=$2; shift 2 ;;
    --kubernetes-version) kubernetes_version=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done


case "$schema_mode" in
  offline) schema_status=NOT_RUN ;;
  network)
    schema_status=PASS
    ;;
  *) printf 'invalid schema mode: %s\n' "$schema_mode" >&2; exit 2 ;;
esac

if [[ "$schema_mode" == network && -z "$kubernetes_version" && -f "$repo_root/gitops/releases/current.yaml" ]] && command -v yq >/dev/null 2>&1; then
  kubernetes_version=$(yq -r '.platform.kubernetesVersion // ""' "$repo_root/gitops/releases/current.yaml")
fi
if [[ "$schema_mode" == network && -z "$kubernetes_version" ]]; then
  printf '%s\n' 'network schema mode requires --kubernetes-version or platform.kubernetesVersion in gitops/releases/current.yaml' >&2
  exit 2
fi

errors=0
required_files='
Makefile
local/Makefile
local/compose.yaml
local/.env.example
local/scripts/validate-compose.sh
gitops/Makefile
gitops/releases/current.yaml
gitops/kustomize/arkmq-operator/base/kustomization.yaml
gitops/kustomize/arkmq-operator/base/values.yaml
gitops/kustomize/arkmq-operator/base/deployment-identity.patch.yaml
gitops/kustomize/arkmq-operator/overlays/test/kustomization.yaml
gitops/kustomize/arkmq-operator/overlays/nonprod/kustomization.yaml
gitops/kustomize/arkmq-operator/overlays/prod/kustomization.yaml
gitops/kustomize/zookeeper/base/kustomization.yaml
gitops/kustomize/zookeeper/base/statefulset.yaml
gitops/kustomize/zookeeper/base/networkpolicy.yaml
gitops/kustomize/zookeeper/overlays/test/kustomization.yaml
gitops/kustomize/zookeeper/overlays/nonprod/kustomization.yaml
gitops/kustomize/zookeeper/overlays/prod/kustomization.yaml
gitops/kustomize/zookeeper/tests/test.sh
gitops/argocd/bootstrap/base/kustomization.yaml
gitops/argocd/bootstrap/base/project.yaml
gitops/argocd/bootstrap/base/operator-application.yaml
gitops/argocd/bootstrap/base/zookeeper-application.yaml
gitops/argocd/bootstrap/base/artemis-workloads-applicationset.yaml
gitops/argocd/bootstrap/test/kustomization.yaml
gitops/argocd/bootstrap/nonprod/kustomization.yaml
gitops/argocd/bootstrap/prod/kustomization.yaml
gitops/argocd/baseline-policy.yaml
gitops/argocd/profiles/standard/profile.yaml
gitops/argocd/profiles/standard/values.yaml
gitops/scripts/validate-topology.sh
gitops/scripts/validate-rendered-schema.sh
gitops/scripts/render-arkmq-operator.sh
gitops/scripts/verify-argocd-applicationset.sh
gitops/scripts/refresh-argocd-ecr-credential.sh
gitops/scripts/diagnose-pod-startup.sh
gitops/tests/topology/test.sh
gitops/tests/argocd/test-ecr-credential-refresh.sh
gitops/tests/argocd/test-verify-applicationset.sh
gitops/tests/incidents/test-diagnose-pod-startup.sh
gitops/tests/incidents/fixtures/aws-cni-ip-allocation.events.txt
gitops/tests/e2e/acceptance-plan.yaml
gitops/tests/e2e/test-scenario-tools.sh
gitops/tests/compatibility/classic-6.2.6-inventory.yaml
gitops/tests/e2e/manifests/replication-isolation-deny.yaml
gitops/tests/e2e/manifests/zookeeper-isolation-deny.yaml
performance/Makefile
performance/build-local-image.sh
performance/client/Dockerfile
performance/client/Dockerfile.local
performance/client/Dockerfile.prebuilt
performance/client/pom.xml
performance/profiles/sustained-load-profiles.yaml
performance/run-profile.sh
performance/run-failure-test.sh
performance/test-failure-script.sh
'
for relative_file in $required_files; do
  if [[ ! -f "$repo_root/$relative_file" ]]; then
    printf 'missing required file: %s\n' "$relative_file" >&2
    errors=$((errors + 1))
  fi
done

if command -v yq >/dev/null 2>&1; then
  for yaml_file in \
    "$repo_root/local/compose.yaml" \
    "$repo_root/gitops/tests/compatibility/classic-6.2.6-inventory.yaml" \
    "$repo_root/performance/profiles/sustained-load-profiles.yaml" \
    "$repo_root/gitops/tests/chart/validation-policy.yaml" \
    "$repo_root/gitops/tests/e2e/manifests/replication-isolation-deny.yaml" \
    "$repo_root/gitops/tests/e2e/manifests/zookeeper-isolation-deny.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/base/kustomization.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/base/values.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/base/pdb.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/overlays/test/kustomization.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/overlays/test/private-images.patch.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/overlays/nonprod/kustomization.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/overlays/nonprod/private-images.patch.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/overlays/prod/kustomization.yaml" \
    "$repo_root/gitops/kustomize/arkmq-operator/overlays/prod/private-images.patch.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/base/kustomization.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/base/serviceaccount.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/base/services.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/base/statefulset.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/base/networkpolicy.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/base/pdb.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/base/servicemonitor.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/base/prometheusrule.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/test/kustomization.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/test/statefulset.patch.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/test/integrations.patch.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/nonprod/kustomization.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/nonprod/statefulset.patch.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/nonprod/integrations.patch.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/prod/kustomization.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/prod/statefulset.patch.yaml" \
    "$repo_root/gitops/kustomize/zookeeper/overlays/prod/integrations.patch.yaml" \
    "$repo_root/gitops/argocd/bootstrap/base/kustomization.yaml" \
    "$repo_root/gitops/argocd/bootstrap/base/project.yaml" \
    "$repo_root/gitops/argocd/bootstrap/base/operator-application.yaml" \
    "$repo_root/gitops/argocd/bootstrap/base/zookeeper-application.yaml" \
    "$repo_root/gitops/argocd/bootstrap/base/artemis-workloads-applicationset.yaml" \
    "$repo_root/gitops/argocd/bootstrap/test/kustomization.yaml" \
    "$repo_root/gitops/argocd/bootstrap/test/cluster.patch.yaml" \
    "$repo_root/gitops/argocd/bootstrap/nonprod/kustomization.yaml" \
    "$repo_root/gitops/argocd/bootstrap/nonprod/cluster.patch.yaml" \
    "$repo_root/gitops/argocd/bootstrap/prod/kustomization.yaml" \
    "$repo_root/gitops/argocd/bootstrap/prod/cluster.patch.yaml" \
    "$repo_root/gitops/argocd/baseline-policy.yaml" \
    "$repo_root/gitops/argocd/profiles/standard/profile.yaml" \
    "$repo_root/gitops/argocd/profiles/standard/values.yaml"; do
    yq -e '.' "$yaml_file" >/dev/null || {
      printf 'invalid YAML: %s\n' "${yaml_file#"$repo_root/"}" >&2
      errors=$((errors + 1))
    }
  done

  assert_yaml_pattern() {
    local label=$1
    local expression=$2
    local yaml_file=$3
    local expected_pattern=$4
    local actual
    actual=$(yq -r "$expression" "$yaml_file")
    if [[ ! "$actual" =~ $expected_pattern ]]; then
      printf '%s: value does not match required pattern: %s\n' "$label" "$expected_pattern" >&2
      errors=$((errors + 1))
    fi
  }

  assert_yaml_pattern 'ZooKeeper release image digest' \
    '.spec.template.spec.containers[] | select(.name == "zookeeper") | .image // ""' \
    "$repo_root/gitops/kustomize/zookeeper/base/statefulset.yaml" \
    '@sha256:[0-9a-f]{64}$'

  assert_yaml_pattern 'ArkMQ Kustomize chart OCI repository' \
    '.helmCharts[0].repo // ""' \
    "$repo_root/gitops/kustomize/arkmq-operator/base/kustomization.yaml" \
    '^oci://quay[.]io/arkmq-org/helm-charts$'

  if rg -n '^[[:space:]]*(image|images|tag|digest):' "$repo_root/gitops/environments" >/dev/null; then
    printf '%s\n' 'environment values must not contain image locations or release pins' >&2
    errors=$((errors + 1))
  fi
else
  printf '%s\n' 'yq unavailable; YAML syntax checks skipped' >&2
fi

schema_args=(--mode "$schema_mode")
if [[ -n "$kubernetes_version" ]]; then
  schema_args+=(--kubernetes-version "$kubernetes_version")
fi
"$repo_root/gitops/scripts/validate-rendered-schema.sh" \
  "${schema_args[@]}" \
  "$repo_root/gitops/tests/e2e/manifests/replication-isolation-deny.yaml" \
  "$repo_root/gitops/tests/e2e/manifests/zookeeper-isolation-deny.yaml" || {
    printf '%s\n' 'temporary isolation manifests failed Kubernetes schema validation' >&2
    errors=$((errors + 1))
    schema_status=FAIL
  }

dockerfile="$repo_root/performance/client/Dockerfile"
if [[ -f "$dockerfile" ]]; then
  grep -Eq '^ARG BUILD_IMAGE_DIGEST$' "$dockerfile" || { printf '%s\n' 'Dockerfile must require BUILD_IMAGE_DIGEST' >&2; errors=$((errors + 1)); }
  grep -Eq '^ARG RUNTIME_IMAGE_DIGEST$' "$dockerfile" || { printf '%s\n' 'Dockerfile must require RUNTIME_IMAGE_DIGEST' >&2; errors=$((errors + 1)); }
  grep -Eq '^FROM \$\{BUILD_IMAGE\}@\$\{BUILD_IMAGE_DIGEST\}' "$dockerfile" || { printf '%s\n' 'build stage is not digest-pinned' >&2; errors=$((errors + 1)); }
  grep -Eq '^FROM \$\{RUNTIME_IMAGE\}@\$\{RUNTIME_IMAGE_DIGEST\}' "$dockerfile" || { printf '%s\n' 'runtime stage is not digest-pinned' >&2; errors=$((errors + 1)); }
  grep -Eq '^USER 65532:65532$' "$dockerfile" || { printf '%s\n' 'runtime image must run as non-root UID 65532' >&2; errors=$((errors + 1)); }
fi

makefile="$repo_root/performance/Makefile"
grep -q 'BUILD_IMAGE_DIGEST' "$makefile" || { printf '%s\n' 'Makefile must pass build image digest' >&2; errors=$((errors + 1)); }
grep -q 'RUNTIME_IMAGE_DIGEST' "$makefile" || { printf '%s\n' 'Makefile must pass runtime image digest' >&2; errors=$((errors + 1)); }

if command -v rg >/dev/null 2>&1; then
  if rg -n --hidden --glob '!/.git/**' --glob '!reports/**' \
      'AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{20,}' \
      "$repo_root/performance" "$repo_root/gitops" "$repo_root/local" "$repo_root/scripts" >/dev/null; then
    printf '%s\n' 'credential-shaped value detected in owned validation files' >&2
    errors=$((errors + 1))
  fi
fi

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"
status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"static-invariants","status":"%s","errors":%d,"schemaMode":"%s","schemaValidation":"%s"}\n' \
  "$status" "$errors" "$schema_mode" "$schema_status" > "$report"
printf '%s\n' "static validation: $status ($errors errors; Kubernetes schema: $schema_status/$schema_mode)"
[[ "$errors" -eq 0 ]]
