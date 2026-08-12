#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
chart_root="$repo_root/charts"
report="$repo_root/reports/chart-validation.json"
values_args=()
schema_mode=${ARTEMIS_SCHEMA_MODE:-offline}
kubernetes_version=${ARTEMIS_KUBERNETES_VERSION:-}

while (($#)); do
  case "$1" in
    --report) report=$2; shift 2 ;;
    --chart-root) chart_root=$2; shift 2 ;;
    --values) values_args+=(--values "$2"); shift 2 ;;
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

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"

if [[ ! -d "$chart_root" ]] || ! \
  find "$chart_root" -path '*/vendor/*' -prune -o -name Chart.yaml -print -quit | grep -q .; then
  printf '%s\n' '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"charts","status":"SKIP","reason":"no charts present"}' > "$report"
  printf '%s\n' 'chart validation: SKIP (no charts present)'
  exit 0
fi

command -v helm >/dev/null 2>&1 || { printf '%s\n' 'helm is required when charts are present' >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { printf '%s\n' 'yq is required when charts are present' >&2; exit 2; }
if [[ "$schema_mode" == network && -z "$kubernetes_version" && -f "$repo_root/releases/current.yaml" ]]; then
  kubernetes_version=$(yq -r '.platform.kubernetesVersion // ""' "$repo_root/releases/current.yaml")
fi
if [[ "$schema_mode" == network && -z "$kubernetes_version" ]]; then
  printf '%s\n' 'network schema mode requires --kubernetes-version or platform.kubernetesVersion in releases/current.yaml' >&2
  exit 2
fi

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-chart-validation.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
errors=0
chart_count=0
schema_args=(--mode "$schema_mode")
if [[ -n "$kubernetes_version" ]]; then
  schema_args+=(--kubernetes-version "$kubernetes_version")
fi

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
  "$script_dir/validate-rendered-schema.sh" \
    "${schema_args[@]}" \
    --quiet-offline \
    "$rendered" || {
    printf 'kubeconform failed: %s\n' "$label" >&2
    errors=$((errors + 1))
    schema_status=FAIL
  }
}

while IFS= read -r chart_file; do
  source_chart_dir=$(dirname -- "$chart_file")
  chart_dir=$source_chart_dir
  chart_count=$((chart_count + 1))
  chart_name=$(basename -- "$chart_dir")
  if [[ "$(yq -r '.dependencies | length' "$chart_file")" -gt 0 ]]; then
    chart_dir="$temp_dir/$chart_name"
    cp -R "$source_chart_dir/." "$chart_dir"
    if ! helm dependency build --skip-refresh "$chart_dir"; then
      printf 'Helm dependency build failed: %s\n' "$chart_name" >&2
      errors=$((errors + 1))
      continue
    fi
  fi
  rendered="$temp_dir/$chart_name.yaml"
  validate_chart_values \
    "$chart_dir" "$chart_name" "$rendered" \
    ${values_args[@]+"${values_args[@]}"}

  focused_test="$source_chart_dir/tests/test.sh"
  if [[ -x "$focused_test" ]] && ! \
    ARTEMIS_SCHEMA_MODE="$schema_mode" \
    ARTEMIS_KUBERNETES_VERSION="$kubernetes_version" \
    "$focused_test"; then
    printf 'focused chart tests failed: %s\n' "$chart_name" >&2
    errors=$((errors + 1))
  fi

  if ((${#values_args[@]} == 0)); then
    overlay_stem=${chart_name%-ha}
    for environment in test nonprod prod; do
      overlay="$repo_root/environments/$environment/$overlay_stem-values.yaml"
      [[ -f "$overlay" ]] || continue
      rendered="$temp_dir/$chart_name-$environment.yaml"
      validate_chart_values \
        "$chart_dir" "$chart_name ($environment)" "$rendered" \
        --values "$overlay"
    done
  fi
done < <(find "$chart_root" -path '*/vendor/*' -prune -o -name Chart.yaml -print | sort)

status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"charts","status":"%s","charts":%d,"errors":%d,"schemaMode":"%s","schemaValidation":"%s"}\n' \
  "$status" "$chart_count" "$errors" "$schema_mode" "$schema_status" > "$report"
printf '%s\n' "chart validation: $status ($chart_count charts, $errors errors; Kubernetes schema: $schema_status/$schema_mode)"
[[ "$errors" -eq 0 ]]
