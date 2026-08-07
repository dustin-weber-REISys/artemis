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
gitops/charts/arkmq-operator/values.yaml
gitops/scripts/validate-topology.sh
gitops/scripts/verify-argocd-applicationset.sh
gitops/scripts/refresh-argocd-ecr-credential.sh
gitops/tests/topology/test.sh
gitops/tests/argocd/test-ecr-credential-refresh.sh
gitops/tests/argocd/test-verify-applicationset.sh
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
    '.image.digest // ""' \
    "$repo_root/gitops/charts/zookeeper/values.yaml" \
    '^sha256:[0-9a-f]{64}$'
  assert_yaml_pattern 'operator release image digest' \
    '."arkmq-org-broker-operator".controllerManager.manager.image.tag // ""' \
    "$repo_root/gitops/charts/arkmq-operator/values.yaml" \
    '^2[.]2[.]0@sha256:[0-9a-f]{64}$'

  if rg -n '^[[:space:]]*(image|images|tag|digest):' "$repo_root/gitops/environments" >/dev/null; then
    printf '%s\n' 'environment values must not contain image locations or release pins' >&2
    errors=$((errors + 1))
  fi
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
