#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
component=''
version=''
write=false
image_digest=''
init_image_digest=''
runtime_image_digest=''
chart_artifact=''
chart_oci_digest=''
manifest_sha256=''
image_os_id=''
image_os_version=''
init_image_os_id=''
init_image_os_version=''
runtime_image_os_id=''
runtime_image_os_version=''

usage() {
  cat <<'USAGE'
Usage:
  prepare-upgrade.sh --component kubernetes --version VERSION [--write]
  prepare-upgrade.sh --component broker --version VERSION \
    --chart-artifact CURRENT-OPERATOR-CHART.tgz \
    --init-image-digest sha256:HEX --runtime-image-digest sha256:HEX \
    --init-image-os-id ID --init-image-os-version VERSION_ID \
    --runtime-image-os-id ID --runtime-image-os-version VERSION_ID [--write]
  prepare-upgrade.sh --component zookeeper --version VERSION \
    --image-digest sha256:HEX --image-os-id ID \
    --image-os-version VERSION_ID [--write]
  prepare-upgrade.sh --component operator --version VERSION \
    --chart-artifact CHART.tgz --chart-oci-digest sha256:HEX \
    --manifest-sha256 HEX --image-digest sha256:HEX \
    --image-os-id ID --image-os-version VERSION_ID [--write]

The default is a dry run that validates a staged copy and prints the exact
diff. --write copies only those validated release/generated files back into
the checkout. It does not download artifacts, mirror images, commit, or deploy.
Container OS inputs are the ID and VERSION_ID read from /etc/os-release in the
exact digest-qualified image after mirroring. Record fresh SBOM and scan evidence
for that same digest; do not infer OS identity from an image tag or Dockerfile.
Operator upgrades consume the unmodified upstream chart. The chart package,
OCI digest, manifest checksum, and operator image digest are required inputs.
USAGE
}

while (($#)); do
  case "$1" in
    --component) component=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --image-digest) image_digest=$2; shift 2 ;;
    --init-image-digest) init_image_digest=$2; shift 2 ;;
    --runtime-image-digest) runtime_image_digest=$2; shift 2 ;;
    --image-os-id) image_os_id=$2; shift 2 ;;
    --image-os-version) image_os_version=$2; shift 2 ;;
    --init-image-os-id) init_image_os_id=$2; shift 2 ;;
    --init-image-os-version) init_image_os_version=$2; shift 2 ;;
    --runtime-image-os-id) runtime_image_os_id=$2; shift 2 ;;
    --runtime-image-os-version) runtime_image_os_version=$2; shift 2 ;;
    --chart-artifact) chart_artifact=$2; shift 2 ;;
    --chart-oci-digest) chart_oci_digest=$2; shift 2 ;;
    --manifest-sha256) manifest_sha256=$2; shift 2 ;;
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
  kubernetes|broker|zookeeper|operator) ;;
  '') printf '%s\n' '--component is required' >&2; usage >&2; exit 2 ;;
  *) printf 'unsupported component: %s\n' "$component" >&2; exit 2 ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]] || {
  printf 'invalid --version: %s\n' "$version" >&2
  exit 2
}
digest_pattern='^sha256:[a-f0-9]{64}$'
hex_pattern='^[a-f0-9]{64}$'
os_value_pattern='^[A-Za-z0-9][A-Za-z0-9._+-]*$'
require_os_value() {
  option_name=$1
  option_value=$2
  [[ "$option_value" =~ $os_value_pattern ]] || {
    printf 'invalid or missing %s: %s\n' "$option_name" "$option_value" >&2
    exit 2
  }
}
if [[ "$component" == zookeeper ]]; then
  [[ "$image_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || {
    printf '%s\n' 'ZooKeeper upgrades require --image-digest sha256: followed by 64 lowercase hexadecimal characters' >&2
    exit 2
  }
  require_os_value --image-os-id "$image_os_id"
  require_os_value --image-os-version "$image_os_version"
elif [[ "$component" == operator ]]; then
  [[ -f "$chart_artifact" ]] || { printf '%s\n' 'operator upgrades require --chart-artifact CHART.tgz' >&2; exit 2; }
  [[ "$chart_oci_digest" =~ $digest_pattern ]] || { printf '%s\n' 'operator upgrades require --chart-oci-digest sha256:HEX' >&2; exit 2; }
  [[ "$manifest_sha256" =~ $hex_pattern ]] || { printf '%s\n' 'operator upgrades require --manifest-sha256 HEX' >&2; exit 2; }
  [[ "$image_digest" =~ $digest_pattern ]] || { printf '%s\n' 'operator upgrades require --image-digest sha256:HEX' >&2; exit 2; }
  require_os_value --image-os-id "$image_os_id"
  require_os_value --image-os-version "$image_os_version"
elif [[ "$component" == broker ]]; then
  [[ -f "$chart_artifact" ]] || { printf '%s\n' 'broker upgrades require --chart-artifact for operator compatibility validation' >&2; exit 2; }
  [[ "$init_image_digest" =~ $digest_pattern ]] || { printf '%s\n' 'broker upgrades require --init-image-digest sha256:HEX' >&2; exit 2; }
  [[ "$runtime_image_digest" =~ $digest_pattern ]] || { printf '%s\n' 'broker upgrades require --runtime-image-digest sha256:HEX' >&2; exit 2; }
  if [[ -n "$image_digest" || -n "$chart_oci_digest" || -n "$manifest_sha256" ]]; then
    printf '%s\n' 'generic digest inputs are valid only for operator or ZooKeeper upgrades' >&2
    exit 2
  fi
  require_os_value --init-image-os-id "$init_image_os_id"
  require_os_value --init-image-os-version "$init_image_os_version"
  require_os_value --runtime-image-os-id "$runtime_image_os_id"
  require_os_value --runtime-image-os-version "$runtime_image_os_version"
fi
if [[ "$component" != operator && "$component" != broker && ( -n "$chart_artifact" || -n "$chart_oci_digest" || -n "$manifest_sha256" ) ]]; then
  printf '%s\n' 'chart inputs are only valid for operator or broker upgrades' >&2
  exit 2
fi
if [[ "$component" != operator && "$component" != zookeeper && -n "$image_digest" ]]; then
  printf '%s\n' 'image digests are valid only for operator or ZooKeeper upgrades' >&2
  exit 2
fi
if [[ "$component" != broker && ( -n "$init_image_digest" || -n "$runtime_image_digest" ) ]]; then
  printf '%s\n' 'init/runtime image digests are valid only for broker upgrades' >&2
  exit 2
fi
if [[ "$component" != operator && "$component" != zookeeper && ( -n "$image_os_id" || -n "$image_os_version" ) ]]; then
  printf '%s\n' 'generic image OS inputs are valid only for operator or ZooKeeper upgrades' >&2
  exit 2
fi
if [[ "$component" != broker && ( -n "$init_image_os_id" || -n "$init_image_os_version" || -n "$runtime_image_os_id" || -n "$runtime_image_os_version" ) ]]; then
  printf '%s\n' 'init/runtime image OS inputs are valid only for broker upgrades' >&2
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
  kubernetes)
    old_kubernetes_version=$(yq -r '.platform.kubernetesVersion' "$release")
    replace_literal "$release" \
      "  kubernetesVersion: $old_kubernetes_version" "  kubernetesVersion: $version"
    ;;
  broker)
    old_version=$(yq -r '.broker.version' "$release")
    old_image_tag="artemis.$old_version"
    old_compact=${old_version//./}
    new_compact=${version//./}
    old_init_os_id=$(yq -r '.broker.images.init.baseOs.id' "$release")
    old_init_os_version=$(yq -r '.broker.images.init.baseOs.versionId' "$release")
    old_init_image_digest=$(yq -r '.broker.images.init.digest' "$release")
    old_runtime_os_id=$(yq -r '.broker.images.runtime.baseOs.id' "$release")
    old_runtime_os_version=$(yq -r '.broker.images.runtime.baseOs.versionId' "$release")
    old_runtime_image_digest=$(yq -r '.broker.images.runtime.digest' "$release")
    replace_literal "$release" \
      "broker:
  version: $old_version
  images:
    init:
      digest: $old_init_image_digest
      baseOs:
        id: $old_init_os_id
        versionId: $old_init_os_version
    runtime:
      digest: $old_runtime_image_digest
      baseOs:
        id: $old_runtime_os_id
        versionId: $old_runtime_os_version" \
      "broker:
  version: $version
  images:
    init:
      digest: $init_image_digest
      baseOs:
        id: $init_image_os_id
        versionId: $init_image_os_version
    runtime:
      digest: $runtime_image_digest
      baseOs:
        id: $runtime_image_os_id
        versionId: $runtime_image_os_version"
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
    for environment in test nonprod prod; do
      image_patch="$stage/kustomize/arkmq-operator/overlays/$environment/private-images.patch.yaml"
      replace_literal "$image_patch" "$old_image_tag" "artemis.$version"
      replace_literal "$image_patch" "$old_compact" "$new_compact"
      replace_literal "$image_patch" \
        "/activemq-artemis-broker-init:artemis.$version@$old_init_image_digest" \
        "/activemq-artemis-broker-init:artemis.$version@$init_image_digest"
      replace_literal "$image_patch" \
        "/activemq-artemis-broker-kubernetes:artemis.$version@$old_runtime_image_digest" \
        "/activemq-artemis-broker-kubernetes:artemis.$version@$runtime_image_digest"
    done
    changed_files="$changed_files
charts/artemis-ha/values.yaml
charts/artemis-ha/values.schema.json
kustomize/arkmq-operator/overlays/test/private-images.patch.yaml
kustomize/arkmq-operator/overlays/nonprod/private-images.patch.yaml
kustomize/arkmq-operator/overlays/prod/private-images.patch.yaml"
    ;;
  zookeeper)
    old_zookeeper_version=$(yq -r '.zookeeper.version' "$release")
    zookeeper_base="$stage/kustomize/zookeeper/base"
    old_zookeeper_image=$(yq -r \
      '.spec.template.spec.containers[] | select(.name == "zookeeper") | .image' \
      "$zookeeper_base/statefulset.yaml")
    old_zookeeper_tagged_image=${old_zookeeper_image%@*}
    zookeeper_repository=${old_zookeeper_tagged_image%:*}
    new_zookeeper_image="$zookeeper_repository:$version@$image_digest"
    old_zookeeper_os_id=$(yq -r '.zookeeper.image.baseOs.id' "$release")
    old_zookeeper_os_version=$(yq -r '.zookeeper.image.baseOs.versionId' "$release")
    old_zookeeper_digest=$(yq -r '.zookeeper.image.digest' "$release")
    replace_literal "$release" \
      "zookeeper:
  version: $old_zookeeper_version
  image:
    digest: $old_zookeeper_digest
    baseOs:
      id: $old_zookeeper_os_id
      versionId: $old_zookeeper_os_version" \
      "zookeeper:
  version: $version
  image:
    digest: $image_digest
    baseOs:
      id: $image_os_id
      versionId: $image_os_version"
    replace_literal "$zookeeper_base/statefulset.yaml" \
      "$old_zookeeper_image" "$new_zookeeper_image"
    replace_literal "$zookeeper_base/statefulset.yaml" \
      "        app.kubernetes.io/name: zookeeper
        app.kubernetes.io/version: $old_zookeeper_version
        app.kubernetes.io/managed-by: kustomize" \
      "        app.kubernetes.io/name: zookeeper
        app.kubernetes.io/version: $version
        app.kubernetes.io/managed-by: kustomize"
    replace_literal "$zookeeper_base/kustomization.yaml" \
      "      app.kubernetes.io/version: $old_zookeeper_version" \
      "      app.kubernetes.io/version: $version"
    changed_files="$changed_files
kustomize/zookeeper/base/kustomization.yaml
kustomize/zookeeper/base/statefulset.yaml"
    ;;
  operator)
    old_operator_version=$(yq -r '.operator.version' "$release")
    old_chart_digest=$(yq -r '.operator.chart.ociDigest' "$release")
    old_chart_artifact_sha256=$(yq -r '.operator.chart.artifactSha256' "$release")
    old_manifest_sha256=$(yq -r '.operator.manifest.sha256' "$release")
    old_image_digest=$(yq -r '.operator.image.upstreamDigest' "$release")
    old_operator_os_id=$(yq -r '.operator.image.baseOs.id' "$release")
    old_operator_os_version=$(yq -r '.operator.image.baseOs.versionId' "$release")
    if command -v sha256sum >/dev/null 2>&1; then
      chart_artifact_sha256=$(sha256sum "$chart_artifact" | awk '{print $1}')
    else
      chart_artifact_sha256=$(shasum -a 256 "$chart_artifact" | awk '{print $1}')
    fi
    replace_literal "$release" \
      "operator:
  version: $old_operator_version" \
      "operator:
  version: $version"
    replace_literal "$release" \
      "    version: $old_operator_version
    ociDigest:" \
      "    version: $version
    ociDigest:"
    replace_literal "$release" \
      "/releases/download/v$old_operator_version/" \
      "/releases/download/v$version/"
    replace_literal "$release" "$old_chart_digest" "$chart_oci_digest"
    replace_literal "$release" "$old_chart_artifact_sha256" "$chart_artifact_sha256"
    replace_literal "$release" "$old_manifest_sha256" "$manifest_sha256"
    replace_literal "$release" \
      "  image:
    upstreamDigest: $old_image_digest
    baseOs:
      id: $old_operator_os_id
      versionId: $old_operator_os_version" \
      "  image:
    upstreamDigest: $image_digest
    baseOs:
      id: $image_os_id
      versionId: $image_os_version"
    replace_literal "$stage/kustomize/arkmq-operator/base/kustomization.yaml" "$old_operator_version" "$version"
    replace_literal "$stage/kustomize/arkmq-operator/base/values.yaml" "$old_operator_version" "$version"
    for environment in test nonprod prod; do
      replace_literal "$stage/kustomize/arkmq-operator/overlays/$environment/private-images.patch.yaml" \
        "/arkmq-operator:$old_operator_version" "/arkmq-operator:$version"
      replace_literal "$stage/kustomize/arkmq-operator/overlays/$environment/private-images.patch.yaml" \
        "@$old_image_digest" "@$image_digest"
    done
    changed_files="$changed_files
kustomize/arkmq-operator/base/kustomization.yaml
kustomize/arkmq-operator/base/values.yaml
kustomize/arkmq-operator/overlays/test/private-images.patch.yaml
kustomize/arkmq-operator/overlays/nonprod/private-images.patch.yaml
kustomize/arkmq-operator/overlays/prod/private-images.patch.yaml"
    ;;
esac

if [[ "$component" == operator || "$component" == broker ]]; then
  ARKMQ_UPSTREAM_CHART="$chart_artifact" "$stage/scripts/validate-release.sh"
else
  "$stage/scripts/validate-release.sh"
fi

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
  if [[ "$component" == operator || "$component" == broker ]]; then
    ARKMQ_UPSTREAM_CHART="$chart_artifact" "$script_dir/validate-release.sh"
  else
    "$script_dir/validate-release.sh"
  fi
  printf '%s\n' 'upgrade files written; review the diff, mirror artifacts, and run repository validation before committing'
else
  printf '%s\n' 'dry run only; rerun the same command with --write after reviewing this diff'
fi
