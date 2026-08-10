#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
release_file="$repo_root/releases/current.yaml"

while (($#)); do
  case "$1" in
    --release-file) release_file=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for command_name in helm yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done
[[ -f "$release_file" ]] || {
  printf 'release manifest not found: %s\n' "$release_file" >&2
  exit 1
}

errors=0
error() {
  printf 'release validation: %s\n' "$1" >&2
  errors=$((errors + 1))
}

assert_equal() {
  description=$1
  actual=$2
  expected=$3
  [[ "$actual" == "$expected" ]] || error "$description: expected $expected, got $actual"
}

assert_keys() {
  path=$1
  expected=$2
  actual=$(yq -r "$path | keys | sort | join(\",\")" "$release_file" 2>/dev/null || true)
  assert_equal "$path keys" "$actual" "$expected"
}

assert_pattern() {
  description=$1
  value=$2
  pattern=$3
  [[ "$value" =~ $pattern ]] || error "$description has invalid format: $value"
}

# Keep the release contract dependency-free so it works on an offline laptop.
assert_keys '.platform' 'kubernetesVersion'
assert_keys '.operator' 'image,manifest,vendoredChartVersion,version,wrapperChartVersion'
assert_keys '.operator.manifest' 'sha256,url'
assert_keys '.' 'broker,operator,platform,schemaVersion,zookeeper'
assert_keys '.operator.image' 'upstreamDigest'
assert_keys '.broker' 'version'
assert_keys '.zookeeper' 'version'
assert_equal 'schemaVersion' "$(yq -r '.schemaVersion // ""' "$release_file")" 'releases.artemis.apache.org/v1'

version_pattern='^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$'
chart_version_pattern='^[0-9]+\.[0-9]+\.[0-9]+[-.+0-9A-Za-z]*$'
digest_pattern='^sha256:[a-f0-9]{64}$'
hex_pattern='^[a-f0-9]{64}$'

operator_version=$(yq -r '.operator.version // ""' "$release_file")
wrapper_chart_version=$(yq -r '.operator.wrapperChartVersion // ""' "$release_file")
vendored_chart_version=$(yq -r '.operator.vendoredChartVersion // ""' "$release_file")
operator_manifest_url=$(yq -r '.operator.manifest.url // ""' "$release_file")
operator_manifest_sha256=$(yq -r '.operator.manifest.sha256 // ""' "$release_file")
operator_upstream_digest=$(yq -r '.operator.image.upstreamDigest // ""' "$release_file")
broker_version=$(yq -r '.broker.version // ""' "$release_file")
zookeeper_version=$(yq -r '.zookeeper.version // ""' "$release_file")
operator_image_tag=$operator_version
broker_image_tag="artemis.$broker_version"
zookeeper_image_tag=$zookeeper_version

for entry in \
  "operator.version:$operator_version" \
  "platform.kubernetesVersion:$(yq -r '.platform.kubernetesVersion // ""' "$release_file")" \
  "broker.version:$broker_version" \
  "zookeeper.version:$zookeeper_version"; do
  assert_pattern "${entry%%:*}" "${entry#*:}" "$version_pattern"
done
assert_pattern 'operator.wrapperChartVersion' "$wrapper_chart_version" "$chart_version_pattern"
assert_pattern 'operator.vendoredChartVersion' "$vendored_chart_version" "$chart_version_pattern"
assert_pattern 'operator.manifest.sha256' "$operator_manifest_sha256" "$hex_pattern"
assert_pattern 'operator.image.upstreamDigest' "$operator_upstream_digest" "$digest_pattern"
[[ "$operator_manifest_url" == https://* ]] || error "operator.manifest.url must use https: $operator_manifest_url"
[[ "$operator_manifest_url" == *"/v$operator_version/"* ]] || \
  error "operator.manifest.url does not select operator.version $operator_version"

chart="$repo_root/charts/arkmq-operator/Chart.yaml"
values="$repo_root/charts/arkmq-operator/values.yaml"
vendor_chart="$repo_root/charts/arkmq-operator/vendor/arkmq-org-broker-operator/Chart.yaml"
vendor_values="$repo_root/charts/arkmq-operator/vendor/arkmq-org-broker-operator/values.yaml"
vendor_lock="$repo_root/charts/arkmq-operator/vendor/upstream.lock.yaml"
assert_equal 'wrapper Chart.yaml version' "$(yq -r '.version' "$chart")" "$wrapper_chart_version"
assert_equal 'wrapper Chart.yaml appVersion' "$(yq -r '.appVersion' "$chart")" "$operator_version"
assert_equal 'wrapper dependency version' \
  "$(yq -r '.dependencies[] | select(.name == "arkmq-org-broker-operator") | .version' "$chart")" \
  "$vendored_chart_version"
assert_equal 'vendored chart version' "$(yq -r '.version' "$vendor_chart")" "$vendored_chart_version"
assert_equal 'vendored chart appVersion' "$(yq -r '.appVersion' "$vendor_chart")" "$operator_version"
if [[ -f "$vendor_lock" ]]; then
  assert_equal 'vendor lock upstream version' \
    "$(yq -r '.spec.upstream.version' "$vendor_lock")" "$operator_version"
  assert_equal 'vendor lock enterprise version' \
    "$(yq -r '.spec.enterprise.version' "$vendor_lock")" "$vendored_chart_version"
  assert_pattern 'vendor lock OCI reference' \
    "$(yq -r '.spec.upstream.ociReference // ""' "$vendor_lock")" '^oci://.+'
  assert_pattern 'vendor lock OCI digest' \
    "$(yq -r '.spec.upstream.ociDigest // ""' "$vendor_lock")" "$digest_pattern"
  assert_pattern 'vendor lock artifact checksum' \
    "$(yq -r '.spec.upstream.artifactSha256 // ""' "$vendor_lock")" "$hex_pattern"
  locked_patches=$(yq -r '.spec.enterprise.patches[]?' "$vendor_lock" | sort)
  actual_patches=$(find "$(dirname -- "$vendor_lock")/patches" -maxdepth 1 -type f -name '*.patch' -print | \
    sed "s#^$(dirname -- "$vendor_lock")/##" | sort)
  assert_equal 'vendor lock patch inventory' "$actual_patches" "$locked_patches"
  while IFS= read -r relative_patch; do
    [[ -n "$relative_patch" ]] || continue
    case "$relative_patch" in
      patches/*.patch) ;;
      *) error "vendor lock contains invalid patch path: $relative_patch"; continue ;;
    esac
    [[ -f "$(dirname -- "$vendor_lock")/$relative_patch" ]] || \
      error "vendor lock patch is missing: $relative_patch"
  done <<< "$locked_patches"
else
  error 'vendor lock is missing'
fi
assert_equal 'vendored operator image tag' \
  "$(yq -r '.controllerManager.manager.image.tag' "$vendor_values")" "$operator_image_tag"
assert_equal 'wrapper operator image tag' \
  "$(yq -r '."arkmq-org-broker-operator".controllerManager.manager.image.tag' "$values")" "$operator_image_tag"

broker_compact=${broker_version//./}
for family in activemqArtemisBrokerInit activemqArtemisBrokerKubernetes; do
  vendor_key="$family$broker_compact"
  assert_equal "vendored operator $vendor_key support" \
    "$(FAMILY="$vendor_key" yq -r '.controllerManager.manager.relatedImages | has(strenv(FAMILY))' "$vendor_values")" \
    true
  assert_equal "wrapper $family$broker_compact tag" \
    "$(FAMILY="$family$broker_compact" yq -r '."arkmq-org-broker-operator".controllerManager.manager.relatedImages[strenv(FAMILY)].tag // ""' "$values")" \
    "$broker_image_tag"
done

render_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-release-validation.XXXXXX")
trap 'rm -rf "$render_dir"' EXIT
cp -R "$repo_root/charts/arkmq-operator" "$render_dir/chart"
if helm dependency build "$render_dir/chart" >/dev/null && \
   helm template release-validation "$render_dir/chart" \
     --set-string global.requiredLabels.env=test > "$render_dir/operator.yaml"; then
  for image_kind in Init Kubernetes; do
    env_name="RELATED_IMAGE_ActiveMQ_Artemis_Broker_${image_kind}_$broker_compact"
    assert_equal "rendered operator $env_name count" \
      "$(ENV_NAME="$env_name" yq eval-all -r '[.] | [.[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env[] | select(.name == strenv(ENV_NAME))] | length' "$render_dir/operator.yaml")" \
      1
  done
else
  error 'operator wrapper did not render with the central release'
fi

for environment in test nonprod prod; do
  application="$repo_root/argocd/bootstrap/$environment/operator-application.yaml"
  tag_override_count=$(yq -r \
    '[.spec.source.helm.parameters[]? | select(.name | test("\\.tag$"))] | length' \
    "$application")
  assert_equal "$environment operator tag override count" "$tag_override_count" 0
done

# These charts are generated consumers too. prepare-upgrade.sh rewrites the
# broker and ZooKeeper fields; operator upgrades also require a vendor rebase.
assert_equal 'Artemis chart broker version' \
  "$(yq -r '.broker.version' "$repo_root/charts/artemis-ha/values.yaml")" "$broker_version"
assert_equal 'ZooKeeper chart image tag' \
  "$(yq -r '.image.tag' "$repo_root/charts/zookeeper/values.yaml")" "$zookeeper_image_tag"

if ((errors)); then
  printf 'release validation: FAIL (%d errors)\n' "$errors" >&2
  exit 1
fi
printf 'release validation: PASS (operator %s, broker %s, ZooKeeper %s)\n' \
  "$operator_version" "$broker_version" "$zookeeper_version"
