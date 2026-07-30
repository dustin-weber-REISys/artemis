#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
acceptance_plan="$repo_root/tests/e2e/acceptance-plan.yaml"
load_profiles="$repo_root/../performance/profiles/sustained-load-profiles.yaml"
compatibility_inventory="$repo_root/tests/compatibility/classic-6.2.6-inventory.yaml"
chart_policy="$repo_root/tests/chart/validation-policy.yaml"
runner="$script_dir/eks-scenario.sh"
report="$repo_root/reports/scenario-validation.json"

require_option_value() {
  local option=$1
  local value=${2-}
  [[ -n "$value" ]] || { printf '%s requires a value\n' "$option" >&2; exit 2; }
}

while (($#)); do
  case "$1" in
    --report) require_option_value "$1" "${2-}"; report=$2; shift 2 ;;
    --file) require_option_value "$1" "${2-}"; acceptance_plan=$2; shift 2 ;;
    --load-profiles) require_option_value "$1" "${2-}"; load_profiles=$2; shift 2 ;;
    --compatibility-inventory) require_option_value "$1" "${2-}"; compatibility_inventory=$2; shift 2 ;;
    --chart-policy) require_option_value "$1" "${2-}"; chart_policy=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if ! command -v yq >/dev/null 2>&1; then
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
fi

errors=0
error() {
  printf '%s\n' "$*" >&2
  errors=$((errors + 1))
}

require_yaml_artifact() {
  local file=$1
  local expected_schema=$2
  local expected_kind=$3
  local label=$4
  if [[ ! -f "$file" ]]; then
    error "$label not found: $file"
    return
  fi
  if ! yq -e '.' "$file" >/dev/null; then
    error "$label is not valid YAML: $file"
    return
  fi
  local actual_schema
  local actual_kind
  actual_schema=$(yq -r '.schemaVersion // ""' "$file")
  actual_kind=$(yq -r '.kind // ""' "$file")
  [[ "$actual_schema" == "$expected_schema" ]] || error "$label has invalid schema: $actual_schema"
  [[ "$actual_kind" == "$expected_kind" ]] || error "$label has invalid kind: $actual_kind"
}

require_yaml_artifact \
  "$acceptance_plan" \
  validation.artemis.apache.org/manual-acceptance-plan/v1 \
  ManualAcceptancePlan \
  'acceptance plan'
require_yaml_artifact \
  "$load_profiles" \
  validation.artemis.apache.org/load-profile-catalog/v1 \
  LoadProfileCatalog \
  'load profile catalog'
require_yaml_artifact \
  "$compatibility_inventory" \
  validation.artemis.apache.org/compatibility-inventory/v1 \
  CompatibilityInventory \
  'compatibility inventory'
require_yaml_artifact \
  "$chart_policy" \
  validation.artemis.apache.org/chart-validation-policy/v1 \
  ChartValidationPolicy \
  'chart validation policy'

if [[ -f "$acceptance_plan" ]] && yq -e '.' "$acceptance_plan" >/dev/null; then
  ids=$(yq -r '.cases[]?.id // ""' "$acceptance_plan")
  required_ids=$(yq -r '.requiredCoverage[]? // ""' "$acceptance_plan")
  supported_actions=$("$runner" --list-actions | awk -F '\t' '{print $1}')

  duplicate_ids=$(yq -r '.cases | group_by(.id)[] | select(length > 1) | .[0].id' "$acceptance_plan")
  while IFS= read -r duplicate_id; do
    [[ -n "$duplicate_id" ]] || continue
    error "duplicate acceptance case: $duplicate_id"
  done <<< "$duplicate_ids"

  duplicate_required_ids=$(yq -r '.requiredCoverage | group_by(.)[] | select(length > 1) | .[0]' "$acceptance_plan")
  while IFS= read -r duplicate_required_id; do
    [[ -n "$duplicate_required_id" ]] || continue
    error "duplicate required coverage entry: $duplicate_required_id"
  done <<< "$duplicate_required_ids"

  while IFS= read -r required_id; do
    [[ -n "$required_id" ]] || continue
    if ! grep -Fxq "$required_id" <<< "$ids"; then
      error "missing required acceptance coverage: $required_id"
    fi
  done <<< "$required_ids"

  while IFS= read -r scenario_id; do
    [[ -n "$scenario_id" ]] || continue
    if ! grep -Fxq "$scenario_id" <<< "$required_ids"; then
      error "acceptance case is not declared in requiredCoverage: $scenario_id"
    fi
    [[ "$scenario_id" =~ ^[a-z0-9-]+$ ]] || error "$scenario_id has an invalid ID"

    destructive=$(SCENARIO_ID=$scenario_id yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .destructive' "$acceptance_plan")
    eks_required=$(SCENARIO_ID=$scenario_id yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .eksRequired' "$acceptance_plan")
    claim=$(SCENARIO_ID=$scenario_id yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .claim' "$acceptance_plan")
    action=$(SCENARIO_ID=$scenario_id yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .action // ""' "$acceptance_plan")
    execution_kind=$(SCENARIO_ID=$scenario_id yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .execution.kind // ""' "$acceptance_plan")
    runner_action=$(SCENARIO_ID=$scenario_id yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .execution.runnerAction // ""' "$acceptance_plan")
    repository_command=$(SCENARIO_ID=$scenario_id yq -r '.cases[] | select(.id == strenv(SCENARIO_ID)) | .execution.command // ""' "$acceptance_plan")
    verification_count=$(SCENARIO_ID=$scenario_id yq -r '[.cases[] | select(.id == strenv(SCENARIO_ID)) | .verification[]?] | length' "$acceptance_plan")

    [[ "$destructive" == true || "$destructive" == false ]] || error "$scenario_id has invalid destructive flag"
    [[ "$eks_required" == true || "$eks_required" == false ]] || error "$scenario_id has invalid eksRequired flag"
    case "$claim" in safety|liveness|compatibility|operability) ;; *) error "$scenario_id has invalid claim" ;; esac
    [[ -n "$action" ]] || error "$scenario_id has no action description"
    [[ "$verification_count" -gt 0 ]] || error "$scenario_id has no verification criteria"

    case "$execution_kind" in
      runner-assisted)
        [[ -n "$runner_action" ]] || error "$scenario_id is runner-assisted but has no runnerAction"
        [[ -z "$repository_command" ]] || error "$scenario_id cannot set both runnerAction and command"
        if [[ -n "$runner_action" ]] && ! grep -Fxq "$runner_action" <<< "$supported_actions"; then
          error "$scenario_id references unsupported runner action: $runner_action"
        fi
        ;;
      repository-check)
        [[ -n "$repository_command" ]] || error "$scenario_id is a repository check but has no command"
        [[ -z "$runner_action" ]] || error "$scenario_id repository check cannot set runnerAction"
        ;;
      manual-procedure)
        [[ -z "$runner_action" ]] || error "$scenario_id manual procedure cannot set runnerAction"
        [[ -z "$repository_command" ]] || error "$scenario_id manual procedure cannot set command"
        ;;
      *)
        error "$scenario_id has invalid execution kind: $execution_kind"
        ;;
    esac
  done <<< "$ids"

  while IFS= read -r supported_action; do
    [[ -n "$supported_action" ]] || continue
    reference_count=$(RUNNER_ACTION=$supported_action yq -r '[.cases[] | select(.execution.runnerAction == strenv(RUNNER_ACTION))] | length' "$acceptance_plan")
    [[ "$reference_count" -gt 0 ]] || error "runner exposes unreferenced action: $supported_action"
  done <<< "$supported_actions"
fi

if [[ -f "$load_profiles" ]] && yq -e '.' "$load_profiles" >/dev/null; then
  profile_count=$(yq -r '[.profiles[]?] | length' "$load_profiles")
  [[ "$profile_count" -gt 0 ]] || error 'load profile catalog has no profiles'
  duplicate_profiles=$(yq -r '.profiles | group_by(.name)[] | select(length > 1) | .[0].name' "$load_profiles")
  while IFS= read -r duplicate_profile; do
    [[ -n "$duplicate_profile" ]] || continue
    error "duplicate load profile: $duplicate_profile"
  done <<< "$duplicate_profiles"
  invalid_default_numbers=$(yq -r '[
    .defaults.messageCount,
    .defaults.payloadBytes,
    .defaults.producerConcurrency,
    .defaults.consumerConcurrency,
    .defaults.durationSeconds
  ] | map(select(. == null or type != "!!int" or . <= 0)) | length' "$load_profiles")
  invalid_profile_numbers=$(yq -r '[
    .profiles[]?.messageCount,
    .profiles[]?.payloadBytes,
    .profiles[]?.producerConcurrency,
    .profiles[]?.consumerConcurrency,
    .profiles[]?.durationSeconds
  ] | map(select(. != null and (type != "!!int" or . <= 0))) | length' "$load_profiles")
  [[ "$invalid_default_numbers" -eq 0 && "$invalid_profile_numbers" -eq 0 ]] ||
    error 'load profile counts, payload size, concurrency, and durations must be positive integers'
fi

if [[ -f "$compatibility_inventory" ]] && yq -e '.' "$compatibility_inventory" >/dev/null; then
  feature_count=$(yq -r '[.features[]?] | length' "$compatibility_inventory")
  [[ "$feature_count" -gt 0 ]] || error 'compatibility inventory has no features'
  duplicate_features=$(yq -r '.features | group_by(.id)[] | select(length > 1) | .[0].id' "$compatibility_inventory")
  while IFS= read -r duplicate_feature; do
    [[ -n "$duplicate_feature" ]] || continue
    error "duplicate compatibility inventory feature: $duplicate_feature"
  done <<< "$duplicate_features"
  invalid_inventory_results=$(yq -r '[
    .features[]? |
    select(
      .result != "pending-runtime-inventory" and
      .result != "observed-compatible" and
      .result != "observed-incompatible" and
      .result != "not-used"
    )
  ] | length' "$compatibility_inventory")
  [[ "$invalid_inventory_results" -eq 0 ]] || error 'compatibility inventory has an invalid result'
  missing_inventory_evidence=$(yq -r '[
    .features[]? |
    select(.result != "pending-runtime-inventory" and ((.evidence // "") | length) == 0)
  ] | length' "$compatibility_inventory")
  [[ "$missing_inventory_evidence" -eq 0 ]] || error 'completed compatibility inventory entries require evidence'
fi

if [[ -f "$chart_policy" ]] && yq -e '.' "$chart_policy" >/dev/null; then
  chart_check_count=$(yq -r '[.requiredChecks[]?] | length' "$chart_policy")
  [[ "$chart_check_count" -gt 0 ]] || error 'chart validation policy has no required checks'
fi

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
report_dir=$(dirname -- "$report")
mkdir -p "$report_dir"
temp_report=$(mktemp "$report_dir/.acceptance-artifact-report.XXXXXX")
trap 'rm -f -- "$temp_report"' EXIT
status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
REPORT_STATUS=$status \
REPORT_ERRORS=$errors \
REPORT_PLAN=${acceptance_plan#"$repo_root/"} \
  yq -n -o=json -I=0 '{
    "schemaVersion": "validation.artemis.apache.org/acceptance-artifact-validation-report/v1",
    "kind": "AcceptanceArtifactValidationReport",
    "check": "acceptance-artifacts",
    "status": strenv(REPORT_STATUS),
    "errors": env(REPORT_ERRORS),
    "acceptancePlan": strenv(REPORT_PLAN)
  }' > "$temp_report"
mv -- "$temp_report" "$report"
trap - EXIT
printf '%s\n' "acceptance artifact validation: $status ($errors errors)"
[[ "$errors" -eq 0 ]]
