#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
script="$repo_root/scripts/refresh-argocd-ecr-credential.sh"

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required' >&2
  exit 2
}

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-ecr-credential-test.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/bin"

cat > "$temp_dir/bin/aws" <<'EOF'
#!/bin/sh
if [ "$*" != "ecr get-login-password --region us-east-1" ]; then
  printf 'unexpected aws arguments: %s\n' "$*" >&2
  exit 1
fi
printf '%s\n' 'short-lived-test-token'
EOF

cat > "$temp_dir/bin/kubectl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$CAPTURE_DIR/kubectl.args"
cat > "$CAPTURE_DIR/secret.yaml"
EOF

chmod +x "$temp_dir/bin/aws" "$temp_dir/bin/kubectl"

PATH="$temp_dir/bin:$PATH" \
CAPTURE_DIR="$temp_dir" \
ARGOCD_NAMESPACE=argocd \
AWS_REGION=us-east-1 \
ECR_REGISTRY=314410645069.dkr.ecr.us-east-1.amazonaws.com \
KUBECTL_CONTEXT=test-context \
  "$script" >/dev/null

[[ "$(cat "$temp_dir/kubectl.args")" == '--context test-context apply -f -' ]]
[[ "$(yq -r '.metadata.name' "$temp_dir/secret.yaml")" == ecr-helm-oci-creds ]]
[[ "$(yq -r '.metadata.namespace' "$temp_dir/secret.yaml")" == argocd ]]
[[ "$(yq -r '.metadata.labels."argocd.argoproj.io/secret-type"' "$temp_dir/secret.yaml")" == repo-creds ]]
[[ "$(yq -r '.stringData.type' "$temp_dir/secret.yaml")" == helm ]]
[[ "$(yq -r '.stringData.enableOCI' "$temp_dir/secret.yaml")" == true ]]
[[ "$(yq -r '.stringData.url' "$temp_dir/secret.yaml")" == '314410645069.dkr.ecr.us-east-1.amazonaws.com' ]]
[[ "$(yq -r '.stringData.username' "$temp_dir/secret.yaml")" == AWS ]]
expected_password_data=$(printf '%s\n' 'short-lived-test-token' | base64 | tr -d '\n')
[[ "$(yq -r '.data.password' "$temp_dir/secret.yaml")" == "$expected_password_data" ]]

rm -f "$temp_dir/secret.yaml" "$temp_dir/kubectl.args"
PATH="$temp_dir/bin:$PATH" \
CAPTURE_DIR="$temp_dir" \
ARGOCD_NAMESPACE=argocd \
ARGOCD_REPO_CREDS_SECRET=prod-ecr-helm-oci-creds \
AWS_REGION=us-east-1 \
ECR_REGISTRY=314410645069.dkr.ecr.us-east-1.amazonaws.com \
  "$script" >/dev/null

[[ "$(yq -r '.metadata.name' "$temp_dir/secret.yaml")" == prod-ecr-helm-oci-creds ]]

if PATH="$temp_dir/bin:$PATH" \
  ARGOCD_NAMESPACE=argocd \
  AWS_REGION=us-east-1 \
  ECR_REGISTRY=oci://314410645069.dkr.ecr.us-east-1.amazonaws.com \
  "$script" >"$temp_dir/invalid.out" 2>&1; then
  printf '%s\n' 'credential refresh accepted a registry containing oci://' >&2
  exit 1
fi

grep -Fq 'without a protocol or path' "$temp_dir/invalid.out"
printf '%s\n' 'Argo CD ECR credential refresh tests passed'
