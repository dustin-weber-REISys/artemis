#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
mode=${ARTEMIS_SCHEMA_MODE:-offline}
kubernetes_version=${ARTEMIS_KUBERNETES_VERSION:-}
schema_location=${ARTEMIS_KUBECONFORM_SCHEMA_LOCATION:-default}
quiet_offline=false
files=()

usage() {
  printf '%s\n' \
    'Usage: validate-rendered-schema.sh [--mode offline|network] [options] FILE...' \
    '' \
    'Options:' \
    '  --kubernetes-version VERSION  Required in network mode' \
    '  --schema-location LOCATION     kubeconform location; default is its remote catalog' \
    '  --quiet-offline                Do not print the offline NOT_RUN notice' \
    '' \
    'Offline mode never invokes kubeconform because its default catalog downloads schemas.'
}

while (($#)); do
  case "$1" in
    --mode) mode=$2; shift 2 ;;
    --kubernetes-version) kubernetes_version=$2; shift 2 ;;
    --schema-location) schema_location=$2; shift 2 ;;
    --quiet-offline) quiet_offline=true; shift ;;
    --help|-h) usage; exit 0 ;;
    --) shift; files+=("$@"); break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done

case "$mode" in
  offline)
    if [[ "$quiet_offline" != true ]]; then
      printf '%s\n' 'Kubernetes schema validation: NOT_RUN (offline mode; use --mode network with a pinned Kubernetes version)'
    fi
    exit 0
    ;;
  network) ;;
  *) printf 'invalid schema mode: %s\n' "$mode" >&2; exit 2 ;;
esac

if [[ -z "$kubernetes_version" && -f "$repo_root/releases/current.yaml" ]] && command -v yq >/dev/null 2>&1; then
  kubernetes_version=$(yq -r '.platform.kubernetesVersion // ""' "$repo_root/releases/current.yaml")
fi
[[ -n "$kubernetes_version" ]] || {
  printf '%s\n' 'network mode requires --kubernetes-version or platform.kubernetesVersion in releases/current.yaml' >&2
  exit 2
}
((${#files[@]} > 0)) || { printf '%s\n' 'at least one rendered manifest is required' >&2; exit 2; }
command -v kubeconform >/dev/null 2>&1 || { printf '%s\n' 'kubeconform is required in network mode' >&2; exit 2; }

printf 'Kubernetes schema validation: NETWORK (Kubernetes %s; schema location %s)\n' \
  "$kubernetes_version" "$schema_location"
kubeconform \
  -strict \
  -summary \
  -exit-on-error \
  -ignore-missing-schemas \
  -kubernetes-version "$kubernetes_version" \
  -schema-location "$schema_location" \
  "${files[@]}"
