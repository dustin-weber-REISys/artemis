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
while IFS= read -r chart_file; do
  chart_dir=$(dirname -- "$chart_file")
  chart_count=$((chart_count + 1))
  chart_name=$(basename -- "$chart_dir")
  helm lint "$chart_dir" "${values_args[@]}" >/dev/null || { printf 'helm lint failed: %s\n' "$chart_name" >&2; errors=$((errors + 1)); }
  rendered="$temp_dir/$chart_name.yaml"
  if ! helm template validation "$chart_dir" "${values_args[@]}" > "$rendered"; then
    printf 'helm template failed: %s\n' "$chart_name" >&2
    errors=$((errors + 1))
    continue
  fi
  kubeconform -strict -summary -ignore-missing-schemas "$rendered" >/dev/null || {
    printf 'kubeconform failed: %s\n' "$chart_name" >&2
    errors=$((errors + 1))
  }
done < <(find "$chart_root" -name Chart.yaml -print | sort)

status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"charts","status":"%s","charts":%d,"errors":%d}\n' \
  "$status" "$chart_count" "$errors" > "$report"
printf '%s\n' "chart validation: $status ($chart_count charts, $errors errors)"
[[ "$errors" -eq 0 ]]
