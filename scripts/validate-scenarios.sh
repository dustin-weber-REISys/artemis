#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
scenario_file="$repo_root/tests/e2e/scenarios.yaml"
report="$repo_root/reports/scenario-validation.json"

while (($#)); do
  case "$1" in
    --report) report=$2; shift 2 ;;
    --file) scenario_file=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if ! command -v yq >/dev/null 2>&1; then
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
fi

errors=0
if [[ ! -f "$scenario_file" ]]; then
  printf 'scenario file not found: %s\n' "$scenario_file" >&2
  exit 2
fi

schema=$(yq -r '.schemaVersion // ""' "$scenario_file")
if [[ "$schema" != "validation.artemis.apache.org/scenarios/v1" ]]; then
  printf 'invalid scenario schema: %s\n' "$schema" >&2
  errors=$((errors + 1))
fi

required_ids='chart-lint-render clean-install openwire-compatibility amqp-compatibility durable-sequenced-backlog active-broker-process-kill active-broker-pod-delete active-broker-node-drain active-broker-az-loss-guidance zookeeper-one-member-loss zookeeper-quorum-loss broker-replication-isolation broker-zookeeper-isolation consumer-disconnect-before-ack producer-timeout-after-commit ebs-detach-reschedule argo-managed-upgrade-rollback failed-upgrade-rollback vault-credential-rotation keycloak-hawtio-authorization queue-management sustained-load safe-manual-failback'
ids=$(yq -r '.scenarios[]?.id // ""' "$scenario_file")
for required_id in $required_ids; do
  if ! printf '%s\n' "$ids" | grep -Fxq "$required_id"; then
    printf 'missing required scenario: %s\n' "$required_id" >&2
    errors=$((errors + 1))
  fi
done

while IFS= read -r scenario_id; do
  [[ -n "$scenario_id" ]] || continue
  destructive=$(SCENARIO_ID=$scenario_id yq -r '.scenarios[] | select(.id == strenv(SCENARIO_ID)) | .destructive' "$scenario_file")
  eks_required=$(SCENARIO_ID=$scenario_id yq -r '.scenarios[] | select(.id == strenv(SCENARIO_ID)) | .eksRequired' "$scenario_file")
  default_mode=$(SCENARIO_ID=$scenario_id yq -r '.scenarios[] | select(.id == strenv(SCENARIO_ID)) | .defaultMode' "$scenario_file")
  claim=$(SCENARIO_ID=$scenario_id yq -r '.scenarios[] | select(.id == strenv(SCENARIO_ID)) | .claim' "$scenario_file")
  verification_count=$(SCENARIO_ID=$scenario_id yq -r '[.scenarios[] | select(.id == strenv(SCENARIO_ID)) | .verification[]?] | length' "$scenario_file")
  if [[ "$destructive" != true && "$destructive" != false ]]; then
    printf '%s has invalid destructive flag\n' "$scenario_id" >&2
    errors=$((errors + 1))
  fi
  if [[ "$eks_required" != true && "$eks_required" != false ]]; then
    printf '%s has invalid eksRequired flag\n' "$scenario_id" >&2
    errors=$((errors + 1))
  fi
  if [[ "$default_mode" != dry-run ]]; then
    printf '%s must default to dry-run\n' "$scenario_id" >&2
    errors=$((errors + 1))
  fi
  if [[ "$claim" != safety && "$claim" != liveness && "$claim" != compatibility && "$claim" != operability ]]; then
    printf '%s has invalid claim\n' "$scenario_id" >&2
    errors=$((errors + 1))
  fi
  if [[ "$verification_count" -le 0 ]]; then
    printf '%s has no verification criteria\n' "$scenario_id" >&2
    errors=$((errors + 1))
  fi
done <<< "$ids"

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"
status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"scenario-definitions","status":"%s","errors":%d,"file":"%s"}\n' \
  "$status" "$errors" "${scenario_file#"$repo_root/"}" > "$report"
printf '%s\n' "scenario validation: $status ($errors errors)"
[[ "$errors" -eq 0 ]]
