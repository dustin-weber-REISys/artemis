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
required_files='Makefile images/test-client/Dockerfile images/test-client/pom.xml tests/e2e/scenarios.yaml tests/compatibility/classic-6.2.6-inventory.yaml tests/load/sustained-load.yaml tests/e2e/manifests/replication-isolation-deny.yaml tests/e2e/manifests/zookeeper-isolation-deny.yaml'
for relative_file in $required_files; do
  if [[ ! -f "$repo_root/$relative_file" ]]; then
    printf 'missing required file: %s\n' "$relative_file" >&2
    errors=$((errors + 1))
  fi
done

if command -v yq >/dev/null 2>&1; then
  for yaml_file in "$repo_root/tests/compatibility/classic-6.2.6-inventory.yaml" "$repo_root/tests/load/sustained-load.yaml" "$repo_root/tests/chart/validation-policy.yaml" "$repo_root/tests/e2e/manifests/replication-isolation-deny.yaml" "$repo_root/tests/e2e/manifests/zookeeper-isolation-deny.yaml"; do
    yq -e '.' "$yaml_file" >/dev/null || {
      printf 'invalid YAML: %s\n' "${yaml_file#"$repo_root/"}" >&2
      errors=$((errors + 1))
    }
  done
else
  printf '%s\n' 'yq unavailable; YAML syntax checks skipped' >&2
fi

if command -v kubeconform >/dev/null 2>&1; then
  kubeconform -strict -summary -ignore-missing-schemas \
    "$repo_root/tests/e2e/manifests/replication-isolation-deny.yaml" \
    "$repo_root/tests/e2e/manifests/zookeeper-isolation-deny.yaml" >/dev/null || {
      printf '%s\n' 'temporary isolation manifests failed kubeconform' >&2
      errors=$((errors + 1))
    }
fi

dockerfile="$repo_root/images/test-client/Dockerfile"
if [[ -f "$dockerfile" ]]; then
  grep -Eq '^ARG BUILD_IMAGE_DIGEST$' "$dockerfile" || { printf '%s\n' 'Dockerfile must require BUILD_IMAGE_DIGEST' >&2; errors=$((errors + 1)); }
  grep -Eq '^ARG RUNTIME_IMAGE_DIGEST$' "$dockerfile" || { printf '%s\n' 'Dockerfile must require RUNTIME_IMAGE_DIGEST' >&2; errors=$((errors + 1)); }
  grep -Eq '^FROM \$\{BUILD_IMAGE\}@\$\{BUILD_IMAGE_DIGEST\}' "$dockerfile" || { printf '%s\n' 'build stage is not digest-pinned' >&2; errors=$((errors + 1)); }
  grep -Eq '^FROM \$\{RUNTIME_IMAGE\}@\$\{RUNTIME_IMAGE_DIGEST\}' "$dockerfile" || { printf '%s\n' 'runtime stage is not digest-pinned' >&2; errors=$((errors + 1)); }
  grep -Eq '^USER 65532:65532$' "$dockerfile" || { printf '%s\n' 'runtime image must run as non-root UID 65532' >&2; errors=$((errors + 1)); }
fi

makefile="$repo_root/Makefile"
grep -q 'BUILD_IMAGE_DIGEST' "$makefile" || { printf '%s\n' 'Makefile must pass build image digest' >&2; errors=$((errors + 1)); }
grep -q 'RUNTIME_IMAGE_DIGEST' "$makefile" || { printf '%s\n' 'Makefile must pass runtime image digest' >&2; errors=$((errors + 1)); }

if command -v rg >/dev/null 2>&1; then
  if rg -n --hidden --glob '!/.git/**' --glob '!reports/**' \
      'AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{20,}' \
      "$repo_root/images/test-client" "$repo_root/scripts" "$repo_root/tests" >/dev/null; then
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
