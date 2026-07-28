#!/usr/bin/env bash
set -euo pipefail

test_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
validator="$repo_root/scripts/validate-topology.sh"
topology="$repo_root/argocd/applications/artemis-workloads-applicationset.yaml"

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-topology-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

"$validator" \
  --file "$topology" \
  --report "$temp_dir/baseline-report.json" >/dev/null

assert_rejected() {
  case_name=$1
  mutation=$2
  expected_diagnostic=$3
  candidate="$temp_dir/$case_name.yaml"
  output="$temp_dir/$case_name.out"

  cp "$topology" "$candidate"
  yq -i "$mutation" "$candidate"

  if "$validator" \
      --file "$candidate" \
      --report "$temp_dir/$case_name-report.json" >"$output" 2>&1; then
    printf 'topology validator accepted invalid case: %s\n' "$case_name" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_diagnostic" "$output"; then
    printf 'topology validator did not report the expected %s diagnostic\n' "$case_name" >&2
    sed -n '1,120p' "$output" >&2
    exit 1
  fi
}

assert_rejected \
  duplicate-namespace \
  '.spec.generators[0].matrix.generators[1].list.elements[1].workloadNamespace = .spec.generators[0].matrix.generators[1].list.elements[0].workloadNamespace' \
  'unique workloadNamespace count: expected 10, got 9'

assert_rejected \
  duplicate-workload-key \
  '.spec.generators[1].matrix.generators[1].list.elements[2].workloadKey = .spec.generators[1].matrix.generators[1].list.elements[1].workloadKey' \
  'unique workloadKey count: expected 10, got 9'

assert_rejected \
  duplicate-coordination-id \
  '.spec.generators[2].matrix.generators[1].list.elements[1].coordinationId = .spec.generators[2].matrix.generators[1].list.elements[0].coordinationId' \
  'unique coordinationId count: expected 10, got 9'

assert_rejected \
  invalid-coordination-id \
  '.spec.generators[2].matrix.generators[1].list.elements[0].coordinationId = "pe-pair"' \
  'invalid coordination ID count: expected 0, got 1'

assert_rejected \
  missing-workload \
  'del(.spec.generators[1].matrix.generators[1].list.elements[3])' \
  'generated workload count: expected 10, got 9'

assert_rejected \
  wrong-distribution \
  '.spec.generators[0].matrix.generators[0].list.elements[0].environment = "nonprod"' \
  'test workload count: expected 2, got 0'

assert_rejected \
  shared-curator-path \
  '(.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.curatorNamespace") | .value) = "artemis/shared"' \
  'zookeeper.curatorNamespace template value: expected artemis/{{.environment}}/{{.workloadKey}}, got artemis/shared'

assert_rejected \
  workload-specific-zookeeper \
  '(.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.connectString") | .value) = "{{.workloadKey}}-zookeeper:2181"' \
  'shared ZooKeeper client Service template: expected {{.environment}}-shared-zookeeper-zookeeper-client.PLACEHOLDER_PLATFORM_NAMESPACE.svc.cluster.local:2181, got {{.workloadKey}}-zookeeper:2181'

printf '%s\n' 'topology validation tests passed'
