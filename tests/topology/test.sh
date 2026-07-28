#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
validator="$repo_root/scripts/validate-topology.sh"
catalog="$repo_root/argocd/topology/catalog.yaml"
applications="$repo_root/argocd/applications"
artemis="$applications/artemis-workloads-applicationset.yaml"

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-topology-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

"$validator" \
  --catalog "$catalog" \
  --applications-dir "$applications" \
  --report "$temp_dir/baseline-report.json" >/dev/null

assert_catalog_rejected() {
  case_name=$1
  mutation=$2
  expected_diagnostic=$3
  candidate="$temp_dir/$case_name-catalog.yaml"
  output="$temp_dir/$case_name.out"

  cp "$catalog" "$candidate"
  yq -i "$mutation" "$candidate"

  if "$validator" \
      --catalog "$candidate" \
      --applications-dir "$applications" \
      --report "$temp_dir/$case_name-report.json" >"$output" 2>&1; then
    printf 'topology validator accepted invalid catalog case: %s\n' "$case_name" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_diagnostic" "$output"; then
    printf 'topology validator did not report the expected %s diagnostic\n' "$case_name" >&2
    sed -n '1,120p' "$output" >&2
    exit 1
  fi
}

assert_applicationset_rejected() {
  case_name=$1
  file_name=$2
  mutation=$3
  expected_diagnostic=$4
  candidate_dir="$temp_dir/$case_name-applications"
  output="$temp_dir/$case_name.out"

  cp -R "$applications" "$candidate_dir"
  yq -i "$mutation" "$candidate_dir/$file_name"

  if "$validator" \
      --catalog "$catalog" \
      --applications-dir "$candidate_dir" \
      --report "$temp_dir/$case_name-report.json" >"$output" 2>&1; then
    printf 'topology validator accepted invalid ApplicationSet case: %s\n' "$case_name" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_diagnostic" "$output"; then
    printf 'topology validator did not report the expected %s diagnostic\n' "$case_name" >&2
    sed -n '1,120p' "$output" >&2
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

assert_catalog_rejected \
  duplicate-namespace \
  '.brokerPairs[1].workloadNamespace = .brokerPairs[0].workloadNamespace' \
  'unique workloadNamespace count: expected 10, got 9'

assert_catalog_rejected \
  duplicate-broker-pair-name \
  '.brokerPairs[4].brokerPairName = .brokerPairs[3].brokerPairName' \
  'unique brokerPairName count: expected 10, got 9'

assert_catalog_rejected \
  duplicate-coordination-id \
  '.brokerPairs[7].coordinationId = .brokerPairs[6].coordinationId' \
  'unique coordinationId count: expected 10, got 9'

assert_catalog_rejected \
  invalid-coordination-id \
  '.brokerPairs[6].coordinationId = "pe-pair"' \
  'invalid coordination ID count: expected 0, got 1'

assert_catalog_rejected \
  missing-broker-pair \
  'del(.brokerPairs[5])' \
  'broker pair count: expected 10, got 9'

assert_catalog_rejected \
  wrong-distribution \
  '.brokerPairs[0].environment = "nonprod"' \
  'test broker pair count: expected 2, got 1'

assert_catalog_rejected \
  unknown-cluster-reference \
  '.brokerPairs[0].environment = "sandbox"' \
  'unknown broker pair cluster reference count: expected 0, got 1'

assert_catalog_rejected \
  mismatched-cluster-key \
  '.clusters.test.environment = "testing"' \
  'cluster key/environment mismatch count: expected 0, got 1'

assert_catalog_rejected \
  duplicate-cluster-server \
  '.clusters.nonprod.clusterServer = .clusters.test.clusterServer' \
  'unique cluster clusterServer count: expected 3, got 2'

assert_applicationset_rejected \
  embedded-operator-list \
  operator-applicationset.yaml \
  '.spec.generators[0] = {"list":{"elements":[{"environment":"test"}]}}' \
  'operator matrix child count: expected 2, got 0'

assert_applicationset_rejected \
  wrong-artemis-catalog-section \
  artemis-workloads-applicationset.yaml \
  '.spec.generators[0].matrix.generators[1].list.elementsYaml = "{{ values .clusters | toJson }}"' \
  'Artemis catalog expansion: expected {{ .brokerPairs | toJson }}, got {{ values .clusters | toJson }}'

assert_applicationset_rejected \
  missingkey-disabled \
  zookeeper-applicationset.yaml \
  '.spec.goTemplateOptions = []' \
  'ZooKeeper missingkey=error option count: expected 1, got 0'

assert_applicationset_rejected \
  pruning-disabled \
  artemis-workloads-applicationset.yaml \
  '.spec.template.spec.syncPolicy.automated.prune = false' \
  'Artemis automated prune: expected true, got false'

expected_broker_pairs=$(printf '%s\n' \
  'nonprod:nonprod-pt' \
  'nonprod:nonprod-smktest-eut' \
  'nonprod:nonprod-trn' \
  'nonprod:nonprod-trn2' \
  'prod:prod-dm' \
  'prod:prod-pe' \
  'prod:prod-pp' \
  'prod:prod-pr' \
  'test:test-sky' \
  'test:test-sky2' | sort)
actual_broker_pairs=$(yq -r \
  '.brokerPairs[] | .environment + ":" + .brokerPairName' \
  "$catalog" | sort)
if [[ "$actual_broker_pairs" != "$expected_broker_pairs" ]]; then
  printf '%s\n' 'catalog broker pair identities do not match the required 2/4/4 topology' >&2
  exit 1
fi

if rg -n 'workloadKey' "$catalog" "$applications" >/dev/null; then
  printf '%s\n' 'ambiguous workloadKey remains in the topology catalog or ApplicationSets' >&2
  exit 1
fi

assert_yaml_value \
  'Artemis Application name' \
  '.spec.template.metadata.name' \
  "$artemis" \
  '{{.brokerPairName}}-artemis'
assert_yaml_value \
  'Artemis destination server lookup' \
  '.spec.template.spec.destination.server' \
  "$artemis" \
  '{{(index .clusters .environment).clusterServer}}'
assert_yaml_value \
  'Artemis managed namespace cluster label lookup' \
  '.spec.template.spec.syncPolicy.managedNamespaceMetadata.labels."messaging.example.io/cluster"' \
  "$artemis" \
  '{{(index .clusters .environment).clusterName}}'
assert_yaml_value \
  'shared ZooKeeper connection template' \
  '.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.connectString") | .value' \
  "$artemis" \
  '{{.environment}}-shared-zookeeper-zookeeper-client.{{(index .clusters .environment).platformNamespace}}.svc.cluster.local:2181'
assert_yaml_value \
  'shared ZooKeeper namespace lookup' \
  '.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.serviceNamespace") | .value' \
  "$artemis" \
  '{{(index .clusters .environment).platformNamespace}}'
assert_yaml_value \
  'unique Curator namespace template' \
  '.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.curatorNamespace") | .value' \
  "$artemis" \
  'artemis/{{.environment}}/{{.brokerPairName}}'

printf '%s\n' 'topology validation tests passed'
