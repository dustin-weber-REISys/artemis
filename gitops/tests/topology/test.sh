#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
validator="$repo_root/scripts/validate-topology.sh"
topology_dir="$repo_root/argocd/topology"
bootstrap_dir="$repo_root/argocd/bootstrap"

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-topology-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

"$validator" \
  --topology-dir "$topology_dir" \
  --bootstrap-dir "$bootstrap_dir" \
  --report "$temp_dir/baseline-report.json" >/dev/null

assert_topology_rejected() {
  case_name=$1
  environment=$2
  mutation=$3
  expected_diagnostic=$4
  candidate_dir="$temp_dir/$case_name-topology"
  output="$temp_dir/$case_name.out"

  cp -R "$topology_dir" "$candidate_dir"
  yq -i "$mutation" "$candidate_dir/$environment.yaml"

  if "$validator" \
      --topology-dir "$candidate_dir" \
      --bootstrap-dir "$bootstrap_dir" \
      --report "$temp_dir/$case_name-report.json" >"$output" 2>&1; then
    printf 'topology validator accepted invalid topology case: %s\n' "$case_name" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_diagnostic" "$output"; then
    printf 'topology validator did not report the expected %s diagnostic\n' "$case_name" >&2
    sed -n '1,160p' "$output" >&2
    exit 1
  fi
}

assert_bootstrap_rejected() {
  case_name=$1
  environment=$2
  file_name=$3
  mutation=$4
  expected_diagnostic=$5
  candidate_dir="$temp_dir/$case_name-bootstrap"
  output="$temp_dir/$case_name.out"

  cp -R "$bootstrap_dir" "$candidate_dir"
  yq -i "$mutation" "$candidate_dir/$environment/$file_name"

  if "$validator" \
      --topology-dir "$topology_dir" \
      --bootstrap-dir "$candidate_dir" \
      --report "$temp_dir/$case_name-report.json" >"$output" 2>&1; then
    printf 'topology validator accepted invalid bootstrap case: %s\n' "$case_name" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_diagnostic" "$output"; then
    printf 'topology validator did not report the expected %s diagnostic\n' "$case_name" >&2
    sed -n '1,160p' "$output" >&2
    exit 1
  fi
}

assert_yaml_value() {
  description=$1
  expression=$2
  file=$3
  expected=$4
  actual=$(yq -r "$expression" "$file")
  if [[ "$actual" != "$expected" ]]; then
    printf '%s: expected %s, got %s\n' "$description" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_topology_rejected \
  duplicate-namespace \
  test \
  '.brokerPairs[1].workloadNamespace = .brokerPairs[0].workloadNamespace' \
  'unique workloadNamespace count: expected 14, got 13'

assert_topology_rejected \
  duplicate-broker-pair-name \
  nonprod \
  '.brokerPairs[2].brokerPairName = .brokerPairs[1].brokerPairName' \
  'unique brokerPairName count: expected 14, got 13'

assert_topology_rejected \
  duplicate-coordination-id \
  prod \
  '.brokerPairs[1].coordinationId = .brokerPairs[0].coordinationId' \
  'unique coordinationId count: expected 14, got 13'

assert_topology_rejected \
  duplicate-management-host \
  prod \
  '.brokerPairs[1].managementHost = .brokerPairs[0].managementHost' \
  'unique managementHost count: expected 14, got 13'

assert_topology_rejected \
  invalid-coordination-id \
  prod \
  '.brokerPairs[0].coordinationId = "pe-pair"' \
  'prod invalid coordination ID count: expected 0, got 1'

assert_topology_rejected \
  missing-broker-pair \
  nonprod \
  'del(.brokerPairs[3])' \
  'nonprod broker pair count: expected 4, got 3'

assert_topology_rejected \
  mismatched-environment \
  test \
  '.environment = "nonprod"' \
  'test topology environment: expected test, got nonprod'

assert_topology_rejected \
  wrong-name-prefix \
  test \
  '.brokerPairs[0].brokerPairName = "sky"' \
  'test broker-pair name prefix mismatch count: expected 0, got 1'

assert_topology_rejected \
  invalid-enabled-value \
  test \
  '.brokerPairs[0].enabled = "yes"' \
  'test invalid enabled value count: expected 0, got 1'

assert_bootstrap_rejected \
  singleton-operator-appset \
  test \
  operator-application.yaml \
  '.kind = "ApplicationSet"' \
  'test operator kind: expected Application, got ApplicationSet'

assert_bootstrap_rejected \
  remote-operator-destination \
  nonprod \
  operator-application.yaml \
  '.spec.destination.server = "https://remote.invalid"' \
  'nonprod operator local destination: expected https://kubernetes.default.svc, got https://remote.invalid'

assert_bootstrap_rejected \
  wrong-operator-chart \
  test \
  operator-application.yaml \
  '.spec.source.path = "gitops/charts/unapproved-operator"' \
  'test operator wrapper path: expected gitops/charts/arkmq-operator, got gitops/charts/unapproved-operator'

assert_bootstrap_rejected \
  wrong-operator-oci-repository \
  prod \
  operator-application.yaml \
  '.spec.source.repoURL = "https://example.invalid/unapproved.git"' \
  'prod operator Git repository: expected https://example.invalid/PLACEHOLDER_ORG/PLACEHOLDER_GITOPS_REPOSITORY.git, got https://example.invalid/unapproved.git'

assert_bootstrap_rejected \
  mismatched-operator-revision \
  prod \
  operator-application.yaml \
  '.spec.source.targetRevision = "other-revision"' \
  'prod operator Git revision: expected PLACEHOLDER_GITOPS_REVISION, got other-revision'

assert_bootstrap_rejected \
  namespaced-operator-rbac \
  test \
  operator-application.yaml \
  '(.spec.source.helm.parameters[] | select(.name == "arkmq-org-broker-operator.clusterScoped") | .value) = "false"' \
  'test operator cluster scope: expected true, got false'

assert_bootstrap_rejected \
  upstream-digest-on-private-operator-image \
  test \
  operator-application.yaml \
  '(.spec.source.helm.parameters[] | select(.name == "arkmq-org-broker-operator.controllerManager.manager.image.tag") | .value) = "2.2.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  'test operator private image tag: expected 2.2.0, got 2.2.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

assert_bootstrap_rejected \
  missing-operator-prune-last \
  test \
  operator-application.yaml \
  'del(.spec.syncPolicy.syncOptions[] | select(. == "PruneLast=true"))' \
  'test operator PruneLast migration option count: expected 1, got 0'

assert_bootstrap_rejected \
  wrong-topology-file \
  prod \
  artemis-workloads-applicationset.yaml \
  '.spec.generators[0].matrix.generators[0].git.files[0].path = "gitops/argocd/topology/nonprod.yaml"' \
  'prod workloads topology path: expected gitops/argocd/topology/prod.yaml, got gitops/argocd/topology/nonprod.yaml'

assert_bootstrap_rejected \
  missingkey-disabled \
  test \
  artemis-workloads-applicationset.yaml \
  '.spec.goTemplateOptions = []' \
  'test workloads missingkey=error option count: expected 1, got 0'

assert_bootstrap_rejected \
  enable-selector-removed \
  test \
  artemis-workloads-applicationset.yaml \
  'del(.spec.generators[0].selector)' \
  'test workloads enable selector: expected true, got '

assert_bootstrap_rejected \
  deletion-policy-weakened \
  prod \
  artemis-workloads-applicationset.yaml \
  '.spec.syncPolicy.applicationsSync = "sync"' \
  'prod workloads Application modification policy: expected create-update, got sync'

assert_bootstrap_rejected \
  pruning-disabled \
  nonprod \
  artemis-workloads-applicationset.yaml \
  '.spec.template.spec.syncPolicy.automated.prune = false' \
  'nonprod workloads automated prune: expected true, got false'

assert_bootstrap_rejected \
  wrong-project-oci-repository \
  prod \
  project.yaml \
  '.spec.sourceRepos += ["quay.io/arkmq-org/helm-charts"]' \
  'prod project approved sources'

assert_bootstrap_rejected \
  remote-project-destination \
  test \
  project.yaml \
  '.spec.destinations[0].server = "https://remote.invalid"' \
  'test project local destination count: expected 3, got 2'

assert_bootstrap_rejected \
  missing-project-cluster-resource \
  nonprod \
  project.yaml \
  'del(.spec.clusterResourceWhitelist[0])' \
  'nonprod project cluster resource allowlist'

assert_bootstrap_rejected \
  mismatched-zookeeper-revision \
  test \
  zookeeper-application.yaml \
  '.spec.source.targetRevision = "other-revision"' \
  'test ZooKeeper Git revision: expected PLACEHOLDER_GITOPS_REVISION, got other-revision'

assert_bootstrap_rejected \
  mismatched-workload-revision \
  nonprod \
  artemis-workloads-applicationset.yaml \
  '.spec.template.spec.source.targetRevision = "other-revision"' \
  'nonprod workloads source revision: expected PLACEHOLDER_GITOPS_REVISION, got other-revision'

expected_broker_pairs=$(printf '%s\n' \
  'nonprod:nonprod-pt' \
  'nonprod:nonprod-smktest-eut' \
  'nonprod:nonprod-trn' \
  'nonprod:nonprod-trn2' \
  'prod:prod-dm' \
  'prod:prod-pe' \
  'prod:prod-pp' \
  'prod:prod-pp-batch' \
  'prod:prod-pp-external' \
  'prod:prod-pr' \
  'prod:prod-pr-batch' \
  'prod:prod-pr-external' \
  'test:test-sky' \
  'test:test-sky2' | sort)
actual_broker_pairs=$(
  for environment in test nonprod prod; do
    ENVIRONMENT="$environment" yq -r \
      '.brokerPairs[] | strenv(ENVIRONMENT) + ":" + .brokerPairName' \
      "$topology_dir/$environment.yaml"
  done | sort
)
if [[ "$actual_broker_pairs" != "$expected_broker_pairs" ]]; then
  printf '%s\n' 'topology broker-pair identities do not match the required 2/4/8 topology' >&2
  exit 1
fi

if rg -n \
    'clusterServer|PLACEHOLDER_(TEST|NONPROD|PROD)_EKS_API_SERVER|workloadKey' \
    "$topology_dir" "$bootstrap_dir" >/dev/null; then
  printf '%s\n' 'cross-cluster or ambiguous topology data remains in the local bootstrap model' >&2
  exit 1
fi

for environment in test nonprod prod; do
  project="$bootstrap_dir/$environment/project.yaml"
  workloads="$bootstrap_dir/$environment/artemis-workloads-applicationset.yaml"
  operator="$bootstrap_dir/$environment/operator-application.yaml"
  zookeeper="$bootstrap_dir/$environment/zookeeper-application.yaml"

  assert_yaml_value \
    "$environment project kind" \
    '.kind' \
    "$project" \
    AppProject
  assert_yaml_value \
    "$environment project name" \
    '.metadata.name' \
    "$project" \
    messaging-platform
  assert_yaml_value \
    "$environment project sync wave" \
    '.metadata.annotations."argocd.argoproj.io/sync-wave"' \
    "$project" \
    -30
  assert_yaml_value \
    "$environment operator kind" \
    '.kind' \
    "$operator" \
    Application
  assert_yaml_value \
    "$environment ZooKeeper kind" \
    '.kind' \
    "$zookeeper" \
    Application
  assert_yaml_value \
    "$environment workload Application name" \
    '.spec.template.metadata.name' \
    "$workloads" \
    '{{.brokerPairName}}-artemis'
  assert_yaml_value \
    "$environment workload local destination" \
    '.spec.template.spec.destination.server' \
    "$workloads" \
    'https://kubernetes.default.svc'
  assert_yaml_value \
    "$environment shared ZooKeeper connection template" \
    '.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.connectString") | .value' \
    "$workloads" \
    '{{.environment}}-shared-zookeeper-zookeeper-client.{{.platformNamespace}}.svc.cluster.local:2181'
  assert_yaml_value \
    "$environment unique Curator namespace template" \
    '.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.curatorNamespace") | .value' \
    "$workloads" \
    'artemis/{{.environment}}/{{.brokerPairName}}'
  assert_yaml_value \
    "$environment pair-specific storage template" \
    '.spec.template.spec.source.helm.parameters[] | select(.name == "persistence.size") | .value' \
    "$workloads" \
    '{{.storageSize}}'
  assert_yaml_value \
    "$environment pair-specific management host template" \
    '.spec.template.spec.source.helm.parameters[] | select(.name == "console.ingress.host") | .value' \
    "$workloads" \
    '{{.managementHost}}'
  assert_yaml_value \
    "$environment pair-specific redirect URI template" \
    '.spec.template.spec.source.helm.parameters[] | select(.name == "keycloak.redirectUri") | .value' \
    "$workloads" \
    'https://{{.managementHost}}/console'
done

if [[ -f "$repo_root/argocd/topology/catalog.yaml" ]] \
    || find "$repo_root/argocd/applications" -type f -print -quit 2>/dev/null | grep -q .; then
  printf '%s\n' 'legacy central-Argo composition paths still exist' >&2
  exit 1
fi

printf '%s\n' 'topology validation tests passed'
