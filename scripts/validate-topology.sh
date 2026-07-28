#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
topology_file="$repo_root/argocd/applications/artemis-workloads-applicationset.yaml"
report="$repo_root/reports/topology-validation.json"

while (($#)); do
  case "$1" in
    --file) topology_file=$2; shift 2 ;;
    --report) report=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

if [[ ! -f "$topology_file" ]]; then
  printf 'topology file not found: %s\n' "$topology_file" >&2
  exit 2
fi

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-topology-validation.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
expanded="$temp_dir/expanded.json"
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

assert_template_value() {
  parameter_name=$1
  expected_value=$2
  actual_value=$(PARAMETER_NAME="$parameter_name" yq -r \
    '.spec.template.spec.source.helm.parameters[]
      | select(.name == strenv(PARAMETER_NAME))
      | .value' "$topology_file")
  assert_equal "$parameter_name template value" "$actual_value" "$expected_value"
}

api_version=$(yq -r '.apiVersion // ""' "$topology_file")
kind=$(yq -r '.kind // ""' "$topology_file")
assert_equal 'topology apiVersion' "$api_version" 'argoproj.io/v1alpha1'
assert_equal 'topology kind' "$kind" 'ApplicationSet'
assert_equal 'Go template mode' \
  "$(yq -r '.spec.goTemplate // false' "$topology_file")" \
  true
missing_key_error_count=$(yq -r \
  '[.spec.goTemplateOptions[] | select(. == "missingkey=error")] | length' \
  "$topology_file")
assert_equal 'missingkey=error option count' "$missing_key_error_count" 1

matrix_count=$(yq -r '[.spec.generators[] | select(has("matrix"))] | length' "$topology_file")
generator_count=$(yq -r '.spec.generators | length' "$topology_file")
assert_equal 'generator count' "$generator_count" 3
assert_equal 'matrix generator count' "$matrix_count" 3

invalid_matrix_count=$(yq -r '
  [.spec.generators[]
    | select(
        (.matrix.generators | length) != 2
        or (.matrix.generators[0].list.elements | length) != 1
        or (.matrix.generators[1].list.elements | length) < 1
      )
  ] | length
' "$topology_file")
assert_equal 'invalid matrix generator count' "$invalid_matrix_count" 0

# Expand the same two-list Cartesian product that the ApplicationSet matrix
# generator applies. Subsequent checks operate on effective workload
# definitions, not on the compact source representation.
yq -o=json -I=0 '
  [.spec.generators[].matrix.generators as $generators
    | $generators[0].list.elements[] as $cluster
    | $generators[1].list.elements[] as $workload
    | $cluster * $workload
  ]
' "$topology_file" > "$expanded"

workload_count=$(yq -r 'length' "$expanded")
assert_equal 'generated workload count' "$workload_count" 10

for environment_count in test:2 nonprod:4 prod:4; do
  environment=${environment_count%%:*}
  expected_count=${environment_count##*:}
  actual_count=$(ENVIRONMENT="$environment" yq -r \
    '[.[] | select(.environment == strenv(ENVIRONMENT))] | length' "$expanded")
  assert_equal "$environment workload count" "$actual_count" "$expected_count"
done

unexpected_environment_count=$(yq -r \
  '[.[] | select(.environment != "test" and .environment != "nonprod" and .environment != "prod")] | length' \
  "$expanded")
assert_equal 'unexpected environment count' "$unexpected_environment_count" 0

expected_workloads=$(printf '%s\n' \
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
actual_workloads=$(yq -r \
  '.[] | .environment + ":" + .workloadKey' "$expanded" | sort)
if [[ "$actual_workloads" != "$expected_workloads" ]]; then
  record_error 'workload identity mapping does not match SKY/SKY2, smktest(EUT)/TRN/TRN2/PT, PE/PP/DM/PR'
fi

for required_field in environment clusterName clusterServer workloadKey workloadNamespace coordinationId; do
  missing_count=$(FIELD="$required_field" yq -r \
    '[.[] | select((.[strenv(FIELD)] // "") == "")] | length' "$expanded")
  assert_equal "workloads missing $required_field" "$missing_count" 0
done

for unique_field in workloadKey workloadNamespace coordinationId; do
  unique_count=$(FIELD="$unique_field" yq -r \
    '[.[] | .[strenv(FIELD)]] | unique | length' "$expanded")
  assert_equal "unique $unique_field count" "$unique_count" "$workload_count"
done

application_name_count=$(yq -r \
  '[.[] | .workloadKey + "-artemis"] | unique | length' "$expanded")
curator_namespace_count=$(yq -r \
  '[.[] | "artemis/" + .environment + "/" + .workloadKey] | unique | length' "$expanded")
group_name_count=$(yq -r \
  '[.[] | .workloadKey + "-group"] | unique | length' "$expanded")
broker_cluster_name_count=$(yq -r \
  '[.[] | .workloadKey + "-cluster"] | unique | length' "$expanded")
assert_equal 'unique generated Application name count' "$application_name_count" "$workload_count"
assert_equal 'unique Curator namespace count' "$curator_namespace_count" "$workload_count"
assert_equal 'unique broker group name count' "$group_name_count" "$workload_count"
assert_equal 'unique broker cluster name count' "$broker_cluster_name_count" "$workload_count"

invalid_coordination_ids=$(yq -r '
  [.[] | select(
    (.coordinationId | type) != "!!str"
    or (.coordinationId | test("^[A-Za-z0-9][A-Za-z0-9._-]{7,15}$") | not)
  )] | length
' "$expanded")
assert_equal 'invalid coordination ID count' "$invalid_coordination_ids" 0

for environment in test nonprod prod; do
  cluster_name_count=$(ENVIRONMENT="$environment" yq -r \
    '[.[] | select(.environment == strenv(ENVIRONMENT)) | .clusterName] | unique | length' \
    "$expanded")
  cluster_server_count=$(ENVIRONMENT="$environment" yq -r \
    '[.[] | select(.environment == strenv(ENVIRONMENT)) | .clusterServer] | unique | length' \
    "$expanded")
  assert_equal "$environment cluster name count" "$cluster_name_count" 1
  assert_equal "$environment cluster server count" "$cluster_server_count" 1
done

cluster_name_count=$(yq -r '[.[] | .clusterName] | unique | length' "$expanded")
cluster_server_count=$(yq -r '[.[] | .clusterServer] | unique | length' "$expanded")
assert_equal 'EKS cluster name count' "$cluster_name_count" 3
assert_equal 'EKS cluster server count' "$cluster_server_count" 3

assert_equal 'Application name template' \
  "$(yq -r '.spec.template.metadata.name // ""' "$topology_file")" \
  '{{.workloadKey}}-artemis'
assert_equal 'Artemis chart path' \
  "$(yq -r '.spec.template.spec.source.path // ""' "$topology_file")" \
  'charts/artemis-ha'
assert_equal 'environment values file template' \
  "$(yq -r '.spec.template.spec.source.helm.valueFiles[0] // ""' "$topology_file")" \
  '../../environments/{{.environment}}/artemis-values.yaml'
assert_equal 'environment values file count' \
  "$(yq -r '.spec.template.spec.source.helm.valueFiles | length' "$topology_file")" \
  1
assert_equal 'destination namespace template' \
  "$(yq -r '.spec.template.spec.destination.namespace // ""' "$topology_file")" \
  '{{.workloadNamespace}}'
assert_equal 'destination server template' \
  "$(yq -r '.spec.template.spec.destination.server // ""' "$topology_file")" \
  '{{.clusterServer}}'
assert_equal 'managed namespace cluster label' \
  "$(yq -r '.spec.template.spec.syncPolicy.managedNamespaceMetadata.labels."messaging.example.io/cluster" // ""' "$topology_file")" \
  '{{.clusterName}}'

assert_template_value 'ha.coordinationId' '{{.coordinationId}}'
assert_template_value 'ha.groupName' '{{.workloadKey}}-group'
assert_template_value 'ha.clusterName' '{{.workloadKey}}-cluster'
assert_template_value 'zookeeper.curatorNamespace' 'artemis/{{.environment}}/{{.workloadKey}}'

zookeeper_connect_string=$(PARAMETER_NAME='zookeeper.connectString' yq -r \
  '.spec.template.spec.source.helm.parameters[]
    | select(.name == strenv(PARAMETER_NAME))
    | .value // ""' "$topology_file")
assert_equal 'shared ZooKeeper client Service template' \
  "$zookeeper_connect_string" \
  '{{.environment}}-shared-zookeeper-zookeeper-client.PLACEHOLDER_PLATFORM_NAMESPACE.svc.cluster.local:2181'

zookeeper_service_namespace=$(PARAMETER_NAME='zookeeper.serviceNamespace' yq -r \
  '.spec.template.spec.source.helm.parameters[]
    | select(.name == strenv(PARAMETER_NAME))
    | .value // ""' "$topology_file")
if [[ -z "$zookeeper_service_namespace" ]]; then
  record_error 'zookeeper.serviceNamespace template value must not be empty'
fi
if [[ "$zookeeper_service_namespace" == *'{{.workload'* \
    || "$zookeeper_service_namespace" == *'{{.coordination'* ]]; then
  record_error 'zookeeper.serviceNamespace must identify the shared per-EKS platform namespace'
fi

create_namespace_count=$(yq -r \
  '[.spec.template.spec.syncPolicy.syncOptions[] | select(. == "CreateNamespace=true")] | length' \
  "$topology_file")
assert_equal 'CreateNamespace sync option count' "$create_namespace_count" 1

status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"workload-topology","status":"%s","workloads":%d,"distribution":{"test":2,"nonprod":4,"prod":4},"errors":%d,"file":"%s"}\n' \
  "$status" "$workload_count" "$errors" "${topology_file#"$repo_root/"}" > "$report"
printf '%s\n' "topology validation: $status ($workload_count workloads, $errors errors)"
[[ "$errors" -eq 0 ]]
