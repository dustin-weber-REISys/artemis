#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
chart_root="$repo_root/charts"
report="$repo_root/reports/chart-validation.json"
values_args=()

while (($#)); do
  case "$1" in
    --report) report=$2; shift 2 ;;
    --chart-root) chart_root=$2; shift 2 ;;
    --values) values_args+=(--values "$2"); shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"

if [[ ! -d "$chart_root" ]] || ! find "$chart_root" -name Chart.yaml -print -quit | grep -q .; then
  printf '%s\n' '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"charts","status":"SKIP","reason":"no charts present"}' > "$report"
  printf '%s\n' 'chart validation: SKIP (no charts present)'
  exit 0
fi

command -v helm >/dev/null 2>&1 || { printf '%s\n' 'helm is required when charts are present' >&2; exit 2; }
command -v kubeconform >/dev/null 2>&1 || { printf '%s\n' 'kubeconform is required when charts are present' >&2; exit 2; }

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-chart-validation.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
errors=0
chart_count=0

validate_chart_values() {
  local chart_dir=$1
  local label=$2
  local rendered=$3
  shift 3

  helm lint "$chart_dir" "$@" || {
    printf 'helm lint failed: %s\n' "$label" >&2
    errors=$((errors + 1))
  }
  if ! helm template validation "$chart_dir" "$@" > "$rendered"; then
    printf 'helm template failed: %s\n' "$label" >&2
    errors=$((errors + 1))
    return 0
  fi
  kubeconform -strict -summary -ignore-missing-schemas "$rendered" || {
    printf 'kubeconform failed: %s\n' "$label" >&2
    errors=$((errors + 1))
  }
}

while IFS= read -r chart_file; do
  chart_dir=$(dirname -- "$chart_file")
  chart_count=$((chart_count + 1))
  chart_name=$(basename -- "$chart_dir")
  rendered="$temp_dir/$chart_name.yaml"
  validate_chart_values \
    "$chart_dir" "$chart_name" "$rendered" \
    ${values_args[@]+"${values_args[@]}"}

  focused_test="$chart_dir/tests/test.sh"
  if [[ -x "$focused_test" ]] && ! "$focused_test"; then
    printf 'focused chart tests failed: %s\n' "$chart_name" >&2
    errors=$((errors + 1))
  fi

  if ((${#values_args[@]} == 0)); then
    overlay_stem=${chart_name%-ha}
    for environment in test nonprod prod; do
      overlay="$repo_root/environments/$environment/$overlay_stem-values.yaml"
      [[ -f "$overlay" ]] || continue
      ecr_repository=PLACEHOLDER_NONPROD_ECR_REPOSITORY
      if [[ "$environment" == prod ]]; then
        ecr_repository=PLACEHOLDER_PROD_ECR_REPOSITORY
      fi
      image_args=()
      if [[ "$overlay_stem" == artemis ]]; then
        image_args+=(
          --set-string "images.broker.repository=$ecr_repository/activemq-artemis-broker-kubernetes"
          --set-string "images.init.repository=$ecr_repository/activemq-artemis-broker-init"
        )
      else
        image_args+=(--set-string "image.repository=$ecr_repository/zookeeper")
      fi
      rendered="$temp_dir/$chart_name-$environment.yaml"
      validate_chart_values \
        "$chart_dir" "$chart_name ($environment)" "$rendered" \
        "${image_args[@]}" \
        --values "$overlay"
    done
  fi
done < <(find "$chart_root" -name Chart.yaml -print | sort)

status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"charts","status":"%s","charts":%d,"errors":%d}\n' \
  "$status" "$chart_count" "$errors" > "$report"
printf '%s\n' "chart validation: $status ($chart_count charts, $errors errors)"
[[ "$errors" -eq 0 ]]
