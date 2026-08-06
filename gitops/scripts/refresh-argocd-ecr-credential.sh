#!/bin/sh
set -eu

require_value() {
  if [ -z "$1" ]; then
    printf 'required environment variable is empty: %s\n' "$2" >&2
    exit 2
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'required command is unavailable: %s\n' "$1" >&2
    exit 2
  }
}

require_value "${ARGOCD_NAMESPACE:-}" ARGOCD_NAMESPACE
require_value "${AWS_REGION:-}" AWS_REGION
require_value "${ECR_REGISTRY:-}" ECR_REGISTRY

ARGOCD_REPO_CREDS_SECRET=${ARGOCD_REPO_CREDS_SECRET:-ecr-helm-oci-creds}
KUBECTL=${KUBECTL:-kubectl}

case "$ARGOCD_NAMESPACE" in
  *[!a-z0-9.-]*|'')
    printf '%s\n' 'ARGOCD_NAMESPACE must be a Kubernetes DNS name' >&2
    exit 2
    ;;
esac

case "$ARGOCD_REPO_CREDS_SECRET" in
  *[!a-z0-9.-]*|'')
    printf '%s\n' 'ARGOCD_REPO_CREDS_SECRET must be a Kubernetes DNS name' >&2
    exit 2
    ;;
esac

case "$ECR_REGISTRY" in
  http://*|https://*|oci://*|*/*)
    printf '%s\n' 'ECR_REGISTRY must be a registry hostname without a protocol or path' >&2
    exit 2
    ;;
  *.dkr.ecr.*.amazonaws.com|*.dkr.ecr.*.amazonaws.com.cn) ;;
  *)
    printf '%s\n' 'ECR_REGISTRY must be a private Amazon ECR registry hostname' >&2
    exit 2
    ;;
esac

require_command aws
require_command base64
require_command "$KUBECTL"

password_data=$(aws ecr get-login-password --region "$AWS_REGION" | base64 | tr -d '\n')

if [ -z "$password_data" ]; then
  printf '%s\n' 'AWS returned an empty ECR authorization password' >&2
  exit 1
fi

set -- "$KUBECTL"
if [ -n "${KUBECTL_CONTEXT:-}" ]; then
  set -- "$@" --context "$KUBECTL_CONTEXT"
fi

{
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: Secret' \
    'metadata:' \
    "  name: $ARGOCD_REPO_CREDS_SECRET" \
    "  namespace: $ARGOCD_NAMESPACE" \
    '  labels:' \
    '    argocd.argoproj.io/secret-type: repo-creds' \
    'type: Opaque' \
    'stringData:' \
    '  type: helm' \
    '  enableOCI: "true"' \
    "  url: $ECR_REGISTRY" \
    '  username: AWS' \
    'data:' \
    "  password: $password_data"
} | "$@" apply -f -

unset password_data
printf 'refreshed Argo CD ECR Helm/OCI credential template: %s/%s (%s)\n' \
  "$ARGOCD_NAMESPACE" "$ARGOCD_REPO_CREDS_SECRET" "$ECR_REGISTRY"
