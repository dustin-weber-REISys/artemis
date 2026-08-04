#!/bin/sh
set -eu

require_value() {
  if [ -z "$1" ]; then
    printf 'required environment variable is empty: %s\n' "$2" >&2
    exit 2
  fi
}

require_value "${FROM_REPO:-}" FROM_REPO
require_value "${FROM_CHART:-}" FROM_CHART
require_value "${FROM_CHART_VERSION:-}" FROM_CHART_VERSION
require_value "${TO_CHART_REPOSITORY:-}" TO_CHART_REPOSITORY
require_value "${ECR_REPOSITORY_URI:-}" ECR_REPOSITORY_URI
require_value "${HELM_REGISTRY_CONFIG:-}" HELM_REGISTRY_CONFIG

command -v helm >/dev/null 2>&1 || {
  printf '%s\n' 'required command is unavailable: helm' >&2
  exit 2
}

case "$FROM_REPO" in
  oci://?*) ;;
  *)
    printf '%s\n' 'FROM_REPO must be an OCI namespace beginning with oci://' >&2
    exit 2
    ;;
esac

destination_chart=${TO_CHART_REPOSITORY##*/}
if [ "$destination_chart" != "$FROM_CHART" ]; then
  printf 'destination chart name must match source chart: expected %s, got %s\n' \
    "$FROM_CHART" "$destination_chart" >&2
  exit 2
fi

case "$ECR_REPOSITORY_URI" in
  */*) ;;
  *)
    printf '%s\n' 'ECR_REPOSITORY_URI is invalid' >&2
    exit 2
    ;;
esac

transfer_dir=$(mktemp -d "${WORKSPACE_TMP:-${TMPDIR:-/tmp}}/helm-transfer.XXXXXX")
cleanup() {
  rm -rf "$transfer_dir"
}
trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

export HELM_CACHE_HOME="$transfer_dir/cache"
export HELM_CONFIG_HOME="$transfer_dir/config"
export HELM_DATA_HOME="$transfer_dir/data"
mkdir -p "$HELM_CACHE_HOME" "$HELM_CONFIG_HOME" "$HELM_DATA_HOME"

source_ref="${FROM_REPO%/}/$FROM_CHART"
destination_ref="oci://${ECR_REPOSITORY_URI%/*}"

printf 'Pulling %s version %s\n' "$source_ref" "$FROM_CHART_VERSION"
helm pull "$source_ref" \
  --version "$FROM_CHART_VERSION" \
  --destination "$transfer_dir"

set -- "$transfer_dir"/*.tgz
package_count=$#
if [ ! -f "$1" ]; then
  package_count=0
fi
if [ "$package_count" -ne 1 ]; then
  printf 'expected one downloaded chart package, found %d\n' "$package_count" >&2
  exit 1
fi

printf 'Pushing %s to %s\n' "$FROM_CHART_VERSION" "$destination_ref"
helm push "$1" "$destination_ref"
