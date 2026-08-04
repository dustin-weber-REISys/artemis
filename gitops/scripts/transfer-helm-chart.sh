#!/usr/bin/env bash
set -euo pipefail

require_value() {
  local name=$1
  if [[ -z ${!name:-} ]]; then
    printf 'required environment variable is empty: %s\n' "$name" >&2
    exit 2
  fi
}

for name in FROM_REPO FROM_CHART FROM_CHART_VERSION TO_CHART_REPOSITORY AWS_REGION; do
  require_value "$name"
done

for command_name in aws helm; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'required command is unavailable: %s\n' "$command_name" >&2
    exit 2
  }
done

if [[ ! $FROM_REPO =~ ^oci://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]+)?$ ]]; then
  printf '%s\n' 'FROM_REPO must be an OCI namespace beginning with oci://' >&2
  exit 2
fi
if [[ ! $FROM_CHART =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  printf '%s\n' 'FROM_CHART contains unsupported characters' >&2
  exit 2
fi
if [[ ! $FROM_CHART_VERSION =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
  printf '%s\n' 'FROM_CHART_VERSION contains unsupported characters' >&2
  exit 2
fi
if [[ ! $TO_CHART_REPOSITORY =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]]; then
  printf '%s\n' 'TO_CHART_REPOSITORY is not a valid ECR repository name' >&2
  exit 2
fi
if [[ ! $AWS_REGION =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]]; then
  printf '%s\n' 'AWS_REGION is not a valid AWS region name' >&2
  exit 2
fi

destination_chart=${TO_CHART_REPOSITORY##*/}
destination_namespace=${TO_CHART_REPOSITORY%/*}
if [[ $destination_chart != "$FROM_CHART" ]]; then
  printf 'destination chart name must match source chart: expected %s, got %s\n' \
    "$FROM_CHART" "$destination_chart" >&2
  exit 2
fi
if [[ $destination_namespace == "$TO_CHART_REPOSITORY" ]]; then
  destination_namespace=''
fi

repository_mutability=$(aws ecr describe-repositories \
  --region "$AWS_REGION" \
  --repository-names "$TO_CHART_REPOSITORY" \
  --query 'repositories[0].imageTagMutability' \
  --output text)
if [[ $repository_mutability != IMMUTABLE ]]; then
  printf 'destination ECR repository must be immutable: %s is %s\n' \
    "$TO_CHART_REPOSITORY" "$repository_mutability" >&2
  exit 1
fi

describe_error=$(mktemp "${TMPDIR:-/tmp}/helm-transfer-describe.XXXXXX")
if aws ecr describe-images \
  --region "$AWS_REGION" \
  --repository-name "$TO_CHART_REPOSITORY" \
  --image-ids "imageTag=$FROM_CHART_VERSION" \
  >/dev/null 2>"$describe_error"; then
  printf 'chart version already exists in immutable repository: %s:%s\n' \
    "$TO_CHART_REPOSITORY" "$FROM_CHART_VERSION" >&2
  rm -f -- "$describe_error"
  exit 1
fi
if ! grep -q 'ImageNotFoundException' "$describe_error"; then
  printf '%s\n' 'unable to determine whether the destination chart version exists' >&2
  cat "$describe_error" >&2
  rm -f -- "$describe_error"
  exit 1
fi
rm -f -- "$describe_error"

ecr_registry=$(aws ecr get-authorization-token \
  --region "$AWS_REGION" \
  --query 'authorizationData[0].proxyEndpoint' \
  --output text)
ecr_registry=${ecr_registry#https://}
if [[ -z $ecr_registry || $ecr_registry == None ]]; then
  printf '%s\n' 'AWS did not return an ECR registry endpoint' >&2
  exit 1
fi

transfer_dir=$(mktemp -d "${WORKSPACE_TMP:-${TMPDIR:-/tmp}}/helm-transfer.XXXXXX")
cleanup() {
  helm registry logout "$ecr_registry" >/dev/null 2>&1 || true
  rm -rf -- "$transfer_dir"
}
trap cleanup EXIT
export HELM_REGISTRY_CONFIG="$transfer_dir/registry.json"

source_ref="${FROM_REPO%/}/$FROM_CHART"
printf 'Pulling %s version %s\n' "$source_ref" "$FROM_CHART_VERSION"
helm pull "$source_ref" \
  --version "$FROM_CHART_VERSION" \
  --destination "$transfer_dir"

shopt -s nullglob
chart_packages=("$transfer_dir"/*.tgz)
if ((${#chart_packages[@]} != 1)); then
  printf 'expected one downloaded chart package, found %d\n' "${#chart_packages[@]}" >&2
  exit 1
fi

printf 'Logging in to destination registry %s\n' "$ecr_registry"
aws ecr get-login-password --region "$AWS_REGION" |
  helm registry login \
    --username AWS \
    --password-stdin \
    "$ecr_registry"

destination_ref="oci://$ecr_registry"
if [[ -n $destination_namespace ]]; then
  destination_ref="$destination_ref/$destination_namespace"
fi

printf 'Pushing %s to %s\n' "$FROM_CHART_VERSION" "$destination_ref"
helm push "${chart_packages[0]}" "$destination_ref"

artifact_media_type=$(aws ecr describe-images \
  --region "$AWS_REGION" \
  --repository-name "$TO_CHART_REPOSITORY" \
  --image-ids "imageTag=$FROM_CHART_VERSION" \
  --query 'imageDetails[0].artifactMediaType' \
  --output text)
if [[ $artifact_media_type != application/vnd.cncf.helm.config.v1+json ]]; then
  printf 'unexpected ECR artifact media type: %s\n' "$artifact_media_type" >&2
  exit 1
fi

artifact_digest=$(aws ecr describe-images \
  --region "$AWS_REGION" \
  --repository-name "$TO_CHART_REPOSITORY" \
  --image-ids "imageTag=$FROM_CHART_VERSION" \
  --query 'imageDetails[0].imageDigest' \
  --output text)
if [[ -z $artifact_digest || $artifact_digest == None ]]; then
  printf '%s\n' 'AWS did not return a digest for the transferred chart' >&2
  exit 1
fi

printf 'Verified Helm chart %s:%s at %s\n' \
  "$TO_CHART_REPOSITORY" "$FROM_CHART_VERSION" "$artifact_digest"