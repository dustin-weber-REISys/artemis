#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
component=''
version=''
write=false
image_tag=''
init_image_tag=''
runtime_image_tag=''
chart_artifact=''
baseline_chart_artifact=''
chart_oci_digest=''
manifest_sha256=''
render_diff=''

usage() {
  cat <<'USAGE'
Usage:
  prepare-upgrade.sh --component kubernetes --version VERSION [--write]
  prepare-upgrade.sh --component broker --version VERSION \
    --chart-artifact CURRENT-OPERATOR-CHART.tgz \
    [--init-image-tag TAG] [--runtime-image-tag TAG] [--write]
  prepare-upgrade.sh --component zookeeper --version VERSION \
    [--image-tag TAG] [--write]
  prepare-upgrade.sh --component operator --version VERSION \
    --baseline-chart-artifact CURRENT-CHART.tgz \
    --chart-artifact CANDIDATE-CHART.tgz --chart-oci-digest sha256:HEX \
    --manifest-sha256 HEX [--image-tag TAG] [--write]

The default is a dry run that validates a staged copy and prints the exact
diff. --write copies only those validated release/generated files back into
the checkout. It does not download artifacts, mirror images, commit, or deploy.
Container images are selected by unique, immutable ECR tags. Image tags default
to VERSION for operator and ZooKeeper, and artemis.VERSION for broker images.
Pass an explicit image tag when an OS-only rebuild keeps the application version.
Operator upgrades consume the unmodified upstream chart. The chart package,
OCI digest, and manifest checksum are required inputs.
Operator and broker previews write a canonical full render diff for all three
environments under reports/ by default; override it with --render-diff FILE.
USAGE
}

while (($#)); do
  case "$1" in
    --component) component=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --image-tag) image_tag=$2; shift 2 ;;
    --init-image-tag) init_image_tag=$2; shift 2 ;;
    --runtime-image-tag) runtime_image_tag=$2; shift 2 ;;
    --chart-artifact) chart_artifact=$2; shift 2 ;;
    --baseline-chart-artifact) baseline_chart_artifact=$2; shift 2 ;;
    --chart-oci-digest) chart_oci_digest=$2; shift 2 ;;
    --manifest-sha256) manifest_sha256=$2; shift 2 ;;
    --render-diff) render_diff=$2; shift 2 ;;
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
image_tag_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
require_image_tag() {
  option_name=$1
  option_value=$2
  [[ "$option_value" =~ $image_tag_pattern ]] || {
    printf 'invalid or missing %s: %s\n' "$option_name" "$option_value" >&2
    exit 2
  }
}
if [[ "$component" == zookeeper ]]; then
  image_tag=${image_tag:-$version}
  require_image_tag --image-tag "$image_tag"
elif [[ "$component" == operator ]]; then
  [[ -f "$chart_artifact" ]] || { printf '%s\n' 'operator upgrades require --chart-artifact CHART.tgz' >&2; exit 2; }
  [[ -f "$baseline_chart_artifact" ]] || { printf '%s\n' 'operator upgrades require --baseline-chart-artifact CURRENT-CHART.tgz' >&2; exit 2; }
  [[ "$chart_oci_digest" =~ $digest_pattern ]] || { printf '%s\n' 'operator upgrades require --chart-oci-digest sha256:HEX' >&2; exit 2; }
  [[ "$manifest_sha256" =~ $hex_pattern ]] || { printf '%s\n' 'operator upgrades require --manifest-sha256 HEX' >&2; exit 2; }
  image_tag=${image_tag:-$version}
  require_image_tag --image-tag "$image_tag"
elif [[ "$component" == broker ]]; then
  [[ -f "$chart_artifact" ]] || { printf '%s\n' 'broker upgrades require --chart-artifact for operator compatibility validation' >&2; exit 2; }
  init_image_tag=${init_image_tag:-artemis.$version}
  runtime_image_tag=${runtime_image_tag:-artemis.$version}
  if [[ -n "$image_tag" || -n "$chart_oci_digest" || -n "$manifest_sha256" ]]; then
    printf '%s\n' 'generic image/chart inputs are valid only for operator or ZooKeeper upgrades' >&2
    exit 2
  fi
  require_image_tag --init-image-tag "$init_image_tag"
  require_image_tag --runtime-image-tag "$runtime_image_tag"
fi
if [[ "$component" != operator && "$component" != broker && ( -n "$chart_artifact" || -n "$baseline_chart_artifact" || -n "$chart_oci_digest" || -n "$manifest_sha256" ) ]]; then
  printf '%s\n' 'chart inputs are only valid for operator or broker upgrades' >&2
  exit 2
fi
if [[ "$component" != operator && -n "$baseline_chart_artifact" ]]; then
  printf '%s\n' '--baseline-chart-artifact is valid only for operator upgrades' >&2
  exit 2
fi
if [[ "$component" != operator && "$component" != zookeeper && -n "$image_tag" ]]; then
  printf '%s\n' 'image tags are valid only for operator or ZooKeeper upgrades' >&2
  exit 2
fi
if [[ "$component" != broker && ( -n "$init_image_tag" || -n "$runtime_image_tag" ) ]]; then
  printf '%s\n' 'init/runtime image tags are valid only for broker upgrades' >&2
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
    old_init_image_tag=$(yq -r '.broker.images.init.tag' "$release")
    old_runtime_image_tag=$(yq -r '.broker.images.runtime.tag' "$release")
    old_compact=${old_version//./}
    new_compact=${version//./}
    replace_literal "$release" \
      "broker:
  version: $old_version
  images:
    init:
      tag: $old_init_image_tag
    runtime:
      tag: $old_runtime_image_tag" \
      "broker:
  version: $version
  images:
    init:
      tag: $init_image_tag
    runtime:
      tag: $runtime_image_tag"
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
      replace_literal "$image_patch" "$old_compact" "$new_compact"
      replace_literal "$image_patch" \
        "/activemq-artemis-broker-init:$old_init_image_tag" \
        "/activemq-artemis-broker-init:$init_image_tag"
      replace_literal "$image_patch" \
        "/activemq-artemis-broker-kubernetes:$old_runtime_image_tag" \
        "/activemq-artemis-broker-kubernetes:$runtime_image_tag"
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
    zookeeper_repository=${old_zookeeper_image%:*}
    old_zookeeper_image_tag=$(yq -r '.zookeeper.image.tag' "$release")
    new_zookeeper_image="$zookeeper_repository:$image_tag"
    replace_literal "$release" \
      "zookeeper:
  version: $old_zookeeper_version
  image:
    tag: $old_zookeeper_image_tag" \
      "zookeeper:
  version: $version
  image:
    tag: $image_tag"
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
    old_image_tag=$(yq -r '.operator.image.tag' "$release")
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
    replace_literal "$release" \
      "    ociDigest: $old_chart_digest" \
      "    ociDigest: $chart_oci_digest"
    replace_literal "$release" "$old_chart_artifact_sha256" "$chart_artifact_sha256"
    replace_literal "$release" "$old_manifest_sha256" "$manifest_sha256"
    replace_literal "$release" \
      "  image:
    tag: $old_image_tag" \
      "  image:
    tag: $image_tag"
    replace_literal "$stage/kustomize/arkmq-operator/base/kustomization.yaml" "$old_operator_version" "$version"
    replace_literal "$stage/kustomize/arkmq-operator/base/values.yaml" \
      "      tag: $old_image_tag" "      tag: $image_tag"
    for environment in test nonprod prod; do
      replace_literal "$stage/kustomize/arkmq-operator/overlays/$environment/private-images.patch.yaml" \
        "/arkmq-operator:$old_image_tag" "/arkmq-operator:$image_tag"
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

if [[ "$component" == operator || "$component" == broker ]]; then
  if [[ -z "$render_diff" ]]; then
    render_diff="$repo_root/../reports/arkmq-operator-$component-$version-render.diff"
  fi
  baseline_artifact=$chart_artifact
  if [[ "$component" == operator ]]; then
    baseline_artifact=$baseline_chart_artifact
  fi
  "$stage/scripts/diff-arkmq-operator.sh" \
    --baseline-gitops "$repo_root" \
    --candidate-gitops "$stage" \
    --baseline-artifact "$baseline_artifact" \
    --candidate-artifact "$chart_artifact" \
    --output "$render_diff"
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
