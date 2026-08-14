#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
validator="$repo_root/scripts/validate-topology.sh"
topology_dir="$repo_root/argocd/topology"
effective_topology_dir="$repo_root/argocd/topology"
bootstrap_dir="$repo_root/argocd/bootstrap"
profile_dir="$repo_root/argocd/profiles"
environment_dir="$repo_root/environments"
workload_dir="$repo_root/workloads"
baseline="$repo_root/argocd/workload-cell-baseline.yaml"
composer="$repo_root/scripts/compose-topology.sh"

for command_name in yq kubectl helm; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required for topology regression tests\n' "$command_name" >&2
    exit 2
  }
done

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-composition-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

run_validator() {
  local topology=$1 bootstrap=$2 profiles=$3 environments=$4 workloads=$5 output=$6
  local selected_baseline=${7:-$baseline} effective=${8:-$effective_topology_dir}
  "$validator" \
    --topology-dir "$topology" \
    --topology-dir "$effective" \
    --bootstrap-dir "$bootstrap" \
    --profile-dir "$profiles" \
    --environment-dir "$environments" \
    --workload-dir "$workloads" \
    --baseline "$selected_baseline" \
    --report "$temp_dir/report.json" >"$output" 2>&1
}

compose_all() {
  local selected_baseline=$1 topology=$2 effective=$3 environment
  mkdir -p "$effective"
  for environment in test nonprod prod; do
    "$composer" \
      --baseline "$selected_baseline" \
      --topology "$topology/$environment.yaml" \
      --output "$effective/$environment.yaml"
  done
}

base_output="$temp_dir/base.out"
run_validator "$topology_dir" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$workload_dir" "$base_output"

assert_catalog_rejected() {
  local case_name=$1 environment=$2 expression=$3 expected=$4
  local candidate="$temp_dir/$case_name-topology" output="$temp_dir/$case_name.out"
  cp -R "$topology_dir" "$candidate"
  yq -i "$expression" "$candidate/$environment.yaml"
  if run_validator "$candidate" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$workload_dir" "$output"; then
    printf 'validator accepted invalid Workload Cell catalog case: %s\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    printf 'validator did not report expected diagnostic for %s: %s\n' "$case_name" "$expected" >&2
    sed -n '1,100p' "$output" >&2
    exit 1
  }
}

assert_baseline_rejected() {
  local case_name=$1 expression=$2 expected=$3
  local candidate="$temp_dir/$case_name-baseline.yaml" output="$temp_dir/$case_name.out"
  cp "$baseline" "$candidate"
  yq -i "$expression" "$candidate"
  if run_validator "$topology_dir" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$workload_dir" "$output" "$candidate"; then
    printf 'validator accepted invalid Workload Cell baseline case: %s\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    printf 'validator did not report expected diagnostic for %s: %s\n' "$case_name" "$expected" >&2
    sed -n '1,100p' "$output" >&2
    exit 1
  }
}

assert_bootstrap_rejected() {
  local case_name=$1 file=$2 expression=$3 expected=$4
  local candidate="$temp_dir/$case_name-bootstrap" output="$temp_dir/$case_name.out"
  cp -R "$bootstrap_dir" "$candidate"
  yq -i "$expression" "$candidate/$file"
  if run_validator "$topology_dir" "$candidate" "$profile_dir" "$environment_dir" "$workload_dir" "$output"; then
    printf 'validator accepted invalid rendered composition case: %s\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    printf 'validator did not report expected diagnostic for %s: %s\n' "$case_name" "$expected" >&2
    sed -n '1,100p' "$output" >&2
    exit 1
  }
}

assert_profile_rejected() {
  local case_name=$1 file=$2 expression=$3 expected=$4
  local candidate="$temp_dir/$case_name-profiles" output="$temp_dir/$case_name.out"
  cp -R "$profile_dir" "$candidate"
  yq -i "$expression" "$candidate/$file"
  if run_validator "$topology_dir" "$bootstrap_dir" "$candidate" "$environment_dir" "$workload_dir" "$output"; then
    printf 'validator accepted invalid Profile case: %s\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    printf 'validator did not report expected diagnostic for %s: %s\n' "$case_name" "$expected" >&2
    sed -n '1,100p' "$output" >&2
    exit 1
  }
}

assert_environment_rejected() {
  local case_name=$1 environment=$2 expression=$3 expected=$4
  local candidate="$temp_dir/$case_name-environments" output="$temp_dir/$case_name.out"
  cp -R "$environment_dir" "$candidate"
  yq -i "$expression" "$candidate/$environment/artemis-values.yaml"
  if run_validator "$topology_dir" "$bootstrap_dir" "$profile_dir" "$candidate" "$workload_dir" "$output"; then
    printf 'validator accepted invalid environment ownership case: %s\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    printf 'validator did not report expected diagnostic for %s: %s\n' "$case_name" "$expected" >&2
    sed -n '1,100p' "$output" >&2
    exit 1
  }
}

assert_workload_rejected() {
  local case_name=$1 file=$2 expression=$3 expected=$4
  local candidate="$temp_dir/$case_name-workloads" output="$temp_dir/$case_name.out"
  cp -R "$workload_dir" "$candidate"
  yq -i "$expression" "$candidate/$file"
  if run_validator "$topology_dir" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$candidate" "$output"; then
    printf 'validator accepted invalid Workload Cell values case: %s\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    printf 'validator did not report expected diagnostic for %s: %s\n' "$case_name" "$expected" >&2
    sed -n '1,100p' "$output" >&2
    exit 1
  }
}

assert_baseline_rejected duplicate-namespace \
  '.clusters.test.workloadCells."test-sky2".workloadNamespace = .clusters.test.workloadCells."test-sky".workloadNamespace' \
  'cluster test Workload Cell field workloadNamespace violates uniqueness rule'

assert_baseline_rejected duplicate-coordination \
  '.clusters.prod.workloadCells."prod-pp".coordinationId = .clusters.prod.workloadCells."prod-pe".coordinationId' \
  'cluster prod Workload Cell field coordinationId violates uniqueness rule'

assert_baseline_rejected unknown-profile \
  '.clusters.test.workloadCells."test-sky".profile = "unapproved"' \
  'cluster test Workload Cell test-sky field profile violates rule: unknown Profile: unapproved'

assert_catalog_rejected unsupported-feature test \
  '.workloadCellOverrides."test-sky".features.rawHelm = true' \
  'field features.rawHelm violates rule: Profile standard does not permit this override'

assert_catalog_rejected invalid-feature-type test \
  '.workloadCellOverrides."test-sky".features.expiryResources = "yes"' \
  'field features.expiryResources violates rule: must be a boolean'

assert_catalog_rejected invalid-feature-enum prod \
  '.workloadCellOverrides."prod-pe".features.diskGuardrail = "unsafe"' \
  'field features.diskGuardrail violates rule: value unsafe is not allowed by Profile standard'

assert_catalog_rejected arbitrary-helm-parameters test \
  '.workloadCellOverrides."test-sky".helmParameters = [{"name":"ha.allowFailback","value":"true"}]' \
  'field topologyKeys violates rule: allowed environment keys are'

assert_catalog_rejected per-cell-version test \
  '.workloadCellOverrides."test-sky".version = "9.9.9"' \
  'field topologyKeys violates rule: allowed environment keys are'

assert_baseline_rejected invalid-namespace \
  '.clusters.test.workloadCells."test-sky".workloadNamespace = "default"' \
  'field workloadNamespace violates rule: must equal artemis-int-sky'

assert_catalog_rejected changed-platform-namespace test \
  '.platformNamespace = "artemis-other"' \
  'cluster test topology platform namespace: expected artemis-platform, got artemis-other'

assert_catalog_rejected implicit-enabled test \
  '.workloadCellOverrides."test-sky".enabled = true' \
  'field enabled violates rule: must be a string'

assert_catalog_rejected missing-baseline-override nonprod \
  'del(.workloadCellOverrides."nonprod-pt")' \
  'baseline cells missing topology overrides: nonprod-pt'

assert_catalog_rejected stable-field-in-topology prod \
  '.workloadCellOverrides."prod-pe".managementHost = "artemis-new.example.invalid"' \
  'field topologyKeys violates rule: allowed environment keys are'

assert_baseline_rejected dynamic-field-in-baseline \
  '.clusters.test.workloadCells."test-sky".enabled = "true"' \
  'field baselineKeys violates rule: allowed stable keys are'

assert_bootstrap_rejected weakened-deletion-policy \
  'base/artemis-workloads-applicationset.yaml' \
  '.spec.syncPolicy.applicationsSync = "sync"' \
  'cluster test workloads Application modification policy: expected create-update, got sync'

assert_bootstrap_rejected changed-argocd-namespace \
  'base/project.yaml' \
  '.metadata.namespace = "gitops"' \
  'cluster test AppProject Argo CD namespace: expected argocd, got gitops'

assert_bootstrap_rejected remote-workload-destination \
  'base/artemis-workloads-applicationset.yaml' \
  '.spec.template.spec.destination.server = "https://remote.invalid"' \
  'cluster test workloads local destination: expected https://kubernetes.default.svc, got https://remote.invalid'

assert_bootstrap_rejected wrong-catalog-interface \
  'base/artemis-workloads-applicationset.yaml' \
  '.spec.generators[0].matrix.generators[1].list.elementsYaml = "{{ .brokerPairs | toJson }}"' \
  'cluster test workloads catalog expansion: expected {{ .workloadCells | toJson }}, got {{ .brokerPairs | toJson }}'

assert_profile_rejected protected-ha-setting standard/values.yaml \
  '.ha.retryReplicationWaitMs = 1' \
  'Workload Cell Profile standard field ha.retryReplicationWaitMs violates protected-setting ownership'

assert_profile_rejected protected-durability-setting standard/values.yaml \
  '.brokerProperties.durability.journalDatasync = false' \
  'Workload Cell Profile standard field brokerProperties.durability.journalDatasync violates protected-setting ownership'

assert_environment_rejected profile-environment-collision prod \
  '.brokerProperties.maxDiskUsage = 70' \
  'cluster prod environment field brokerProperties.maxDiskUsage violates cluster-integration ownership'

assert_workload_rejected protected-workload-version test/test-sky/artemis-values.yaml \
  '.broker.version = "9.9.9"' \
  'field workloadValues.broker.version violates rule: must be a pair-owned listener'

missing_workloads="$temp_dir/missing-workloads"
cp -R "$workload_dir" "$missing_workloads"
rm "$missing_workloads/test/test-sky/artemis-values.yaml"
if run_validator "$topology_dir" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$missing_workloads" "$temp_dir/missing-workload.out"; then
  printf '%s\n' 'validator accepted a missing Workload Cell values file' >&2
  exit 1
fi
grep -Fq 'cluster test Workload Cell test-sky field workloadValues violates rule: missing required values file' \
  "$temp_dir/missing-workload.out"

# Catalog growth adds stable identity to the baseline and environment state to
# the topology overlay without duplicating fields.
growth_baseline="$temp_dir/growth-baseline.yaml"
growth_topology="$temp_dir/growth-topology"
growth_effective="$temp_dir/growth-effective"
growth_workloads="$temp_dir/growth-workloads"
cp "$baseline" "$growth_baseline"
cp -R "$topology_dir" "$growth_topology"
cp -R "$workload_dir" "$growth_workloads"
mkdir -p "$growth_workloads/test/test-extra"
cp "$workload_dir/test/test-sky2/artemis-values.yaml" "$growth_workloads/test/test-extra/artemis-values.yaml"
yq -i '
  .clusters.test.workloadCells."test-extra" = {
    "workloadNamespace": "artemis-int-extra",
    "coordinationId": "test-extra-01",
    "logicalEnvironment": "EXTRA",
    "trafficClass": "internal",
    "managementHost": "artemis-test-extra.example.invalid",
    "storageSize": "20Gi",
    "profile": "standard"
  }
' "$growth_baseline"
yq -i '
  .workloadCellOverrides."test-extra" = {
    "resources": {
      "requests": {"cpu": "500m", "memory": "2Gi"},
      "limits": {"cpu": "1", "memory": "3Gi"}
    },
    "features": {},
    "enabled": "false"
  }
' "$growth_topology/test.yaml"
compose_all "$growth_baseline" "$growth_topology" "$growth_effective"
run_validator "$growth_topology" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$growth_workloads" "$temp_dir/growth.out" "$growth_baseline" "$growth_effective"

# An operational enablement changes only the topology overlay. A stale
# committed effective catalog is rejected until it is regenerated.
enabled_topology="$temp_dir/enabled-topology"
enabled_effective="$temp_dir/enabled-effective"
cp -R "$topology_dir" "$enabled_topology"
yq -i '.workloadCellOverrides."nonprod-trn".enabled = "true"' "$enabled_topology/nonprod.yaml"
if run_validator "$enabled_topology" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$workload_dir" "$temp_dir/stale-effective.out"; then
  printf '%s\n' 'validator accepted a stale generated effective topology' >&2
  exit 1
fi
grep -Fq 'cluster nonprod generated effective topology is stale' "$temp_dir/stale-effective.out"
compose_all "$baseline" "$enabled_topology" "$enabled_effective"
run_validator "$enabled_topology" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$workload_dir" "$temp_dir/enabled.out" "$baseline" "$enabled_effective"

# Both approved typed feature choices render through the shared template.
feature_topology="$temp_dir/feature-topology"
feature_effective="$temp_dir/feature-effective"
cp -R "$topology_dir" "$feature_topology"
yq -i '.workloadCellOverrides."test-sky".features.expiryResources = true' "$feature_topology/test.yaml"
compose_all "$baseline" "$feature_topology" "$feature_effective"
run_validator "$feature_topology" "$bootstrap_dir" "$profile_dir" "$environment_dir" "$workload_dir" "$temp_dir/feature.out" "$baseline" "$feature_effective"

# A single temporary root revision is injected once and reaches every child.
revision_bootstrap="$temp_dir/revision-bootstrap"
cp -R "$bootstrap_dir" "$revision_bootstrap"
yq -i '.metadata.annotations."composition.artemis.apache.org/git-revision" = "upgrade/platform-release"' \
  "$revision_bootstrap/test/cluster.patch.yaml"
run_validator "$topology_dir" "$revision_bootstrap" "$profile_dir" "$environment_dir" "$workload_dir" "$temp_dir/revision.out"
kubectl kustomize "$revision_bootstrap/test" > "$temp_dir/revision-rendered.yaml"
revision_values=$(yq ea -r '
  select(.kind == "Application") | .spec.source.targetRevision,
  select(.kind == "ApplicationSet") | .spec.generators[0].matrix.generators[0].git.revision,
  select(.kind == "ApplicationSet") | .spec.template.spec.source.targetRevision
' "$temp_dir/revision-rendered.yaml" | sed '/^---$/d' | sort -u)
[[ "$revision_values" == 'upgrade/platform-release' ]] || {
  printf 'root revision was not propagated uniformly: %s\n' "$revision_values" >&2
  exit 1
}

# The initial Profile is semantically neutral for current test behavior, and
# the derived Application and broker custom-resource identities stay stable.
helm template test-sky-artemis "$repo_root/charts/artemis-ha" \
  --namespace artemis-int-sky \
  -f "$profile_dir/standard/values.yaml" \
  -f "$environment_dir/test/artemis-values.yaml" \
  -f "$workload_dir/test/test-sky/artemis-values.yaml" \
  --set ha.coordinationId=test-sky-01 \
  --set ha.groupName=test-sky-group \
  --set zookeeper.connectString=test-shared-zookeeper-zookeeper-client.artemis-platform.svc.cluster.local:2181 \
  --set zookeeper.serviceNamespace=artemis-platform \
  --set zookeeper.curatorNamespace=artemis/test/test-sky \
  --set persistence.size=20Gi \
  --set-string broker.resources.requests.cpu=500m \
  --set-string broker.resources.requests.memory=2Gi \
  --set-string broker.resources.limits.cpu=1 \
  --set-string broker.resources.limits.memory=3Gi \
  --set brokerProperties.maxDiskUsage=90 \
  --set brokerProperties.addressSettings.expiry.enabled=false \
  --set console.ingress.host=artemis-test-sky.example.invalid \
  --set keycloak.redirectUri=https://artemis-test-sky.example.invalid/console \
  > "$temp_dir/test-sky.yaml"
asserted_broker_name=$(yq ea -r 'select(.kind == "ActiveMQArtemis") | .metadata.name' "$temp_dir/test-sky.yaml")
[[ "$asserted_broker_name" == test-sky-artemis-artemis-ha ]] || {
  printf 'broker identity changed: %s\n' "$asserted_broker_name" >&2
  exit 1
}

legacy_values="$temp_dir/legacy-test-values.yaml"
cp "$environment_dir/test/artemis-values.yaml" "$legacy_values"
yq -i '
  .broker.resources.requests.cpu = "500m"
  | .broker.resources.requests.memory = "2Gi"
  | .broker.resources.limits.cpu = "1"
  | .broker.resources.limits.memory = "3Gi"
' "$legacy_values"
helm template test-sky-artemis "$repo_root/charts/artemis-ha" \
  --namespace artemis-int-sky \
  -f "$legacy_values" \
  --set ha.coordinationId=test-sky-01 \
  --set ha.groupName=test-sky-group \
  --set zookeeper.connectString=test-shared-zookeeper-zookeeper-client.artemis-platform.svc.cluster.local:2181 \
  --set zookeeper.serviceNamespace=artemis-platform \
  --set zookeeper.curatorNamespace=artemis/test/test-sky \
  --set persistence.size=20Gi \
  --set console.ingress.host=artemis-test-sky.example.invalid \
  --set keycloak.redirectUri=https://artemis-test-sky.example.invalid/console \
  > "$temp_dir/test-sky-legacy.yaml"
cmp -s "$temp_dir/test-sky.yaml" "$temp_dir/test-sky-legacy.yaml" || {
  printf '%s\n' 'standard Profile changed the current test Workload Cell render' >&2
  diff -u "$temp_dir/test-sky-legacy.yaml" "$temp_dir/test-sky.yaml" >&2 || true
  exit 1
}

for environment in test nonprod prod; do
  rendered="$temp_dir/$environment-rendered.yaml"
  kubectl kustomize "$bootstrap_dir/$environment" > "$rendered"
  assert_count=$(yq ea -r '[.] | [.[] | select(.kind == "AppProject" or .kind == "Application" or .kind == "ApplicationSet")] | length' "$rendered")
  [[ "$assert_count" == 4 ]] || { printf 'unexpected rendered composition count for %s\n' "$environment" >&2; exit 1; }
done

printf '%s\n' 'rendered topology validation tests passed'
