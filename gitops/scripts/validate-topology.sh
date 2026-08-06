#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
topology_dir="$repo_root/argocd/topology"
bootstrap_dir="$repo_root/argocd/bootstrap"
report="$repo_root/reports/topology-validation.json"

while (($#)); do
  case "$1" in
    --topology-dir) topology_dir=$2; shift 2 ;;
    --bootstrap-dir) bootstrap_dir=$2; shift 2 ;;
    --report) report=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

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

assert_project() {
  file=$1
  environment=$2
  topology=$3
  expected_git_repository=$4

  assert_equal "$environment project apiVersion" \
    "$(yq -r '.apiVersion // ""' "$file")" \
    'argoproj.io/v1alpha1'
  assert_equal "$environment project kind" \
    "$(yq -r '.kind // ""' "$file")" \
    AppProject
  assert_equal "$environment project name" \
    "$(yq -r '.metadata.name // ""' "$file")" \
    messaging-platform
  assert_equal "$environment project namespace" \
    "$(yq -r '.metadata.namespace // ""' "$file")" \
    PLACEHOLDER_ARGOCD_NAMESPACE
  assert_equal "$environment project sync wave" \
    "$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave" // ""' "$file")" \
    -30

  expected_sources=$expected_git_repository
  actual_sources=$(yq -r '.spec.sourceRepos[]' "$file" | sort)
  assert_equal "$environment project approved sources" \
    "$actual_sources" "$expected_sources"

  expected_namespaces=$(
    yq -r '.platformNamespace, .brokerPairs[].workloadNamespace' "$topology" | sort
  )
  actual_namespaces=$(yq -r '.spec.destinations[].namespace' "$file" | sort)
  assert_equal "$environment project approved namespaces" \
    "$actual_namespaces" "$expected_namespaces"
  destination_count=$(yq -r '.spec.destinations | length' "$file")
  assert_equal "$environment project local destination count" \
    "$(yq -r \
      '[.spec.destinations[] | select(.server == "https://kubernetes.default.svc")] | length' \
      "$file")" \
    "$destination_count"

  expected_cluster_resources=$(printf '%s\n' \
    '|Namespace' \
    'apiextensions.k8s.io|CustomResourceDefinition' \
    'rbac.authorization.k8s.io|ClusterRole' \
    'rbac.authorization.k8s.io|ClusterRoleBinding' | sort)
  actual_cluster_resources=$(yq -r \
    '.spec.clusterResourceWhitelist[] | .group + "|" + .kind' "$file" | sort)
  assert_equal "$environment project cluster resource allowlist" \
    "$actual_cluster_resources" "$expected_cluster_resources"
}

unique_line_count() {
  printf '%s\n' "$1" | sed '/^$/d' | sort -u | wc -l | tr -d ' '
}

assert_sync_policy() {
  file=$1
  expression_prefix=$2
  label=$3

  for safety_option in CreateNamespace=true ServerSideApply=true ApplyOutOfSyncOnly=true; do
    assert_equal "$label $safety_option count" \
      "$(OPTION="$safety_option" PREFIX="$expression_prefix" yq -r \
        '[eval(strenv(PREFIX) + ".syncOptions[]") | select(. == strenv(OPTION))] | length' \
        "$file")" \
      1
  done
  assert_equal "$label automated prune" \
    "$(PREFIX="$expression_prefix" yq -r \
      'eval(strenv(PREFIX) + ".automated.prune") // false' "$file")" \
    true
  assert_equal "$label automated self-heal" \
    "$(PREFIX="$expression_prefix" yq -r \
      'eval(strenv(PREFIX) + ".automated.selfHeal") // false' "$file")" \
    true
}

assert_singleton_application() {
  file=$1
  environment=$2
  component=$3
  expected_name=$4
  expected_wave=$5

  assert_equal "$environment $component apiVersion" \
    "$(yq -r '.apiVersion // ""' "$file")" \
    'argoproj.io/v1alpha1'
  assert_equal "$environment $component kind" \
    "$(yq -r '.kind // ""' "$file")" \
    Application
  assert_equal "$environment $component name" \
    "$(yq -r '.metadata.name // ""' "$file")" \
    "$expected_name"
  assert_equal "$environment $component sync wave" \
    "$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave" // ""' "$file")" \
    "$expected_wave"
  assert_equal "$environment $component project" \
    "$(yq -r '.spec.project // ""' "$file")" \
    messaging-platform
  assert_equal "$environment $component local destination" \
    "$(yq -r '.spec.destination.server // ""' "$file")" \
    'https://kubernetes.default.svc'
  assert_sync_policy "$file" '.spec.syncPolicy' "$environment $component"
}

assert_workload_applicationset() {
  file=$1
  environment=$2

  assert_equal "$environment workloads apiVersion" \
    "$(yq -r '.apiVersion // ""' "$file")" \
    'argoproj.io/v1alpha1'
  assert_equal "$environment workloads kind" \
    "$(yq -r '.kind // ""' "$file")" \
    ApplicationSet
  assert_equal "$environment workloads name" \
    "$(yq -r '.metadata.name // ""' "$file")" \
    "$environment-artemis-workloads"
  assert_equal "$environment workloads Go template mode" \
    "$(yq -r '.spec.goTemplate // false' "$file")" \
    true
  assert_equal "$environment workloads missingkey=error option count" \
    "$(yq -r '[.spec.goTemplateOptions[] | select(. == "missingkey=error")] | length' "$file")" \
    1
  assert_equal "$environment workloads generator count" \
    "$(yq -r '.spec.generators | length' "$file")" \
    1
  assert_equal "$environment workloads matrix child count" \
    "$(yq -r '.spec.generators[0].matrix.generators | length' "$file")" \
    2
  assert_equal "$environment workloads topology path" \
    "$(yq -r '.spec.generators[0].matrix.generators[0].git.files[0].path // ""' "$file")" \
    "gitops/argocd/topology/$environment.yaml"
  generator_revision=$(yq -r \
    '.spec.generators[0].matrix.generators[0].git.revision // ""' "$file")
  if [[ -z "$generator_revision" ]]; then
    record_error "$environment workloads Git generator revision is required"
  fi
  assert_equal "$environment workloads source revision" \
    "$(yq -r '.spec.template.spec.source.targetRevision // ""' "$file")" \
    "$generator_revision"
  assert_equal "$environment workloads topology expansion" \
    "$(yq -r '.spec.generators[0].matrix.generators[1].list.elementsYaml // ""' "$file")" \
    '{{ .brokerPairs | toJson }}'
  assert_equal "$environment workloads enable selector" \
    "$(yq -r '.spec.generators[0].selector.matchLabels.enabled // ""' "$file")" \
    'true'
  assert_equal "$environment workloads Application modification policy" \
    "$(yq -r '.spec.syncPolicy.applicationsSync // ""' "$file")" \
    create-update
  assert_equal "$environment workloads preserve resources on deletion" \
    "$(yq -r '.spec.syncPolicy.preserveResourcesOnDeletion // false' "$file")" \
    true
  assert_equal "$environment workloads local destination" \
    "$(yq -r '.spec.template.spec.destination.server // ""' "$file")" \
    'https://kubernetes.default.svc'
  assert_equal "$environment workloads destination namespace" \
    "$(yq -r '.spec.template.spec.destination.namespace // ""' "$file")" \
    '{{.workloadNamespace}}'
  assert_equal "$environment workloads values file count" \
    "$(yq -r '.spec.template.spec.source.helm.valueFiles | length' "$file")" \
    1
  assert_equal "$environment workloads environment values path" \
    "$(yq -r '.spec.template.spec.source.helm.valueFiles[0] // ""' "$file")" \
    '../../environments/{{.environment}}/artemis-values.yaml'
  assert_equal "$environment workloads cluster label" \
    "$(yq -r \
      '.spec.template.spec.syncPolicy.managedNamespaceMetadata.labels."messaging.example.io/cluster" // ""' \
      "$file")" \
    '{{.clusterName}}'
  assert_equal "$environment workloads ZooKeeper endpoint" \
    "$(yq -r \
      '.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.connectString") | .value' \
      "$file")" \
    '{{.environment}}-shared-zookeeper-zookeeper-client.{{.platformNamespace}}.svc.cluster.local:2181'
  assert_equal "$environment workloads ZooKeeper namespace" \
    "$(yq -r \
      '.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.serviceNamespace") | .value' \
      "$file")" \
    '{{.platformNamespace}}'
  assert_equal "$environment workloads storage size" \
    "$(yq -r \
      '.spec.template.spec.source.helm.parameters[] | select(.name == "persistence.size") | .value' \
      "$file")" \
    '{{.storageSize}}'
  assert_equal "$environment workloads management host" \
    "$(yq -r \
      '.spec.template.spec.source.helm.parameters[] | select(.name == "console.ingress.host") | .value' \
      "$file")" \
    '{{.managementHost}}'
  assert_equal "$environment workloads Keycloak redirect URI" \
    "$(yq -r \
      '.spec.template.spec.source.helm.parameters[] | select(.name == "keycloak.redirectUri") | .value' \
      "$file")" \
    'https://{{.managementHost}}/console'
  assert_sync_policy "$file" '.spec.template.spec.syncPolicy' "$environment workloads"
}

environments='test nonprod prod'
cluster_count=0
broker_pair_count=0
all_names=''
all_namespaces=''
all_coordination_ids=''
all_management_hosts=''
distribution_json=''

for environment_count in test:2 nonprod:4 prod:8; do
  environment=${environment_count%%:*}
  expected_count=${environment_count##*:}
  topology="$topology_dir/$environment.yaml"
  environment_bootstrap="$bootstrap_dir/$environment"
  project="$environment_bootstrap/project.yaml"
  operator="$environment_bootstrap/operator-application.yaml"
  zookeeper="$environment_bootstrap/zookeeper-application.yaml"
  workloads="$environment_bootstrap/artemis-workloads-applicationset.yaml"

  for required_path in "$topology" "$project" "$operator" "$zookeeper" "$workloads"; do
    if [[ ! -f "$required_path" ]]; then
      record_error "topology input not found: $required_path"
    fi
  done
  if [[ ! -f "$topology" || ! -f "$project" || ! -f "$operator" || ! -f "$zookeeper" || ! -f "$workloads" ]]; then
    continue
  fi

  cluster_count=$((cluster_count + 1))
  assert_equal "$environment topology schemaVersion" \
    "$(yq -r '.schemaVersion // ""' "$topology")" \
    'topology.artemis.apache.org/v1'
  assert_equal "$environment topology environment" \
    "$(yq -r '.environment // ""' "$topology")" \
    "$environment"

  for required_field in clusterName platformNamespace; do
    assert_equal "$environment topology missing $required_field count" \
      "$(FIELD="$required_field" yq -r \
        '[select((.[strenv(FIELD)] // "") == "")] | length' "$topology")" \
      0
  done

  actual_count=$(yq -r '.brokerPairs // [] | length' "$topology")
  assert_equal "$environment broker pair count" "$actual_count" "$expected_count"
  broker_pair_count=$((broker_pair_count + actual_count))

  for required_field in brokerPairName workloadNamespace coordinationId logicalEnvironment trafficClass managementHost storageSize enabled; do
    assert_equal "$environment broker pairs missing $required_field" \
      "$(FIELD="$required_field" yq -r '
        [.brokerPairs // [] | .[]
          | select((.[strenv(FIELD)] // "") == "")
        ] | length
      ' "$topology")" \
      0
  done

  assert_equal "$environment invalid coordination ID count" \
    "$(yq -r '
      [.brokerPairs // [] | .[]
        | select(
            (.coordinationId | type) != "!!str"
            or (.coordinationId | length) < 8
            or (.coordinationId | length) > 16
            or (.coordinationId | test("^[A-Za-z0-9][A-Za-z0-9._-]+$") | not)
          )
      ] | length
    ' "$topology")" \
    0
  assert_equal "$environment invalid enabled value count" \
    "$(yq -r '
      [.brokerPairs // [] | .[]
        | select(.enabled != "true" and .enabled != "false")
      ] | length
    ' "$topology")" \
    0
  assert_equal "$environment invalid traffic class count" \
    "$(yq -r '
      [.brokerPairs // [] | .[]
        | select(
            .trafficClass != "internal"
            and .trafficClass != "external"
            and .trafficClass != "batch"
          )
      ] | length
    ' "$topology")" \
    0
  assert_equal "$environment invalid management host count" \
    "$(yq -r '
      [.brokerPairs // [] | .[]
        | select(
            (.managementHost | type) != "!!str"
            or (.managementHost | test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$") | not)
          )
      ] | length
    ' "$topology")" \
    0
  assert_equal "$environment invalid storage size count" \
    "$(yq -r '
      [.brokerPairs // [] | .[]
        | select(
            (.storageSize | type) != "!!str"
            or (.storageSize | test("^[1-9][0-9]*(Mi|Gi|Ti)$") | not)
          )
      ] | length
    ' "$topology")" \
    0
  assert_equal "$environment broker-pair name prefix mismatch count" \
    "$(PREFIX="^$environment-" yq -r '
      [.brokerPairs // [] | .[]
        | select(.brokerPairName | test(strenv(PREFIX)) | not)
      ] | length
    ' "$topology")" \
    0

  all_names="$all_names
$(yq -r '.brokerPairs[].brokerPairName' "$topology")"
  all_namespaces="$all_namespaces
$(yq -r '.brokerPairs[].workloadNamespace' "$topology")"
  all_coordination_ids="$all_coordination_ids
$(yq -r '.brokerPairs[].coordinationId' "$topology")"
  all_management_hosts="$all_management_hosts
$(yq -r '.brokerPairs[].managementHost' "$topology")"

  if [[ "$environment" == prod ]]; then
    assert_equal 'prod internal pair count' \
      "$(yq -r '[.brokerPairs[] | select(.trafficClass == "internal")] | length' "$topology")" \
      4
    assert_equal 'prod internal logical environment coverage' \
      "$(yq -r '[.brokerPairs[] | select(.trafficClass == "internal") | .logicalEnvironment] | unique | sort | join(",")' "$topology")" \
      'DM,PE,PP,PR'
    assert_equal 'prod external pair count' \
      "$(yq -r '[.brokerPairs[] | select(.trafficClass == "external")] | length' "$topology")" \
      2
    assert_equal 'prod external logical environment coverage' \
      "$(yq -r '[.brokerPairs[] | select(.trafficClass == "external") | .logicalEnvironment] | unique | sort | join(",")' "$topology")" \
      'PP,PR'
    assert_equal 'prod batch placeholder count' \
      "$(yq -r '[.brokerPairs[] | select(.trafficClass == "batch")] | length' "$topology")" \
      2
    assert_equal 'prod enabled batch placeholder count' \
      "$(yq -r '[.brokerPairs[] | select(.trafficClass == "batch" and .enabled == "true")] | length' "$topology")" \
      0
  else
    assert_equal "$environment non-internal pair count" \
      "$(yq -r '[.brokerPairs[] | select(.trafficClass != "internal")] | length' "$topology")" \
      0
  fi

  assert_singleton_application \
    "$operator" "$environment" operator "$environment-arkmq-operator" -20
  expected_ecr_repository=PLACEHOLDER_NONPROD_ECR_REPOSITORY
  if [[ "$environment" == prod ]]; then
    expected_ecr_repository=PLACEHOLDER_PROD_ECR_REPOSITORY
  fi
  assert_equal "$environment operator wrapper path" \
    "$(yq -r '.spec.source.path // ""' "$operator")" \
    gitops/charts/arkmq-operator
  assert_equal "$environment operator release name" \
    "$(yq -r '.spec.source.helm.releaseName // ""' "$operator")" \
    "$environment-arkmq-operator"
  assert_equal "$environment operator values file count" \
    "$(yq -r '.spec.source.helm.valueFiles | length' "$operator")" \
    1
  assert_equal "$environment operator release values path" \
    "$(yq -r '.spec.source.helm.valueFiles[0] // ""' "$operator")" \
    '../../operator-values.yaml'
  assert_equal "$environment operator required env label" \
    "$(yq -r '.spec.source.helm.parameters[] | select(.name == "global.requiredLabels.env") | .value' "$operator")" \
    "$environment"
  assert_equal "$environment operator image repository" \
    "$(yq -r '.spec.source.helm.parameters[] | select(.name == "arkmq-org-broker-operator.controllerManager.manager.image.repository") | .value' "$operator")" \
    "$expected_ecr_repository/arkmq-operator"
  assert_equal "$environment operator init-image repository" \
    "$(yq -r '.spec.source.helm.parameters[] | select(.name == "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerInitRepository") | .value' "$operator")" \
    "$expected_ecr_repository/activemq-artemis-broker-init"
  assert_equal "$environment operator broker-image repository" \
    "$(yq -r '.spec.source.helm.parameters[] | select(.name == "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerKubernetesRepository") | .value' "$operator")" \
    "$expected_ecr_repository/activemq-artemis-broker-kubernetes"
  assert_singleton_application \
    "$zookeeper" "$environment" ZooKeeper "$environment-shared-zookeeper" -10
  assert_equal "$environment ZooKeeper release name" \
    "$(yq -r '.spec.source.helm.releaseName // ""' "$zookeeper")" \
    "$environment-shared-zookeeper"
  assert_equal "$environment ZooKeeper values file count" \
    "$(yq -r '.spec.source.helm.valueFiles | length' "$zookeeper")" \
    1
  assert_equal "$environment ZooKeeper environment values path" \
    "$(yq -r '.spec.source.helm.valueFiles[0] // ""' "$zookeeper")" \
    "../../environments/$environment/zookeeper-values.yaml"
  assert_equal "$environment ZooKeeper image repository" \
    "$(yq -r '.spec.source.helm.parameters[] | select(.name == "image.repository") | .value' "$zookeeper")" \
    "$expected_ecr_repository/zookeeper"
  assert_workload_applicationset "$workloads" "$environment"

  git_revision=$(yq -r \
    '.spec.generators[0].matrix.generators[0].git.revision // ""' "$workloads")
  assert_equal "$environment operator Git revision" \
    "$(yq -r '.spec.source.targetRevision // ""' "$operator")" \
    "$git_revision"
  assert_equal "$environment ZooKeeper Git revision" \
    "$(yq -r '.spec.source.targetRevision // ""' "$zookeeper")" \
    "$git_revision"

  git_repo=$(yq -r \
    '.spec.generators[0].matrix.generators[0].git.repoURL // ""' "$workloads")
  assert_equal "$environment workload source repository" \
    "$(yq -r '.spec.template.spec.source.repoURL // ""' "$workloads")" \
    "$git_repo"
  assert_equal "$environment operator Git repository" \
    "$(yq -r '.spec.source.repoURL // ""' "$operator")" \
    "$git_repo"
  assert_equal "$environment ZooKeeper Git repository" \
    "$(yq -r '.spec.source.repoURL // ""' "$zookeeper")" \
    "$git_repo"
  assert_project \
    "$project" "$environment" "$topology" "$git_repo"

  if [[ -n "$distribution_json" ]]; then
    distribution_json="$distribution_json,"
  fi
  distribution_json="$distribution_json\"$environment\":$actual_count"
done

assert_equal 'cluster bootstrap count' "$cluster_count" 3
assert_equal 'broker pair count' "$broker_pair_count" 14
assert_equal 'unique brokerPairName count' \
  "$(unique_line_count "$all_names")" \
  "$broker_pair_count"
assert_equal 'unique workloadNamespace count' \
  "$(unique_line_count "$all_namespaces")" \
  "$broker_pair_count"
assert_equal 'unique coordinationId count' \
  "$(unique_line_count "$all_coordination_ids")" \
  "$broker_pair_count"
assert_equal 'unique managementHost count' \
  "$(unique_line_count "$all_management_hosts")" \
  "$broker_pair_count"

if rg -n \
    'clusterServer|PLACEHOLDER_(TEST|NONPROD|PROD)_EKS_API_SERVER' \
    "$topology_dir" "$bootstrap_dir" >/dev/null; then
  record_error 'cross-cluster destination data remains in cluster-local topology or bootstrap manifests'
fi

status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"deployment-topology","status":"%s","clusters":%d,"brokerPairs":%d,"distribution":{%s},"projectOwner":"bootstrap","errors":%d,"topologyDirectory":"%s","bootstrapDirectory":"%s"}\n' \
  "$status" "$cluster_count" "$broker_pair_count" "$distribution_json" "$errors" \
  "${topology_dir#"$repo_root/"}" "${bootstrap_dir#"$repo_root/"}" > "$report"
printf '%s\n' \
  "topology validation: $status ($cluster_count local cluster bootstraps, $broker_pair_count broker pairs, $errors errors)"
[[ "$errors" -eq 0 ]]
