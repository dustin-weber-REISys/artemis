#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
report_dir="$repo_root/reports"
while (($#)); do
  case "$1" in
    --report-dir) report_dir=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
"$script_dir/validate-static.sh" --report "$report_dir/static-validation.json"
"$script_dir/validate-scenarios.sh" --report "$report_dir/scenario-validation.json"
"$script_dir/validate-charts.sh" --report "$report_dir/chart-validation.json"
