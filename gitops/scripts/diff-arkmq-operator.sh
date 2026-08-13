#!/usr/bin/env bash
set -euo pipefail

baseline_gitops=''
candidate_gitops=''
baseline_artifact=''
candidate_artifact=''
output=''

usage() {
  printf '%s\n' \
    'Usage: diff-arkmq-operator.sh --baseline-gitops DIR --candidate-gitops DIR' \
    '  --baseline-artifact CHART.tgz --candidate-artifact CHART.tgz --output FILE' \
    '' \
    'Renders test, nonprod, and prod from both release states, canonicalizes' \
    'resource and mapping order, and writes a full unified desired-state diff.'
}

while (($#)); do
  case "$1" in
    --baseline-gitops) baseline_gitops=$2; shift 2 ;;
    --candidate-gitops) candidate_gitops=$2; shift 2 ;;
    --baseline-artifact) baseline_artifact=$2; shift 2 ;;
    --candidate-artifact) candidate_artifact=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for required_path in \
  "$baseline_gitops/scripts/render-arkmq-operator.sh" \
  "$candidate_gitops/scripts/render-arkmq-operator.sh" \
  "$baseline_artifact" \
  "$candidate_artifact"; do
  [[ -f "$required_path" ]] || {
    printf 'required file not found: %s\n' "$required_path" >&2
    exit 2
  }
done
[[ -n "$output" ]] || { printf '%s\n' '--output is required' >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { printf '%s\n' 'yq is required' >&2; exit 2; }

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/arkmq-render-diff.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

render_normalized() {
  gitops_root=$1
  artifact=$2
  destination=$3
  : > "$destination"
  for environment in test nonprod prod; do
    rendered="$work_dir/${environment}-$(basename -- "$destination").yaml"
    "$gitops_root/scripts/render-arkmq-operator.sh" \
      --environment "$environment" --artifact "$artifact" > "$rendered"
    if [[ -s "$destination" ]]; then
      printf '%s\n' '---' >> "$destination"
    fi
    printf '# environment=%s\n' "$environment" >> "$destination"
    yq eval-all -P '
      [.] |
      sort_by(.apiVersion, .kind, .metadata.namespace // "", .metadata.name) |
      .[] | sort_keys(..)
    ' "$rendered" | awk '
      /^apiVersion:/ {
        if (seen) print "---"
        seen=1
      }
      { print }
    ' >> "$destination"
  done
}

baseline="$work_dir/baseline.jsonl"
candidate="$work_dir/candidate.jsonl"
render_normalized "$baseline_gitops" "$baseline_artifact" "$baseline"
render_normalized "$candidate_gitops" "$candidate_artifact" "$candidate"

if [[ "$output" != /* ]]; then
  output="$PWD/$output"
fi
mkdir -p "$(dirname -- "$output")"
diff_status=0
diff -u --label baseline/operator-render.yaml --label candidate/operator-render.yaml \
  "$baseline" "$candidate" > "$output" || diff_status=$?
[[ "$diff_status" -eq 0 || "$diff_status" -eq 1 ]] || exit "$diff_status"

if [[ "$diff_status" -eq 0 ]]; then
  printf 'ArkMQ full render diff: no desired-state changes (%s)\n' "$output"
else
  printf 'ArkMQ full render diff written: %s\n' "$output"
fi
