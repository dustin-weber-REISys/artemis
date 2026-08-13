#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
gitops_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
contract="$gitops_dir/toolchain.yaml"

for command_name in helm yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'required command not found: %s\n' "$command_name" >&2
    exit 2
  }
done

expected_kustomize=$(yq -er '.render.kustomizeVersion' "$contract")
expected_helm=$(yq -er '.render.helmVersion' "$contract")
expected_yq=$(yq -er '.render.yqVersion' "$contract")

if command -v kustomize >/dev/null 2>&1; then
  actual_kustomize=$(kustomize version | sed -E 's/.*(v[0-9]+[.][0-9]+[.][0-9]+).*/\1/')
elif command -v kubectl >/dev/null 2>&1; then
  actual_kustomize=$(kubectl version --client=true --output=yaml 2>/dev/null | yq -er '.kustomizeVersion')
else
  printf '%s\n' 'kustomize or kubectl with embedded Kustomize is required' >&2
  exit 2
fi

actual_helm=$(helm version --short | sed -E 's/^(v[0-9]+[.][0-9]+[.][0-9]+).*/\1/')
actual_yq=$(yq --version | sed -E 's/.* version (v[0-9]+[.][0-9]+[.][0-9]+).*/\1/')

errors=0
assert_version() {
  tool_name=$1
  expected=$2
  actual=$3
  if [[ "$actual" != "$expected" ]]; then
    printf '%s version mismatch: expected %s, got %s\n' \
      "$tool_name" "$expected" "$actual" >&2
    errors=$((errors + 1))
  fi
}

assert_version Kustomize "$expected_kustomize" "$actual_kustomize"
assert_version Helm "$expected_helm" "$actual_helm"
assert_version yq "$expected_yq" "$actual_yq"

if [[ "$(yq -r '.argocd.kustomizeBuildOptions | contains(["--enable-helm"])' "$contract")" != true ]]; then
  printf '%s\n' 'toolchain contract must require Argo CD --enable-helm' >&2
  errors=$((errors + 1))
fi

[[ "$errors" -eq 0 ]] || exit 1
printf 'render toolchain: PASS (Kustomize %s, Helm %s, yq %s)\n' \
  "$actual_kustomize" "$actual_helm" "$actual_yq"
