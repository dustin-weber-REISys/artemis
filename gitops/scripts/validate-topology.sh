#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
topology_dir="$repo_root/argocd/topology"
bootstrap_dir="$repo_root/argocd/bootstrap"
profile_dir="$repo_root/argocd/profiles"
environment_dir="$repo_root/environments"
baseline_policy="$repo_root/argocd/baseline-policy.yaml"
report="$repo_root/reports/topology-validation.json"

while (($#)); do
  case "$1" in
    --topology-dir) topology_dir=$2; shift 2 ;;
    --bootstrap-dir) bootstrap_dir=$2; shift 2 ;;
    --profile-dir) profile_dir=$2; shift 2 ;;
    --environment-dir) environment_dir=$2; shift 2 ;;
    --baseline-policy) baseline_policy=$2; shift 2 ;;
    --report) report=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}
if command -v kustomize >/dev/null 2>&1; then
  render_command=(kustomize build)
elif command -v kubectl >/dev/null 2>&1; then
  # This is a local file render. It does not contact a Kubernetes cluster.
  render_command=(kubectl kustomize)
else
  printf '%s\n' 'kustomize or kubectl with embedded Kustomize is required' >&2
  exit 2
fi

if [[ "$report" != /* ]]; then
  report="$repo_root/$report"
fi
mkdir -p "$(dirname -- "$report")"
render_dir=$(mktemp -d "${TMPDIR:-/tmp}/artemis-composition.XXXXXX")
trap 'rm -rf "$render_dir"' EXIT

errors=0
cluster_count=0
workload_cell_count=0
enabled_cell_count=0
distribution_json=''

record_error() {
  printf '%s\n' "$1" >&2
  errors=$((errors + 1))
}

assert_equal() {
  local description=$1 actual=$2 expected=$3
  [[ "$actual" == "$expected" ]] || \
    record_error "$description: expected $expected, got $actual"
}

cell_error() {
  local environment=$1 cell=$2 field=$3 rule=$4
  record_error "cluster $environment Workload Cell $cell field $field violates rule: $rule"
}

render_scalar() {
  local manifest=$1 kind=$2 name=$3 expression=$4
  KIND="$kind" NAME="$name" yq ea -r \
    "select(.kind == strenv(KIND) and .metadata.name == strenv(NAME)) | $expression // \"\"" \
    "$manifest"
}

parameter_value() {
  local manifest=$1 application_set=$2 parameter=$3
  APPSET="$application_set" PARAMETER="$parameter" yq ea -r '
    select(.kind == "ApplicationSet" and .metadata.name == strenv(APPSET))
    | .spec.template.spec.source.helm.parameters[]
    | select(.name == strenv(PARAMETER))
    | .value
  ' "$manifest"
}

assert_sync_policy() {
  local manifest=$1 kind=$2 name=$3 prefix=$4 label=$5
  local option
  for option in CreateNamespace=true ServerSideApply=true ApplyOutOfSyncOnly=true; do
    OPTION="$option" KIND="$kind" NAME="$name" PREFIX="$prefix" assert_equal \
      "$label $option count" \
      "$(KIND="$kind" NAME="$name" PREFIX="$prefix" OPTION="$option" yq ea -r '
        select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))
        | [eval(strenv(PREFIX) + ".syncOptions[]") | select(. == strenv(OPTION))]
        | length
      ' "$manifest")" 1
  done
  assert_equal "$label automated prune" \
    "$(KIND="$kind" NAME="$name" PREFIX="$prefix" yq ea -r '
      select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))
      | eval(strenv(PREFIX) + ".automated.prune") // false
    ' "$manifest")" true
  assert_equal "$label automated self-heal" \
    "$(KIND="$kind" NAME="$name" PREFIX="$prefix" yq ea -r '
      select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))
      | eval(strenv(PREFIX) + ".automated.selfHeal") // false
    ' "$manifest")" true
}

validate_profile() {
  local profile=$1 definition="$profile_dir/$profile/profile.yaml" values="$profile_dir/$profile/values.yaml"
  [[ -f "$definition" ]] || { record_error "unknown Workload Cell Profile: $profile"; return; }
  [[ -f "$values" ]] || { record_error "Workload Cell Profile $profile values file is missing"; return; }
  assert_equal "Workload Cell Profile $profile schemaVersion" \
    "$(yq -r '.schemaVersion // ""' "$definition")" profiles.artemis.apache.org/v1
  assert_equal "Workload Cell Profile $profile directory/name contract" \
    "$(yq -r '.name // ""' "$definition")" "$profile"
  assert_equal "Workload Cell Profile $profile contract keys" \
    "$(yq -r 'keys | sort | join(",")' "$definition")" \
    'description,featureOverrides,name,protectedPaths,schemaVersion'
  assert_equal "Workload Cell Profile $profile protected paths" \
    "$(yq -r '.protectedPaths | sort | join(",")' "$definition")" \
    'broker.version,brokerProperties.durability,ha,persistence.size,topology,zookeeper'

  local forbidden leaf
  for forbidden in broker.version operator release platform images image ha zookeeper brokerProperties.durability persistence.size topology; do
    while IFS= read -r leaf; do
      [[ -z "$leaf" || "$leaf" != "$forbidden" && "$leaf" != "$forbidden".* ]] || \
        record_error "Workload Cell Profile $profile field $leaf violates protected-setting ownership"
    done < <(yq -r '.. | select(tag != "!!map" and tag != "!!seq") | path | join(".")' "$values")
  done
}

[[ -f "$baseline_policy" ]] || record_error "baseline policy not found: $baseline_policy"
if [[ -f "$baseline_policy" ]]; then
  assert_equal 'baseline policy schemaVersion' \
    "$(yq -r '.schemaVersion // ""' "$baseline_policy")" baseline.artemis.apache.org/v1
fi

# Validate each Profile once before any cluster references it.
known_profiles=''
if [[ -d "$profile_dir" ]]; then
  while IFS= read -r definition; do
    profile=${definition%/profile.yaml}
    profile=${profile##*/}
    known_profiles="$known_profiles $profile"
    validate_profile "$profile"
  done < <(find "$profile_dir" -mindepth 2 -maxdepth 2 -name profile.yaml -print | sort)
fi
[[ -n "${known_profiles// }" ]] || record_error 'no Workload Cell Profiles are defined'

for environment in test nonprod prod; do
  topology="$topology_dir/$environment.yaml"
  adapter="$bootstrap_dir/$environment"
  rendered="$render_dir/$environment.yaml"
  rendered_again="$render_dir/$environment-again.yaml"

  [[ -f "$topology" ]] || { record_error "cluster $environment catalog not found: $topology"; continue; }
  [[ -f "$adapter/kustomization.yaml" ]] || {
    record_error "cluster $environment Kustomize adapter not found: $adapter/kustomization.yaml"
    continue
  }
  if ! "${render_command[@]}" "$adapter" > "$rendered"; then
    record_error "cluster $environment composition failed to render"
    continue
  fi
  if ! "${render_command[@]}" "$adapter" > "$rendered_again"; then
    record_error "cluster $environment composition failed its repeated render"
    continue
  fi
  cmp -s "$rendered" "$rendered_again" || record_error "cluster $environment composition is not deterministic"
  cluster_count=$((cluster_count + 1))

  assert_equal "cluster $environment catalog schemaVersion" \
    "$(yq -r '.schemaVersion // ""' "$topology")" topology.artemis.apache.org/v2
  assert_equal "cluster $environment catalog root keys" \
    "$(yq -r 'keys | sort | join(",")' "$topology")" \
    'clusterName,environment,platformNamespace,schemaVersion,workloadCells'
  assert_equal "cluster $environment catalog environment" \
    "$(yq -r '.environment // ""' "$topology")" "$environment"
  assert_equal "cluster $environment catalog platform namespace" \
    "$(yq -r '.platformNamespace // ""' "$topology")" artemis-platform
  for root_field in clusterName platformNamespace workloadCells; do
    ROOT_FIELD="$root_field" yq -e 'has(strenv(ROOT_FIELD))' "$topology" >/dev/null || \
      record_error "cluster $environment catalog field $root_field is required"
  done
  if yq -e 'has("brokerPairs")' "$topology" >/dev/null 2>&1; then
    record_error "cluster $environment catalog uses retired brokerPairs terminology; use workloadCells"
  fi

  document_count=$(yq ea -r '[.] | length' "$rendered")
  assert_equal "cluster $environment rendered resource count" "$document_count" 4
  assert_equal "cluster $environment rendered AppProject cardinality" \
    "$(yq ea -r '[.] | [.[] | select(.kind == "AppProject")] | length' "$rendered")" 1
  assert_equal "cluster $environment rendered Application cardinality" \
    "$(yq ea -r '[.] | [.[] | select(.kind == "Application")] | length' "$rendered")" 2
  assert_equal "cluster $environment rendered ApplicationSet cardinality" \
    "$(yq ea -r '[.] | [.[] | select(.kind == "ApplicationSet")] | length' "$rendered")" 1

  project=messaging-platform
  operator="$environment-arkmq-operator"
  zookeeper="$environment-shared-zookeeper"
  workloads="$environment-artemis-workloads"
  assert_equal "cluster $environment AppProject Argo CD namespace" \
    "$(render_scalar "$rendered" AppProject "$project" '.metadata.namespace')" argocd
  for application in "$operator" "$zookeeper"; do
    assert_equal "cluster $environment Application $application Argo CD namespace" \
      "$(render_scalar "$rendered" Application "$application" '.metadata.namespace')" argocd
  done
  assert_equal "cluster $environment ApplicationSet $workloads Argo CD namespace" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.metadata.namespace')" argocd
  assert_equal "cluster $environment project sync wave" \
    "$(render_scalar "$rendered" AppProject "$project" '.metadata.annotations."argocd.argoproj.io/sync-wave"')" -30
  assert_equal "cluster $environment composition interface annotations" \
    "$(KIND=AppProject NAME="$project" yq ea -r '
      select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))
      | .metadata.annotations | keys | sort | join(",")
    ' "$rendered")" \
    'argocd.argoproj.io/sync-wave,composition.artemis.apache.org/catalog-path,composition.artemis.apache.org/environment,composition.artemis.apache.org/git-revision,composition.artemis.apache.org/platform-namespace,composition.artemis.apache.org/repository,composition.artemis.apache.org/zookeeper-image-repository'
  assert_equal "cluster $environment operator sync wave" \
    "$(render_scalar "$rendered" Application "$operator" '.metadata.annotations."argocd.argoproj.io/sync-wave"')" -20
  assert_equal "cluster $environment ZooKeeper sync wave" \
    "$(render_scalar "$rendered" Application "$zookeeper" '.metadata.annotations."argocd.argoproj.io/sync-wave"')" -10
  assert_equal "cluster $environment workloads sync wave" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.metadata.annotations."argocd.argoproj.io/sync-wave"')" 0

  local_server=https://kubernetes.default.svc
  assert_equal "cluster $environment project platform destination" \
    "$(render_scalar "$rendered" AppProject "$project" '.spec.destinations[0].server + "|" + .spec.destinations[0].namespace')" \
    "$local_server|$(yq -r '.platformNamespace' "$topology")"
  assert_equal "cluster $environment project Workload Cell namespace policy" \
    "$(render_scalar "$rendered" AppProject "$project" '.spec.destinations[1].server + "|" + .spec.destinations[1].namespace')" \
    "$local_server|artemis-*"
  for application in "$operator" "$zookeeper"; do
    assert_equal "cluster $environment Application $application local destination" \
      "$(render_scalar "$rendered" Application "$application" '.spec.destination.server')" "$local_server"
    assert_equal "cluster $environment Application $application platform namespace" \
      "$(render_scalar "$rendered" Application "$application" '.spec.destination.namespace')" \
      "$(yq -r '.platformNamespace' "$topology")"
  done
  assert_equal "cluster $environment workloads local destination" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.template.spec.destination.server')" "$local_server"

  revision=$(render_scalar "$rendered" AppProject "$project" '.metadata.annotations."composition.artemis.apache.org/git-revision"')
  [[ -n "$revision" ]] || record_error "cluster $environment root-selected revision is empty"
  for application in "$operator" "$zookeeper"; do
    assert_equal "cluster $environment Application $application root-selected revision" \
      "$(render_scalar "$rendered" Application "$application" '.spec.source.targetRevision')" "$revision"
  done
  assert_equal "cluster $environment generator root-selected revision" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.generators[0].matrix.generators[0].git.revision')" "$revision"
  assert_equal "cluster $environment generated source root-selected revision" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.template.spec.source.targetRevision')" "$revision"

  repository=$(render_scalar "$rendered" AppProject "$project" '.metadata.annotations."composition.artemis.apache.org/repository"')
  assert_equal "cluster $environment project repository" \
    "$(render_scalar "$rendered" AppProject "$project" '.spec.sourceRepos[0]')" "$repository"
  for application in "$operator" "$zookeeper"; do
    assert_equal "cluster $environment Application $application repository" \
      "$(render_scalar "$rendered" Application "$application" '.spec.source.repoURL')" "$repository"
  done
  assert_equal "cluster $environment generator repository" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.generators[0].matrix.generators[0].git.repoURL')" "$repository"
  assert_equal "cluster $environment generated source repository" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.template.spec.source.repoURL')" "$repository"

  assert_equal "cluster $environment operator path" \
    "$(render_scalar "$rendered" Application "$operator" '.spec.source.path')" \
    "gitops/kustomize/arkmq-operator/overlays/$environment"
  assert_equal "cluster $environment ZooKeeper release identity" \
    "$(render_scalar "$rendered" Application "$zookeeper" '.spec.source.helm.releaseName')" "$zookeeper"
  assert_equal "cluster $environment ZooKeeper values path" \
    "$(render_scalar "$rendered" Application "$zookeeper" '.spec.source.helm.valueFiles[0]')" \
    "../../environments/$environment/zookeeper-values.yaml"
  assert_equal "cluster $environment workloads catalog path" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.generators[0].matrix.generators[0].git.files[0].path')" \
    "gitops/argocd/topology/$environment.yaml"
  assert_equal "cluster $environment workloads catalog expansion" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.generators[0].matrix.generators[1].list.elementsYaml')" \
    '{{ .workloadCells | toJson }}'
  assert_equal "cluster $environment workloads enable selector" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.generators[0].selector.matchLabels.enabled')" true
  assert_equal "cluster $environment workloads Application modification policy" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.syncPolicy.applicationsSync')" create-update
  assert_equal "cluster $environment workloads preserve resources on deletion" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.syncPolicy.preserveResourcesOnDeletion')" true
  assert_equal "cluster $environment Workload Cell Application identity template" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.template.metadata.name')" '{{.workloadCellName}}-artemis'
  assert_equal "cluster $environment Workload Cell Profile values path" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.template.spec.source.helm.valueFiles[0]')" \
    '../../argocd/profiles/{{.profile}}/values.yaml'
  assert_equal "cluster $environment environment integration values path" \
    "$(render_scalar "$rendered" ApplicationSet "$workloads" '.spec.template.spec.source.helm.valueFiles[1]')" \
    '../../environments/{{.environment}}/artemis-values.yaml'
  assert_equal "cluster $environment Workload Cell group identity template" \
    "$(parameter_value "$rendered" "$workloads" ha.groupName)" '{{.workloadCellName}}-group'
  assert_equal "cluster $environment Workload Cell Curator namespace template" \
    "$(parameter_value "$rendered" "$workloads" zookeeper.curatorNamespace)" \
    'artemis/{{.environment}}/{{.workloadCellName}}'
  assert_equal "cluster $environment Workload Cell redirect URI template" \
    "$(parameter_value "$rendered" "$workloads" keycloak.redirectUri)" 'https://{{.managementHost}}/console'
  assert_equal "cluster $environment standard disk guardrail feature template" \
    "$(parameter_value "$rendered" "$workloads" brokerProperties.maxDiskUsage)" \
    '{{ if eq (dig "diskGuardrail" "standard" .features) "conservative" }}80{{ else }}90{{ end }}'
  assert_equal "cluster $environment standard expiry feature template" \
    "$(parameter_value "$rendered" "$workloads" brokerProperties.addressSettings.expiry.enabled)" \
    '{{ dig "expiryResources" "false" .features }}'
  assert_sync_policy "$rendered" Application "$operator" .spec.syncPolicy "cluster $environment operator"
  assert_sync_policy "$rendered" Application "$zookeeper" .spec.syncPolicy "cluster $environment ZooKeeper"
  assert_sync_policy "$rendered" ApplicationSet "$workloads" .spec.template.spec.syncPolicy "cluster $environment workloads"
  assert_equal "cluster $environment operator PruneLast count" \
    "$(KIND=Application NAME="$operator" yq ea -r '
      select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))
      | [.spec.syncPolicy.syncOptions[] | select(. == "PruneLast=true")] | length
    ' "$rendered")" 1

  cell_count=$(yq -r '.workloadCells // [] | length' "$topology")
  workload_cell_count=$((workload_cell_count + cell_count))
  environment_enabled=0
  for ((index=0; index<cell_count; index++)); do
    cell=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].workloadCellName // "<unnamed>"' "$topology")
    allowed_keys='coordinationId enabled features logicalEnvironment managementHost profile resources storageSize trafficClass workloadCellName workloadNamespace'
    actual_keys=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)] | keys | sort | join(" ")' "$topology")
    [[ "$actual_keys" == "$allowed_keys" ]] || cell_error "$environment" "$cell" keys "allowed keys are: $allowed_keys; got: $actual_keys"
    for field in workloadCellName workloadNamespace coordinationId logicalEnvironment trafficClass managementHost storageSize resources profile features enabled; do
      FIELD="$field" INDEX="$index" yq -e '.workloadCells[env(INDEX)] | has(strenv(FIELD))' "$topology" >/dev/null || \
        cell_error "$environment" "$cell" "$field" 'field is required'
    done

    [[ "$cell" =~ ^$environment-[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
      cell_error "$environment" "$cell" workloadCellName "must start with $environment- and contain lowercase DNS-label characters"
    logical=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].logicalEnvironment // ""' "$topology")
    traffic=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].trafficClass // ""' "$topology")
    case "$traffic" in
      internal) namespace_class=int ;;
      external) namespace_class=ext ;;
      batch) namespace_class=batch ;;
      *)
        namespace_class=invalid
        cell_error "$environment" "$cell" trafficClass 'must be internal, external, or batch'
        ;;
    esac
    logical_slug=$(printf '%s' "$logical" | tr '[:upper:]' '[:lower:]')
    namespace=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].workloadNamespace // ""' "$topology")
    expected_namespace="artemis-$namespace_class-$logical_slug"
    [[ "$namespace" == "$expected_namespace" ]] || \
      cell_error "$environment" "$cell" workloadNamespace "must equal $expected_namespace"
    coordination=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].coordinationId // ""' "$topology")
    [[ "$coordination" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,15}$ ]] || \
      cell_error "$environment" "$cell" coordinationId 'must be 8-16 safe path characters'
    host=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].managementHost // ""' "$topology")
    [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || \
      cell_error "$environment" "$cell" managementHost 'must be a lowercase DNS hostname'
    storage=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].storageSize // ""' "$topology")
    [[ "$storage" =~ ^[1-9][0-9]*(Mi|Gi|Ti)$ ]] || \
      cell_error "$environment" "$cell" storageSize 'must be a positive Kubernetes binary quantity'
    enabled=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].enabled // ""' "$topology")
    [[ "$enabled" == true || "$enabled" == false ]] || \
      cell_error "$environment" "$cell" enabled 'must be the explicit string "true" or "false"'
    [[ "$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].enabled | tag' "$topology")" == '!!str' ]] || \
      cell_error "$environment" "$cell" enabled 'must be a string so the ApplicationSet selector is deterministic'
    if [[ "$enabled" == true ]]; then
      environment_enabled=$((environment_enabled + 1))
      enabled_cell_count=$((enabled_cell_count + 1))
    fi
    for resource_field in requests.cpu requests.memory limits.cpu limits.memory; do
      value=$(RESOURCE_FIELD="$resource_field" INDEX="$index" yq -r '.workloadCells[env(INDEX)].resources | eval("." + strenv(RESOURCE_FIELD)) // ""' "$topology")
      [[ -n "$value" ]] || cell_error "$environment" "$cell" "resources.$resource_field" 'sizing value is required'
    done
    profile=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].profile // ""' "$topology")
    if [[ ! "$profile" =~ ^[a-z][a-z0-9-]*$ || ! -f "$profile_dir/$profile/profile.yaml" ]]; then
      cell_error "$environment" "$cell" profile "unknown Profile: $profile"
    else
      feature_type=$(INDEX="$index" yq -r '.workloadCells[env(INDEX)].features | tag' "$topology")
      [[ "$feature_type" == '!!map' ]] || cell_error "$environment" "$cell" features 'must be a typed mapping'
      while IFS= read -r feature; do
        [[ -n "$feature" ]] || continue
        if ! FEATURE="$feature" yq -e '.featureOverrides | has(strenv(FEATURE))' "$profile_dir/$profile/profile.yaml" >/dev/null; then
          cell_error "$environment" "$cell" "features.$feature" "Profile $profile does not permit this override"
          continue
        fi
        expected_type=$(FEATURE="$feature" yq -r '.featureOverrides[strenv(FEATURE)].type' "$profile_dir/$profile/profile.yaml")
        actual_type=$(INDEX="$index" FEATURE="$feature" yq -r '.workloadCells[env(INDEX)].features[strenv(FEATURE)] | tag' "$topology")
        if [[ "$expected_type" == boolean && "$actual_type" != '!!bool' ]]; then
          cell_error "$environment" "$cell" "features.$feature" 'must be a boolean'
        elif [[ "$expected_type" == enum ]]; then
          feature_value=$(INDEX="$index" FEATURE="$feature" yq -r '.workloadCells[env(INDEX)].features[strenv(FEATURE)]' "$topology")
          FEATURE="$feature" VALUE="$feature_value" yq -e \
            '.featureOverrides[strenv(FEATURE)].values | any_c(. == strenv(VALUE))' \
            "$profile_dir/$profile/profile.yaml" >/dev/null || \
            cell_error "$environment" "$cell" "features.$feature" "value $feature_value is not allowed by Profile $profile"
        fi
      done < <(INDEX="$index" yq -r '.workloadCells[env(INDEX)].features | keys | .[]' "$topology" 2>/dev/null || true)
    fi

    if [[ -f "$baseline_policy" ]]; then
      baseline_matches=$(ENVIRONMENT="$environment" CELL="$cell" yq -r \
        '[.clusters[env(ENVIRONMENT)].requiredWorkloadCells[] | select(.workloadCellName == strenv(CELL))] | length' \
        "$baseline_policy")
      if [[ "$baseline_matches" == 0 && "$enabled" != false ]]; then
        cell_error "$environment" "$cell" enabled 'a new Workload Cell must begin disabled'
      fi
    fi
  done

  for unique_field in workloadCellName workloadNamespace coordinationId managementHost; do
    duplicate_count=$(FIELD="$unique_field" yq -r '
      [.workloadCells | group_by(.[strenv(FIELD)])[] | select(length > 1)] | length
    ' "$topology")
    [[ "$duplicate_count" == 0 ]] || record_error "cluster $environment Workload Cell field $unique_field violates uniqueness rule ($duplicate_count duplicate groups)"
  done

  if [[ -f "$baseline_policy" ]]; then
    baseline_count=$(ENVIRONMENT="$environment" yq -r '.clusters[env(ENVIRONMENT)].requiredWorkloadCells | length' "$baseline_policy")
    for ((baseline_index=0; baseline_index<baseline_count; baseline_index++)); do
      baseline_cell=$(ENVIRONMENT="$environment" INDEX="$baseline_index" yq -r '.clusters[env(ENVIRONMENT)].requiredWorkloadCells[env(INDEX)].workloadCellName' "$baseline_policy")
      matches=$(CELL="$baseline_cell" yq -r '[.workloadCells[] | select(.workloadCellName == strenv(CELL))] | length' "$topology")
      if [[ "$matches" != 1 ]]; then
        cell_error "$environment" "$baseline_cell" workloadCellName 'required baseline Workload Cell is missing'
        continue
      fi
      for field in workloadNamespace coordinationId logicalEnvironment trafficClass managementHost storageSize profile enabled; do
        expected=$(ENVIRONMENT="$environment" INDEX="$baseline_index" FIELD="$field" yq -r '.clusters[env(ENVIRONMENT)].requiredWorkloadCells[env(INDEX)][env(FIELD)]' "$baseline_policy")
        actual=$(CELL="$baseline_cell" FIELD="$field" yq -r '.workloadCells[] | select(.workloadCellName == strenv(CELL)) | .[strenv(FIELD)]' "$topology")
        [[ "$actual" == "$expected" ]] || cell_error "$environment" "$baseline_cell" "$field" "baseline requires $expected; got $actual"
      done
    done
  fi

  # Environment values are cluster integrations only and cannot collide with
  # Profile-owned capabilities.
  environment_values="$environment_dir/$environment/artemis-values.yaml"
  if [[ -f "$environment_values" ]]; then
    while IFS= read -r leaf; do
      [[ "$leaf" =~ ^commonLabels\. || "$leaf" =~ ^broker\.(nodeSelector|tolerations|labels|annotations)\. || "$leaf" == persistence.storageClassName || "$leaf" == persistence.journalType || "$leaf" =~ ^keycloak\. || "$leaf" =~ ^vault\. || "$leaf" =~ ^console\.ingress\.(className|annotations)\. || "$leaf" =~ ^networkPolicy\.(clientSources|managementSources|monitoringSources|extraIngress|extraEgress)\. || "$leaf" =~ ^monitoring\.(serviceMonitor|prometheusRule)\.(namespace|labels) ]] || \
        record_error "cluster $environment environment field $leaf violates cluster-integration ownership"
      for profile in $known_profiles; do
        if yq -r '.. | select(tag != "!!map" and tag != "!!seq") | path | join(".")' "$profile_dir/$profile/values.yaml" | grep -Fxq "$leaf"; then
          record_error "cluster $environment environment field $leaf conflicts with Workload Cell Profile $profile"
        fi
      done
    done < <(yq -r '.. | select(tag != "!!map" and tag != "!!seq") | path | join(".")' "$environment_values")
  else
    record_error "cluster $environment environment values are missing: $environment_values"
  fi

  if [[ -n "$distribution_json" ]]; then distribution_json="$distribution_json,"; fi
  distribution_json="$distribution_json\"$environment\":$cell_count"
done

assert_equal 'rendered cluster adapter count' "$cluster_count" 3

if rg -n 'brokerPairs|brokerPairName|clusterServer|PLACEHOLDER_(TEST|NONPROD|PROD)_EKS_API_SERVER' \
    "$topology_dir" "$bootstrap_dir/base" >/dev/null; then
  record_error 'retired broker-pair or cross-cluster interface data remains in the shared composition'
fi

status=PASS
[[ "$errors" -eq 0 ]] || status=FAIL
printf '{"schemaVersion":"validation.artemis.apache.org/report/v1","check":"rendered-cluster-composition","status":"%s","clusters":%d,"workloadCells":%d,"enabledWorkloadCells":%d,"distribution":{%s},"projectOwner":"shared-kustomize-base","errors":%d,"topologyDirectory":"%s","bootstrapDirectory":"%s"}\n' \
  "$status" "$cluster_count" "$workload_cell_count" "$enabled_cell_count" "$distribution_json" "$errors" \
  "${topology_dir#"$repo_root/"}" "${bootstrap_dir#"$repo_root/"}" > "$report"
printf '%s\n' \
  "topology validation: $status ($cluster_count rendered cluster compositions, $workload_cell_count Workload Cells, $errors errors)"
[[ "$errors" -eq 0 ]]
