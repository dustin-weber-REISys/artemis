#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
default_lock="$repo_root/charts/arkmq-operator/vendor/upstream.lock.yaml"
lock_file=$default_lock
artifact=
output=

usage() {
  printf '%s\n' \
    'Usage: prepare-arkmq-vendor.sh --artifact UPSTREAM.tgz --output DIRECTORY [--lock LOCK.yaml]' \
    '' \
    'Verifies the exact upstream package, extracts it, and applies the ordered' \
    'enterprise patch series. DIRECTORY must not already exist.'
}

while (($#)); do
  case "$1" in
    --artifact) artifact=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --lock) lock_file=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$artifact" ]] || { printf '%s\n' '--artifact is required' >&2; exit 2; }
[[ -n "$output" ]] || { printf '%s\n' '--output is required' >&2; exit 2; }
[[ -f "$artifact" ]] || { printf 'upstream chart artifact not found: %s\n' "$artifact" >&2; exit 2; }
[[ -f "$lock_file" ]] || { printf 'vendor lock not found: %s\n' "$lock_file" >&2; exit 2; }
[[ ! -e "$output" ]] || { printf 'output already exists: %s\n' "$output" >&2; exit 2; }

for command_name in patch tar yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

expected_name=$(yq -er '.spec.upstream.name' "$lock_file")
expected_version=$(yq -er '.spec.upstream.version' "$lock_file")
expected_sha256=$(yq -er '.spec.upstream.artifactSha256' "$lock_file")
enterprise_version=$(yq -er '.spec.enterprise.version' "$lock_file")

actual_sha256=$(sha256_file "$artifact")
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  printf 'upstream chart checksum mismatch: expected %s, got %s\n' \
    "$expected_sha256" "$actual_sha256" >&2
  exit 1
fi

# Refuse surprising archive paths even though the package is checksum-locked.
if ! tar -tzf "$artifact" | awk '
  /^\// { bad=1 }
  { count=split($0, part, "/"); for (i=1; i<=count; i++) if (part[i] == "..") bad=1 }
  END { exit bad }
'; then
  printf '%s\n' 'upstream chart contains an unsafe archive path' >&2
  exit 1
fi

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/arkmq-vendor.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
tar -xzf "$artifact" -C "$temp_dir"
source_dir="$temp_dir/$expected_name"
[[ -f "$source_dir/Chart.yaml" ]] || {
  printf 'upstream artifact does not contain %s/Chart.yaml\n' "$expected_name" >&2
  exit 1
}

actual_name=$(yq -er '.name' "$source_dir/Chart.yaml")
actual_version=$(yq -er '.version' "$source_dir/Chart.yaml")
if [[ "$actual_name" != "$expected_name" || "$actual_version" != "$expected_version" ]]; then
  printf 'upstream chart identity mismatch: expected %s %s, got %s %s\n' \
    "$expected_name" "$expected_version" "$actual_name" "$actual_version" >&2
  exit 1
fi
if find "$source_dir" -type f -name '*.orig' -print -quit | grep -q .; then
  printf '%s\n' 'upstream chart unexpectedly contains a .orig backup file' >&2
  exit 1
fi

lock_dir=$(CDPATH= cd -- "$(dirname -- "$lock_file")" && pwd)
while IFS= read -r relative_patch; do
  case "$relative_patch" in
    patches/*.patch) ;;
    *) printf 'invalid patch path in lock: %s\n' "$relative_patch" >&2; exit 1 ;;
  esac
  patch_file="$lock_dir/$relative_patch"
  [[ -f "$patch_file" ]] || { printf 'locked patch not found: %s\n' "$patch_file" >&2; exit 1; }
  # Use portable patch(1) flags; generation always starts from a fresh tree.
  patch -d "$source_dir" -p1 -f < "$patch_file"
done < <(yq -er '.spec.enterprise.patches[]' "$lock_file")

# The enterprise package version is generated metadata, not a source change.
# Keeping it out of the patch series avoids a guaranteed patch edit on every
# upstream/operator release while still giving Helm caches a distinct identity.
ENTERPRISE_VERSION="$enterprise_version" yq -i \
  '.version = strenv(ENTERPRISE_VERSION)' "$source_dir/Chart.yaml"

# BSD patch may leave .orig backups when ordered patches touch one file more
# than once. The verified upstream package contained none, so these are safe to
# remove from the generated tree.
find "$source_dir" -type f -name '*.orig' -delete

actual_enterprise_version=$(yq -er '.version' "$source_dir/Chart.yaml")
if [[ "$actual_enterprise_version" != "$enterprise_version" ]]; then
  printf 'patched chart version mismatch: expected %s, got %s\n' \
    "$enterprise_version" "$actual_enterprise_version" >&2
  exit 1
fi

mkdir -p "$output"
cp -R "$source_dir/." "$output/"
printf 'prepared %s %s from checksum-locked upstream artifact at %s\n' \
  "$expected_name" "$enterprise_version" "$output"
