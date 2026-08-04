#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
report="$repo_root/reports/static-validation.json"

while (($#)); do
  case "$1" in
    --report) report=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

errors=0
required_files='
Makefile
local/Makefile
local/compose.yaml
local/.env.example
local/scripts/validate-compose.sh
gitops/Makefile
gitops/scripts/validate-topology.sh
gitops/tests/topology/test.sh
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
    "$repo_root/gitops/tests/e2e/manifests/zookeeper-isolation-deny.yaml"; do
    yq -e '.' "$yaml_file" >/dev/null || {
      printf 'invalid YAML: %s\n' "${yaml_file#"$repo_root/"}" >&2
      errors=$((errors + 1))
    }
  done

  assert_yaml_value() {
    local label=$1
    local expression=$2
    local yaml_file=$3
    local expected=$4
    local actual
    actual=$(yq -r "$expression" "$yaml_file")
    if [[ "$actual" != "$expected" ]]; then
      printf '%s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
      errors=$((errors + 1))
    fi
  }

  for environment in test nonprod; do
    assert_yaml_value "$environment operator ECR repository" \
      '.arkmq-org-broker-operator.controllerManager.manager.image.repository' \
      "$repo_root/gitops/environments/$environment/operator-values.yaml" \
      'PLACEHOLDER_NONPROD_ECR_REGISTRY/PLACEHOLDER_NONPROD_ECR_REPOSITORY/arkmq-operator'
    assert_yaml_value "$environment operator init-image ECR repository" \
      '.arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerInitRepository' \
      "$repo_root/gitops/environments/$environment/operator-values.yaml" \
      'PLACEHOLDER_NONPROD_ECR_REGISTRY/PLACEHOLDER_NONPROD_ECR_REPOSITORY/activemq-artemis-broker-init'
    assert_yaml_value "$environment operator broker-image ECR repository" \
      '.arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerKubernetesRepository' \
      "$repo_root/gitops/environments/$environment/operator-values.yaml" \
      'PLACEHOLDER_NONPROD_ECR_REGISTRY/PLACEHOLDER_NONPROD_ECR_REPOSITORY/activemq-artemis-broker-kubernetes'
    assert_yaml_value "$environment broker ECR repository" \
      '.images.broker.repository' \
      "$repo_root/gitops/environments/$environment/artemis-values.yaml" \
      'PLACEHOLDER_NONPROD_ECR_REGISTRY/PLACEHOLDER_NONPROD_ECR_REPOSITORY/activemq-artemis-broker-kubernetes'
    assert_yaml_value "$environment init ECR repository" \
      '.images.init.repository' \
      "$repo_root/gitops/environments/$environment/artemis-values.yaml" \
      'PLACEHOLDER_NONPROD_ECR_REGISTRY/PLACEHOLDER_NONPROD_ECR_REPOSITORY/activemq-artemis-broker-init'
    assert_yaml_value "$environment ZooKeeper ECR image" \
      '.image.registry + "/" + .image.repository' \
      "$repo_root/gitops/environments/$environment/zookeeper-values.yaml" \
      'PLACEHOLDER_NONPROD_ECR_REGISTRY/PLACEHOLDER_NONPROD_ECR_REPOSITORY/zookeeper'
  done

  assert_yaml_value 'prod operator ECR repository' \
    '.arkmq-org-broker-operator.controllerManager.manager.image.repository' \
    "$repo_root/gitops/environments/prod/operator-values.yaml" \
    'PLACEHOLDER_PROD_ECR_REGISTRY/PLACEHOLDER_PROD_ECR_REPOSITORY/arkmq-operator'
  assert_yaml_value 'prod operator init-image ECR repository' \
    '.arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerInitRepository' \
    "$repo_root/gitops/environments/prod/operator-values.yaml" \
    'PLACEHOLDER_PROD_ECR_REGISTRY/PLACEHOLDER_PROD_ECR_REPOSITORY/activemq-artemis-broker-init'
  assert_yaml_value 'prod operator broker-image ECR repository' \
    '.arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerKubernetesRepository' \
    "$repo_root/gitops/environments/prod/operator-values.yaml" \
    'PLACEHOLDER_PROD_ECR_REGISTRY/PLACEHOLDER_PROD_ECR_REPOSITORY/activemq-artemis-broker-kubernetes'
  assert_yaml_value 'prod broker ECR repository' \
    '.images.broker.repository' \
    "$repo_root/gitops/environments/prod/artemis-values.yaml" \
    'PLACEHOLDER_PROD_ECR_REGISTRY/PLACEHOLDER_PROD_ECR_REPOSITORY/activemq-artemis-broker-kubernetes'
  assert_yaml_value 'prod init ECR repository' \
    '.images.init.repository' \
    "$repo_root/gitops/environments/prod/artemis-values.yaml" \
    'PLACEHOLDER_PROD_ECR_REGISTRY/PLACEHOLDER_PROD_ECR_REPOSITORY/activemq-artemis-broker-init'
  assert_yaml_value 'prod ZooKeeper ECR image' \
    '.image.registry + "/" + .image.repository' \
    "$repo_root/gitops/environments/prod/zookeeper-values.yaml" \
    'PLACEHOLDER_PROD_ECR_REGISTRY/PLACEHOLDER_PROD_ECR_REPOSITORY/zookeeper'
else
  printf '%s\n' 'yq unavailable; YAML syntax checks skipped' >&2
fi

if command -v kubeconform >/dev/null 2>&1; then
  kubeconform -strict -summary -ignore-missing-schemas \
    "$repo_root/gitops/tests/e2e/manifests/replication-isolation-deny.yaml" \
    "$repo_root/gitops/tests/e2e/manifests/zookeeper-isolation-deny.yaml" || {
      printf '%s\n' 'temporary isolation manifests failed kubeconform' >&2
      errors=$((errors + 1))
    }
fi

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
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"static-invariants","status":"%s","errors":%d}\n' \
  "$status" "$errors" > "$report"
printf '%s\n' "static validation: $status ($errors errors)"
[[ "$errors" -eq 0 ]]
