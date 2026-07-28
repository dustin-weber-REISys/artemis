#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
report_dir=${REPORT_DIR:-reports}
client_dir=${CLIENT_DIR:-images/test-client}
maven=${MAVEN:-mvn}

usage() {
  printf '%s\n' \
    "Usage: ${0##*/} [--report-dir DIRECTORY]" \
    '' \
    'Run the complete repository validation suite.' \
    'Relative report and client directories are resolved from the repository root.'
}

while (($#)); do
  case "$1" in
    --report-dir)
      (($# >= 2)) || {
        printf '%s\n' '--report-dir requires a directory' >&2
        exit 2
      }
      report_dir=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$report_dir" ]] || {
  printf '%s\n' 'report directory must not be empty' >&2
  exit 2
}
[[ -n "$client_dir" ]] || {
  printf '%s\n' 'client directory must not be empty' >&2
  exit 2
}
[[ -n "$maven" ]] || {
  printf '%s\n' 'MAVEN must not be empty' >&2
  exit 2
}

if [[ "$report_dir" != /* ]]; then
  report_dir="$repo_root/$report_dir"
fi
if [[ "$client_dir" != /* ]]; then
  client_dir="$repo_root/$client_dir"
fi
mkdir -p "$report_dir"

check_number=0
check_count=8
run_check() {
  local label=$1
  local exit_code
  shift
  check_number=$((check_number + 1))
  printf '\n[%d/%d] %s\n' "$check_number" "$check_count" "$label"
  if "$@"; then
    printf '[%d/%d] PASS: %s\n' "$check_number" "$check_count" "$label"
  else
    exit_code=$?
    printf '[%d/%d] FAIL: %s (exit %d)\n' \
      "$check_number" "$check_count" "$label" "$exit_code" >&2
    return "$exit_code"
  fi
}

run_check 'Static invariants' \
  "$script_dir/validate-static.sh" \
  --report "$report_dir/static-validation.json"
run_check 'Scenario definitions' \
  "$script_dir/validate-scenarios.sh" \
  --report "$report_dir/scenario-validation.json"
run_check 'Generated workload topology' \
  "$script_dir/validate-topology.sh" \
  --report "$report_dir/topology-validation.json"
run_check 'Topology regression tests' \
  "$repo_root/tests/topology/test.sh"
run_check 'Helm charts and overlays' \
  "$script_dir/validate-charts.sh" \
  --report "$report_dir/chart-validation.json"
run_check 'ArkMQ operator schema' \
  "$script_dir/validate-operator-schema.sh"
run_check 'Docker Compose configuration' \
  "$script_dir/validate-compose.sh" \
  --report "$report_dir/compose-validation.json"
run_check 'Java unit tests' \
  "$maven" -B -ntp -f "$client_dir/pom.xml" test

printf '\nRepository validation: PASS (%d checks)\n' "$check_count"
