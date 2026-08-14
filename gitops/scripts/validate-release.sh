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

for command_name in yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done
if command -v kustomize >/dev/null 2>&1; then
  composition_render_command=(kustomize build)
elif command -v kubectl >/dev/null 2>&1; then
  composition_render_command=(kubectl kustomize)
else
  printf '%s\n' 'kustomize or kubectl with embedded Kustomize is required' >&2
  exit 2
fi
release_render_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-release-validation.XXXXXX")
trap 'rm -rf "$release_render_dir"' EXIT
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
assert_keys '.operator' 'chart,image,manifest,version'
assert_keys '.operator.chart' 'artifactSha256,name,ociDigest,repository,version'
assert_keys '.operator.manifest' 'sha256,url'
assert_keys '.' 'broker,operator,platform,schemaVersion,zookeeper'
assert_keys '.operator.image' 'tag'
assert_keys '.broker' 'images,version'
assert_keys '.broker.images' 'init,runtime'
assert_keys '.broker.images.init' 'tag'
assert_keys '.broker.images.runtime' 'tag'
assert_keys '.zookeeper' 'image,version'
assert_keys '.zookeeper.image' 'tag'
assert_equal 'schemaVersion' "$(yq -r '.schemaVersion // ""' "$release_file")" 'releases.artemis.apache.org/v2'

version_pattern='^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$'
digest_pattern='^sha256:[a-f0-9]{64}$'
hex_pattern='^[a-f0-9]{64}$'

operator_version=$(yq -r '.operator.version // ""' "$release_file")
operator_chart_name=$(yq -r '.operator.chart.name // ""' "$release_file")
operator_chart_repository=$(yq -r '.operator.chart.repository // ""' "$release_file")
operator_chart_version=$(yq -r '.operator.chart.version // ""' "$release_file")
operator_chart_oci_digest=$(yq -r '.operator.chart.ociDigest // ""' "$release_file")
operator_chart_artifact_sha256=$(yq -r '.operator.chart.artifactSha256 // ""' "$release_file")
operator_manifest_url=$(yq -r '.operator.manifest.url // ""' "$release_file")
operator_manifest_sha256=$(yq -r '.operator.manifest.sha256 // ""' "$release_file")
operator_image_tag=$(yq -r '.operator.image.tag // ""' "$release_file")
broker_version=$(yq -r '.broker.version // ""' "$release_file")
zookeeper_version=$(yq -r '.zookeeper.version // ""' "$release_file")
broker_init_image_tag=$(yq -r '.broker.images.init.tag // ""' "$release_file")
broker_runtime_image_tag=$(yq -r '.broker.images.runtime.tag // ""' "$release_file")
zookeeper_image_tag=$(yq -r '.zookeeper.image.tag // ""' "$release_file")

for entry in \
  "operator.version:$operator_version" \
  "platform.kubernetesVersion:$(yq -r '.platform.kubernetesVersion // ""' "$release_file")" \
  "broker.version:$broker_version" \
  "zookeeper.version:$zookeeper_version"; do
  assert_pattern "${entry%%:*}" "${entry#*:}" "$version_pattern"
done
image_tag_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
for entry in \
  "operator.image.tag:$operator_image_tag" \
  "broker.images.init.tag:$broker_init_image_tag" \
  "broker.images.runtime.tag:$broker_runtime_image_tag" \
  "zookeeper.image.tag:$zookeeper_image_tag"; do
  assert_pattern "${entry%%:*}" "${entry#*:}" "$image_tag_pattern"
done
assert_equal 'operator chart name' "$operator_chart_name" 'arkmq-org-broker-operator'
assert_equal 'operator chart version' "$operator_chart_version" "$operator_version"
[[ "$operator_chart_repository" == oci://* ]] || \
  error "operator.chart.repository must use oci: $operator_chart_repository"
assert_pattern 'operator.chart.ociDigest' "$operator_chart_oci_digest" "$digest_pattern"
assert_pattern 'operator.chart.artifactSha256' "$operator_chart_artifact_sha256" "$hex_pattern"
assert_pattern 'operator.manifest.sha256' "$operator_manifest_sha256" "$hex_pattern"
[[ "$operator_manifest_url" == https://* ]] || error "operator.manifest.url must use https: $operator_manifest_url"
[[ "$operator_manifest_url" == *"/v$operator_version/"* ]] || \
  error "operator.manifest.url does not select operator.version $operator_version"

operator_base="$repo_root/kustomize/arkmq-operator/base"
operator_kustomization="$operator_base/kustomization.yaml"
operator_values="$operator_base/values.yaml"
assert_equal 'Kustomize operator chart name' \
  "$(yq -r '.helmCharts[0].name' "$operator_kustomization")" "$operator_chart_name"
assert_equal 'Kustomize operator chart repository' \
  "$(yq -r '.helmCharts[0].repo' "$operator_kustomization")" "$operator_chart_repository"
assert_equal 'Kustomize operator chart version' \
  "$(yq -r '.helmCharts[0].version' "$operator_kustomization")" "$operator_chart_version"
assert_equal 'Kustomize operator image tag' \
  "$(yq -r '.controllerManager.manager.image.tag' "$operator_values")" "$operator_image_tag"
assert_equal 'Kustomize operator cluster scope' \
  "$(yq -r '.clusterScoped' "$operator_values")" true

broker_compact=${broker_version//./}
for environment in test nonprod prod; do
  overlay="$repo_root/kustomize/arkmq-operator/overlays/$environment"
  image_patch="$overlay/private-images.patch.yaml"
  expected_ecr_repository=PLACEHOLDER_NONPROD_ECR_REPOSITORY
  if [[ "$environment" == prod ]]; then
    expected_ecr_repository=PLACEHOLDER_PROD_ECR_REPOSITORY
  fi
  assert_equal "$environment overlay environment label" \
    "$(yq -r '.labels[0].pairs.env' "$overlay/kustomization.yaml")" "$environment"
  assert_equal "$environment operator image" \
    "$(yq -r '.spec.template.spec.containers[] | select(.name == "manager") | .image' "$image_patch")" \
    "$expected_ecr_repository/arkmq-operator:$operator_image_tag"
  for image_kind in Init Kubernetes; do
    env_name="RELATED_IMAGE_ActiveMQ_Artemis_Broker_${image_kind}_$broker_compact"
    repository_suffix=activemq-artemis-broker-init
    expected_image_tag=$broker_init_image_tag
    if [[ "$image_kind" == Kubernetes ]]; then
      repository_suffix=activemq-artemis-broker-kubernetes
      expected_image_tag=$broker_runtime_image_tag
    fi
    assert_equal "$environment operator $env_name" \
      "$(ENV_NAME="$env_name" yq -r '.spec.template.spec.containers[] | select(.name == "manager") | .env[] | select(.name == strenv(ENV_NAME)) | .value' "$image_patch")" \
      "$expected_ecr_repository/$repository_suffix:$expected_image_tag"
  done
  application="$release_render_dir/composition-$environment.yaml"
  if ! "${composition_render_command[@]}" "$repo_root/argocd/bootstrap/$environment" > "$application"; then
    error "$environment cluster composition did not render"
    continue
  fi
  assert_equal "$environment operator Kustomize path" \
    "$(ENVIRONMENT="$environment" yq ea -r 'select(.kind == "Application" and .metadata.name == strenv(ENVIRONMENT) + "-arkmq-operator") | .spec.source.path' "$application")" \
    "gitops/kustomize/arkmq-operator/overlays/$environment"
  assert_equal "$environment operator Helm source count" \
    "$(ENVIRONMENT="$environment" yq ea -r 'select(.kind == "Application" and .metadata.name == strenv(ENVIRONMENT) + "-arkmq-operator") | [.spec.source.helm] | map(select(. != null)) | length' "$application")" 0
done

if [[ -n "${ARKMQ_UPSTREAM_CHART:-}" ]]; then
  render_dir="$release_render_dir/operator-artifact"
  mkdir -p "$render_dir"
  upstream_values="$render_dir/upstream-values.yaml"
  if tar -xOf "$ARKMQ_UPSTREAM_CHART" "$operator_chart_name/values.yaml" > "$upstream_values"; then
    for family in activemqArtemisBrokerInit activemqArtemisBrokerKubernetes; do
      related_image_key="$family$broker_compact"
      assert_equal "upstream chart $related_image_key support" \
        "$(RELATED_IMAGE_KEY="$related_image_key" yq -r '.controllerManager.manager.relatedImages | has(strenv(RELATED_IMAGE_KEY))' "$upstream_values")" \
        true
    done
  else
    error "upstream chart artifact does not contain $operator_chart_name/values.yaml"
  fi
  for environment in test nonprod prod; do
    rendered="$render_dir/operator-$environment.yaml"
    if "$repo_root/scripts/render-arkmq-operator.sh" \
      --environment "$environment" --artifact "$ARKMQ_UPSTREAM_CHART" > "$rendered"; then
      for image_kind in Init Kubernetes; do
        env_name="RELATED_IMAGE_ActiveMQ_Artemis_Broker_${image_kind}_$broker_compact"
        assert_equal "rendered $environment operator $env_name count" \
          "$(ENV_NAME="$env_name" yq eval-all -r '[.] | [.[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env[] | select(.name == strenv(ENV_NAME))] | length' "$rendered")" \
          1
      done
    else
      error "$environment operator Kustomize overlay did not render with the approved artifact"
    fi
  done
fi

# These deployable modules are generated consumers too. prepare-upgrade.sh
# rewrites the broker chart and the operator/ZooKeeper Kustomize release inputs.
assert_equal 'Artemis chart broker version' \
  "$(yq -r '.broker.version' "$repo_root/charts/artemis-ha/values.yaml")" "$broker_version"
zookeeper_base="$repo_root/kustomize/zookeeper/base"
zookeeper_image=$(yq -r \
  '.spec.template.spec.containers[] | select(.name == "zookeeper") | .image' \
  "$zookeeper_base/statefulset.yaml")
zookeeper_rendered_tag=${zookeeper_image##*:}
assert_equal 'ZooKeeper Kustomize image tag' "$zookeeper_rendered_tag" "$zookeeper_image_tag"
assert_equal 'ZooKeeper Kustomize version label' \
  "$(yq -r '.labels[0].pairs."app.kubernetes.io/version"' "$zookeeper_base/kustomization.yaml")" \
  "$zookeeper_version"
assert_equal 'ZooKeeper Pod version label' \
  "$(yq -r '.spec.template.metadata.labels."app.kubernetes.io/version"' "$zookeeper_base/statefulset.yaml")" \
  "$zookeeper_version"
# The former Helm-rendered PVC template is immutable. These historical values
# deliberately stay pinned while current release labels and pod images advance.
assert_equal 'ZooKeeper PVC legacy chart label' \
  "$(yq -r '.spec.volumeClaimTemplates[0].metadata.labels."helm.sh/chart"' "$zookeeper_base/statefulset.yaml")" \
  'zookeeper-0.1.0'
assert_equal 'ZooKeeper PVC legacy manager label' \
  "$(yq -r '.spec.volumeClaimTemplates[0].metadata.labels."app.kubernetes.io/managed-by"' "$zookeeper_base/statefulset.yaml")" \
  'Helm'
assert_equal 'ZooKeeper PVC legacy version label' \
  "$(yq -r '.spec.volumeClaimTemplates[0].metadata.labels."app.kubernetes.io/version"' "$zookeeper_base/statefulset.yaml")" \
  '3.9.5'
for environment in test nonprod prod; do
  overlay="$repo_root/kustomize/zookeeper/overlays/$environment/kustomization.yaml"
  expected_ecr_repository=PLACEHOLDER_NONPROD_ECR_REPOSITORY
  if [[ "$environment" == prod ]]; then
    expected_ecr_repository=PLACEHOLDER_PROD_ECR_REPOSITORY
  fi
  assert_equal "$environment ZooKeeper name prefix" \
    "$(yq -r '.namePrefix' "$overlay")" "$environment-"
  assert_equal "$environment ZooKeeper image repository" \
    "$(yq -r '.images[] | select(.name == "example.invalid/ecr-mirror/zookeeper") | .newName' "$overlay")" \
    "$expected_ecr_repository/zookeeper"
done

if ((errors)); then
  printf 'release validation: FAIL (%d errors)\n' "$errors" >&2
  exit 1
fi
printf 'release validation: PASS (operator %s, broker %s, ZooKeeper %s)\n' \
  "$operator_version" "$broker_version" "$zookeeper_version"
