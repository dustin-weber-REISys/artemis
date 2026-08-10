#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
component=''
version=''
write=false
image_digest=''

usage() {
  cat <<'USAGE'
Usage:
  prepare-upgrade.sh --component broker --version VERSION [--write]
  prepare-upgrade.sh --component zookeeper --version VERSION \
    --image-digest sha256:HEX [--write]

The default is a dry run that validates a staged copy and prints the exact
diff. --write copies only those validated release/generated files back into
the checkout. It does not download artifacts, mirror images, commit, or deploy.
Operator upgrades require an explicit upstream vendor rebase and are not
handled by this script.
USAGE
}

while (($#)); do
  case "$1" in
    --component) component=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --image-digest) image_digest=$2; shift 2 ;;
    --write) write=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in diff perl yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done

case "$component" in
  broker|zookeeper) ;;
  operator)
    printf '%s\n' 'operator upgrades require a reviewed ArkMQ vendor rebase; prepare-upgrade.sh supports only broker and zookeeper' >&2
    exit 2
    ;;
  '') printf '%s\n' '--component is required' >&2; usage >&2; exit 2 ;;
  *) printf 'unsupported component: %s\n' "$component" >&2; exit 2 ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]] || {
  printf 'invalid --version: %s\n' "$version" >&2
  exit 2
}
if [[ "$component" == zookeeper ]]; then
  [[ "$image_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || {
    printf '%s\n' 'ZooKeeper upgrades require --image-digest sha256: followed by 64 lowercase hexadecimal characters' >&2
    exit 2
  }
elif [[ -n "$image_digest" ]]; then
  printf '%s\n' '--image-digest is only valid for ZooKeeper upgrades' >&2
  exit 2
fi

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-upgrade.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
stage="$temp_dir/gitops"
cp -R "$repo_root" "$stage"

release="$stage/releases/current.yaml"
changed_files='releases/current.yaml'

replace_literal() {
  file=$1
  old_value=$2
  new_value=$3
  OLD_VALUE="$old_value" NEW_VALUE="$new_value" perl -0pi -e \
    's/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g' "$file"
}

case "$component" in
  broker)
    old_version=$(yq -r '.broker.version' "$release")
    old_image_tag="artemis.$old_version"
    old_compact=${old_version//./}
    new_compact=${version//./}
    replace_literal "$release" "$old_version" "$version"
    replace_literal "$stage/charts/artemis-ha/values.yaml" "$old_version" "$version"
    broker_schema="$stage/charts/artemis-ha/values.schema.json"
    if ! VERSION="$version" yq -e \
      '.properties.broker.properties.version.enum | contains([strenv(VERSION)])' \
      "$broker_schema" >/dev/null; then
      replace_literal "$broker_schema" "\"$old_version\"]" "\"$old_version\", \"$version\"]"
    fi
    VERSION="$version" yq -e \
      '.properties.broker.properties.version.enum | contains([strenv(VERSION)])' \
      "$broker_schema" >/dev/null || {
        printf 'could not add broker version %s to the chart schema\n' "$version" >&2
        exit 1
      }
    replace_literal "$stage/charts/arkmq-operator/values.yaml" "$old_image_tag" "artemis.$version"
    replace_literal "$stage/charts/arkmq-operator/values.yaml" "$old_compact" "$new_compact"
    changed_files="$changed_files
charts/artemis-ha/values.yaml
charts/artemis-ha/values.schema.json
charts/arkmq-operator/values.yaml"
    ;;
  zookeeper)
    old_zookeeper_version=$(yq -r '.zookeeper.version' "$release")
    old_zookeeper_digest=$(yq -r '.image.digest' "$stage/charts/zookeeper/values.yaml")
    replace_literal "$release" "$old_zookeeper_version" "$version"
    replace_literal "$stage/charts/zookeeper/values.yaml" "$old_zookeeper_version" "$version"
    replace_literal "$stage/charts/zookeeper/values.yaml" "$old_zookeeper_digest" "$image_digest"
    replace_literal "$stage/charts/zookeeper/values.schema.json" "\"$old_zookeeper_version\"" "\"$version\""
    VERSION="$version" yq -e \
      '.properties.image.properties.tag.const == strenv(VERSION)' \
      "$stage/charts/zookeeper/values.schema.json" >/dev/null || {
        printf 'could not update ZooKeeper version %s in the chart schema\n' "$version" >&2
        exit 1
      }
    changed_files="$changed_files
charts/zookeeper/values.yaml
charts/zookeeper/values.schema.json"
    ;;
esac

"$stage/scripts/validate-release.sh"

printf 'upgrade plan: %s %s (%s)\n' "$component" "$version" "$([[ "$write" == true ]] && printf write || printf dry-run)"
printf '%s\n' "$changed_files" | while IFS= read -r relative_path; do
  [[ -n "$relative_path" ]] || continue
  diff_status=0
  diff -u --label "a/gitops/$relative_path" --label "b/gitops/$relative_path" \
    "$repo_root/$relative_path" "$stage/$relative_path" || diff_status=$?
  if [[ "$diff_status" -ne 0 ]]; then
    [[ "$diff_status" -eq 1 ]] || exit "$diff_status"
  fi
done

if [[ "$write" == true ]]; then
  printf '%s\n' "$changed_files" | while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    cp "$stage/$relative_path" "$repo_root/$relative_path"
  done
  "$script_dir/validate-release.sh"
  printf '%s\n' 'upgrade files written; review the diff, mirror artifacts, and run repository validation before committing'
else
  printf '%s\n' 'dry run only; rerun the same command with --write after reviewing this diff'
fi
