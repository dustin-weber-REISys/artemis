#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
release_file="$repo_root/releases/current.yaml"
source_dir="$repo_root/kustomize/arkmq-operator"
environment=
artifact=

usage() {
  printf '%s\n' \
    'Usage: render-arkmq-operator.sh --environment test|nonprod|prod [--artifact CHART.tgz]' \
    '' \
    'Renders the unmodified upstream Helm chart through the selected Kustomize' \
    'overlay. Without --artifact, Kustomize pulls the pinned public OCI chart.'
}

while (($#)); do
  case "$1" in
    --environment) environment=$2; shift 2 ;;
    --artifact) artifact=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$environment" in
  test|nonprod|prod) ;;
  '') printf '%s\n' '--environment is required' >&2; usage >&2; exit 2 ;;
  *) printf 'unsupported environment: %s\n' "$environment" >&2; exit 2 ;;
esac

for command_name in tar yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done
if command -v kustomize >/dev/null 2>&1; then
  kustomize_command=(kustomize build --enable-helm)
elif command -v kubectl >/dev/null 2>&1; then
  kustomize_command=(kubectl kustomize --enable-helm)
else
  printf '%s\n' 'kustomize or kubectl with embedded Kustomize is required' >&2
  exit 2
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

chart_name=$(yq -er '.operator.chart.name' "$release_file")
chart_version=$(yq -er '.operator.chart.version' "$release_file")
expected_sha256=$(yq -er '.operator.chart.artifactSha256' "$release_file")

stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/arkmq-kustomize.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
cp -R "$source_dir" "$stage_dir/arkmq-operator"

if [[ -n "$artifact" ]]; then
  [[ -f "$artifact" ]] || { printf 'upstream chart artifact not found: %s\n' "$artifact" >&2; exit 2; }
  actual_sha256=$(sha256_file "$artifact")
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    printf 'upstream chart checksum mismatch: expected %s, got %s\n' \
      "$expected_sha256" "$actual_sha256" >&2
    exit 1
  fi
  if ! tar -tzf "$artifact" | awk '
    /^\// { bad=1 }
    { count=split($0, part, "/"); for (i=1; i<=count; i++) if (part[i] == "..") bad=1 }
    END { exit bad }
  '; then
    printf '%s\n' 'upstream chart contains an unsafe archive path' >&2
    exit 1
  fi
  chart_cache="$stage_dir/arkmq-operator/base/charts/$chart_name-$chart_version"
  mkdir -p "$chart_cache"
  tar -xzf "$artifact" -C "$chart_cache"
  chart_file="$chart_cache/$chart_name/Chart.yaml"
  [[ -f "$chart_file" ]] || { printf 'artifact does not contain %s/Chart.yaml\n' "$chart_name" >&2; exit 1; }
  actual_name=$(yq -er '.name' "$chart_file")
  actual_version=$(yq -er '.version' "$chart_file")
  if [[ "$actual_name" != "$chart_name" || "$actual_version" != "$chart_version" ]]; then
    printf 'upstream chart identity mismatch: expected %s %s, got %s %s\n' \
      "$chart_name" "$chart_version" "$actual_name" "$actual_version" >&2
    exit 1
  fi
fi

"${kustomize_command[@]}" "$stage_dir/arkmq-operator/overlays/$environment"
