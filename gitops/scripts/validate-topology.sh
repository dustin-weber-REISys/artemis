#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
catalog_file="$repo_root/argocd/topology/catalog.yaml"
applications_dir="$repo_root/argocd/applications"
report="$repo_root/reports/topology-validation.json"

while (($#)); do
  case "$1" in
    --catalog|--file) catalog_file=$2; shift 2 ;;
    --applications-dir) applications_dir=$2; shift 2 ;;
    --report) report=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

for required_path in \
  "$catalog_file" \
  "$applications_dir/operator-applicationset.yaml" \
  "$applications_dir/zookeeper-applicationset.yaml" \
  "$applications_dir/artemis-workloads-applicationset.yaml"; do
  if [[ ! -f "$required_path" ]]; then
    printf 'topology input not found: %s\n' "$required_path" >&2
    exit 2
  fi
done

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"

errors=0

record_error() {
  printf '%s\n' "$1" >&2
  errors=$((errors + 1))
}

assert_equal() {
  description=$1
  actual=$2
  expected=$3
  if [[ "$actual" != "$expected" ]]; then
    record_error "$description: expected $expected, got $actual"
  fi
}

assert_applicationset_contract() {
  file=$1
  catalog_expression=$2
  label=$3

  assert_equal "$label apiVersion" \
    "$(yq -r '.apiVersion // ""' "$file")" \
    'argoproj.io/v1alpha1'
  assert_equal "$label kind" \
    "$(yq -r '.kind // ""' "$file")" \
    'ApplicationSet'
  assert_equal "$label Go template mode" \
    "$(yq -r '.spec.goTemplate // false' "$file")" \
    true
  assert_equal "$label missingkey=error option count" \
    "$(yq -r '[.spec.goTemplateOptions[] | select(. == "missingkey=error")] | length' "$file")" \
    1
  assert_equal "$label generator count" \
    "$(yq -r '.spec.generators | length' "$file")" \
    1
  assert_equal "$label matrix child count" \
    "$(yq -r '.spec.generators[0].matrix.generators | length' "$file")" \
    2
  assert_equal "$label catalog path" \
    "$(yq -r '.spec.generators[0].matrix.generators[0].git.files[0].path // ""' "$file")" \
    'gitops/argocd/topology/catalog.yaml'
  assert_equal "$label catalog file count" \
    "$(yq -r '.spec.generators[0].matrix.generators[0].git.files | length' "$file")" \
    1
  assert_equal "$label catalog revision" \
    "$(yq -r '.spec.generators[0].matrix.generators[0].git.revision // ""' "$file")" \
    main
  assert_equal "$label catalog expansion" \
    "$(yq -r '.spec.generators[0].matrix.generators[1].list.elementsYaml // ""' "$file")" \
    "$catalog_expression"

  for safety_option in CreateNamespace=true ServerSideApply=true ApplyOutOfSyncOnly=true; do
    assert_equal "$label $safety_option count" \
      "$(OPTION="$safety_option" yq -r \
        '[.spec.template.spec.syncPolicy.syncOptions[] | select(. == strenv(OPTION))] | length' \
        "$file")" \
      1
  done
  assert_equal "$label automated prune" \
    "$(yq -r '.spec.template.spec.syncPolicy.automated.prune // false' "$file")" \
    true
  assert_equal "$label automated self-heal" \
    "$(yq -r '.spec.template.spec.syncPolicy.automated.selfHeal // false' "$file")" \
    true
}

assert_equal 'catalog schemaVersion' \
  "$(yq -r '.schemaVersion // ""' "$catalog_file")" \
  'topology.artemis.apache.org/v1'

cluster_count=$(yq -r '.clusters // {} | length' "$catalog_file")
broker_pair_count=$(yq -r '.brokerPairs // [] | length' "$catalog_file")
assert_equal 'cluster count' "$cluster_count" 3
assert_equal 'broker pair count' "$broker_pair_count" 10

unexpected_cluster_key_count=$(yq -r '
  [.clusters // {} | keys[]
    | select(. != "test" and . != "nonprod" and . != "prod")
  ] | length
' "$catalog_file")
assert_equal 'unexpected cluster key count' "$unexpected_cluster_key_count" 0

cluster_key_mismatch_count=$(yq -r '
  [.clusters // {} | to_entries[]
    | select(.key != .value.environment)
  ] | length
' "$catalog_file")
assert_equal 'cluster key/environment mismatch count' "$cluster_key_mismatch_count" 0

for required_field in environment clusterName clusterServer platformNamespace; do
  missing_count=$(FIELD="$required_field" yq -r '
    [.clusters // {} | .[]
      | select((.[strenv(FIELD)] // "") == "")
    ] | length
  ' "$catalog_file")
  assert_equal "clusters missing $required_field" "$missing_count" 0
done

for unique_field in environment clusterName clusterServer; do
  unique_count=$(FIELD="$unique_field" yq -r \
    '[.clusters // {} | .[] | .[strenv(FIELD)]] | unique | length' \
    "$catalog_file")
  assert_equal "unique cluster $unique_field count" "$unique_count" "$cluster_count"
done

for required_field in environment brokerPairName workloadNamespace coordinationId; do
  missing_count=$(FIELD="$required_field" yq -r '
    [.brokerPairs // [] | .[]
      | select((.[strenv(FIELD)] // "") == "")
    ] | length
  ' "$catalog_file")
  assert_equal "broker pairs missing $required_field" "$missing_count" 0
done

unknown_cluster_reference_count=$(yq -r '
  .clusters as $clusters
  | [.brokerPairs // [] | .[]
      | select($clusters[.environment] == null)
    ] | length
' "$catalog_file")
assert_equal 'unknown broker pair cluster reference count' "$unknown_cluster_reference_count" 0

for environment_count in test:2 nonprod:4 prod:4; do
  environment=${environment_count%%:*}
  expected_count=${environment_count##*:}
  actual_count=$(ENVIRONMENT="$environment" yq -r '
    [.brokerPairs // [] | .[]
      | select(.environment == strenv(ENVIRONMENT))
    ] | length
  ' "$catalog_file")
  assert_equal "$environment broker pair count" "$actual_count" "$expected_count"
done

for unique_field in brokerPairName workloadNamespace coordinationId; do
  unique_count=$(FIELD="$unique_field" yq -r \
    '[.brokerPairs // [] | .[] | .[strenv(FIELD)]] | unique | length' \
    "$catalog_file")
  assert_equal "unique $unique_field count" "$unique_count" "$broker_pair_count"
done

invalid_coordination_ids=$(yq -r '
  [.brokerPairs // [] | .[]
    | select(
        (.coordinationId | type) != "!!str"
        or (.coordinationId | test("^[A-Za-z0-9][A-Za-z0-9._-]{7,15}$") | not)
      )
  ] | length
' "$catalog_file")
assert_equal 'invalid coordination ID count' "$invalid_coordination_ids" 0

application_name_count=$(yq -r \
  '[.brokerPairs // [] | .[] | .brokerPairName + "-artemis"] | unique | length' \
  "$catalog_file")
curator_namespace_count=$(yq -r \
  '[.brokerPairs // [] | .[] | "artemis/" + .environment + "/" + .brokerPairName] | unique | length' \
  "$catalog_file")
assert_equal 'unique generated Application name count' "$application_name_count" "$broker_pair_count"
assert_equal 'unique Curator namespace count' "$curator_namespace_count" "$broker_pair_count"

assert_applicationset_contract \
  "$applications_dir/operator-applicationset.yaml" \
  '{{ values .clusters | toJson }}' \
  operator
assert_applicationset_contract \
  "$applications_dir/zookeeper-applicationset.yaml" \
  '{{ values .clusters | toJson }}' \
  ZooKeeper
assert_applicationset_contract \
  "$applications_dir/artemis-workloads-applicationset.yaml" \
  '{{ .brokerPairs | toJson }}' \
  Artemis

status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"deployment-topology","status":"%s","clusters":%d,"brokerPairs":%d,"distribution":{"test":2,"nonprod":4,"prod":4},"errors":%d,"catalog":"%s"}\n' \
  "$status" "$cluster_count" "$broker_pair_count" "$errors" "${catalog_file#"$repo_root/"}" > "$report"
printf '%s\n' "topology validation: $status ($cluster_count clusters, $broker_pair_count broker pairs, $errors errors)"
[[ "$errors" -eq 0 ]]
