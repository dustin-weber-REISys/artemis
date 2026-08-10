#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
artifact=
lock_file="$repo_root/charts/arkmq-operator/vendor/upstream.lock.yaml"

usage() {
  printf '%s\n' \
    'Usage: vendor-check.sh --artifact UPSTREAM.tgz [--lock LOCK.yaml]' \
    '' \
    'Regenerates the vendored ArkMQ chart from the checksum-locked artifact and' \
    'fails if the committed chart contains an unrepresented manual edit.'
}

while (($#)); do
  case "$1" in
    --artifact) artifact=$2; shift 2 ;;
    --lock) lock_file=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$artifact" ]] || { printf '%s\n' '--artifact is required' >&2; exit 2; }

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/arkmq-vendor-check.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
generated="$temp_dir/arkmq-org-broker-operator"

"$script_dir/prepare-arkmq-vendor.sh" \
  --artifact "$artifact" \
  --lock "$lock_file" \
  --output "$generated" >/dev/null

committed="$repo_root/charts/arkmq-operator/vendor/arkmq-org-broker-operator"
if ! diff -ruN "$generated" "$committed"; then
  printf '%s\n' 'vendored ArkMQ chart differs from checksum-locked upstream plus patches' >&2
  printf '%s\n' 'update the patch series, increment enterprise.version, and regenerate; do not edit the generated chart directly' >&2
  exit 1
fi

printf '%s\n' 'ArkMQ vendor check: PASS (committed chart is reproducible)'
