#!/usr/bin/env bash
set -euo pipefail

image=''
os_release_file=''
format=yaml
container_id=''

usage() {
  cat <<'USAGE'
Usage:
  read-image-os.sh --image REGISTRY/IMAGE@sha256:DIGEST [--format yaml|args]
  read-image-os.sh --os-release-file FILE [--format yaml|args]

Read ID and VERSION_ID from /etc/os-release in an exact container image.
--image uses a temporary Docker container and removes it on exit. It does not
run the image. --os-release-file supports saved evidence and offline testing.
USAGE
}

while (($#)); do
  case "$1" in
    --image) image=$2; shift 2 ;;
    --os-release-file) os_release_file=$2; shift 2 ;;
    --format) format=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$image" && -n "$os_release_file" ]] || [[ -z "$image" && -z "$os_release_file" ]]; then
  printf '%s\n' 'provide exactly one of --image or --os-release-file' >&2
  exit 2
fi
case "$format" in yaml|args) ;; *) printf 'unsupported --format: %s\n' "$format" >&2; exit 2 ;; esac

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-image-os.XXXXXX")
cleanup() {
  if [[ -n "$container_id" ]]; then
    docker rm -f "$container_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$temp_dir"
}
trap cleanup EXIT

if [[ -n "$image" ]]; then
  [[ "$image" == *@sha256:* ]] || {
    printf '%s\n' '--image must be digest-qualified with @sha256:' >&2
    exit 2
  }
  command -v docker >/dev/null 2>&1 || {
    printf '%s\n' 'docker is required for --image' >&2
    exit 2
  }
  container_id=$(docker create "$image")
  os_release_file="$temp_dir/os-release"
  docker cp "$container_id:/etc/os-release" "$os_release_file" >/dev/null
fi

[[ -f "$os_release_file" ]] || {
  printf 'os-release file not found: %s\n' "$os_release_file" >&2
  exit 1
}

read_value() {
  key=$1
  value=$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$os_release_file")
  value=${value#\"}
  value=${value%\"}
  value=${value#\'}
  value=${value%\'}
  printf '%s' "$value"
}

os_id=$(read_value ID)
os_version=$(read_value VERSION_ID)
value_pattern='^[A-Za-z0-9][A-Za-z0-9._+-]*$'
[[ "$os_id" =~ $value_pattern ]] || {
  printf 'missing or unsupported ID in %s: %s\n' "$os_release_file" "$os_id" >&2
  exit 1
}
[[ "$os_version" =~ $value_pattern ]] || {
  printf 'missing or unsupported VERSION_ID in %s: %s\n' "$os_release_file" "$os_version" >&2
  exit 1
}

if [[ "$format" == args ]]; then
  printf '%s\n' "--image-os-id $os_id --image-os-version $os_version"
else
  printf 'baseOs:\n  id: %s\n  versionId: %s\n' "$os_id" "$os_version"
fi
