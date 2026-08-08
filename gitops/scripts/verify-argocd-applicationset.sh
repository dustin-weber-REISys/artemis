#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

context=
argocd_namespace=
environment=
controller_deployment=argocd-applicationset-controller

usage() {
  cat <<'USAGE'
Usage: verify-argocd-applicationset.sh \
  --context CONTEXT \
  --argocd-namespace NAMESPACE \
  --environment test|nonprod|prod \
  [--controller-deployment NAME]

Read-only verification that the ApplicationSet controller and ArkMQ operator
are available, every enabled broker pair has an Argo CD Application, and the
operator has reconciled each ActiveMQArtemis CR into its expected StatefulSet.
USAGE
}

require_value() {
  option=$1
  value=${2-}
  [[ -n "$value" ]] || {
    printf '%s requires a value\n' "$option" >&2
    exit 2
  }
}

while (($#)); do
  case "$1" in
    --context)
      require_value "$1" "${2-}"
      context=$2
      shift 2
      ;;
    --argocd-namespace)
      require_value "$1" "${2-}"
      argocd_namespace=$2
      shift 2
      ;;
    --environment)
      require_value "$1" "${2-}"
      environment=$2
      shift 2
      ;;
    --controller-deployment)
      require_value "$1" "${2-}"
      controller_deployment=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$context" ]] || { printf '%s\n' '--context is required' >&2; exit 2; }
[[ -n "$argocd_namespace" ]] || { printf '%s\n' '--argocd-namespace is required' >&2; exit 2; }
case "$environment" in
  test|nonprod|prod) ;;
  *) printf '%s\n' '--environment must be test, nonprod, or prod' >&2; exit 2 ;;
esac

command -v kubectl >/dev/null 2>&1 || {
  printf '%s\n' 'kubectl is required' >&2
  exit 2
}
command -v yq >/dev/null 2>&1 || {
  printf '%s\n' 'yq is required (the repository baseline uses yq 4.53.3)' >&2
  exit 2
}

topology="$repo_root/argocd/topology/$environment.yaml"
applicationset="$environment-artemis-workloads"
operator_application="$environment-arkmq-operator"
project=messaging-platform
local_server=https://kubernetes.default.svc
platform_namespace=$(yq -r '.platformNamespace // ""' "$topology")
operator_deployment=activemq-artemis-controller-manager-v2
operator_service_account=activemq-artemis-controller-manager
kubectl_args=(--context "$context" --namespace "$argocd_namespace")
errors=0
checkout_revision=
required_resource_labels=(app contact env fismaid)

if checkout_revision=$(git -C "$repo_root/.." rev-parse HEAD 2>/dev/null); then
  printf 'Repository checkout revision: %s\n' "$checkout_revision"
fi

error() {
  printf 'ERROR: %s\n' "$*" >&2
  errors=$((errors + 1))
}

[[ -n "$platform_namespace" ]] || error "$environment topology does not declare platformNamespace"

controller_json=
if ! controller_json=$(kubectl "${kubectl_args[@]}" get deployment "$controller_deployment" -o json); then
  error "ApplicationSet controller Deployment $argocd_namespace/$controller_deployment is not readable; confirm it is installed in the Argo CD namespace"
else
  available=$(yq -r '.status.availableReplicas // 0' <<<"$controller_json")
  desired=$(yq -r '.spec.replicas // 1' <<<"$controller_json")
  if [[ "$available" -lt 1 ]]; then
    error "ApplicationSet controller has $available available replicas (desired: $desired)"
  else
    printf 'ApplicationSet controller: available (%s/%s replicas)\n' "$available" "$desired"
  fi
fi

operator_application_json=
if ! operator_application_json=$(kubectl "${kubectl_args[@]}" \
  get application "$operator_application" -o json); then
  error "ArkMQ operator Application $argocd_namespace/$operator_application is not readable"
else
  operator_source_count=$(yq -r \
    '[.spec.source | select(. != null)] | length' \
    <<<"$operator_application_json")
  operator_multi_source_count=$(yq -r '.spec.sources // [] | length' \
    <<<"$operator_application_json")
  if [[ "$operator_source_count" -ne 1 || "$operator_multi_source_count" -ne 0 ]]; then
    error "ArkMQ operator Application $argocd_namespace/$operator_application must declare exactly one spec.source and no spec.sources entries"
  fi

  operator_path=$(yq -r '.spec.source.path // ""' \
    <<<"$operator_application_json")
  operator_release=$(yq -r '.spec.source.helm.releaseName // ""' \
    <<<"$operator_application_json")
  operator_environment_count=$(ENVIRONMENT="$environment" yq -r '
    [.spec.source.helm.parameters[]?
      | select(
          .name == "global.requiredLabels.env" and
          .value == strenv(ENVIRONMENT)
        )
    ] | length
  ' <<<"$operator_application_json")
  operator_cluster_scope_count=$(yq -r '
    [.spec.source.helm.parameters[]?
      | select(
          .name == "arkmq-org-broker-operator.clusterScoped" and
          .value == "true"
        )
    ] | length
  ' <<<"$operator_application_json")
  operator_server=$(yq -r '.spec.destination.server // ""' \
    <<<"$operator_application_json")
  operator_namespace=$(yq -r '.spec.destination.namespace // ""' \
    <<<"$operator_application_json")

  [[ "$operator_path" == 'gitops/charts/arkmq-operator' ]] || \
    error "ArkMQ operator Application $argocd_namespace/$operator_application uses path $operator_path; expected gitops/charts/arkmq-operator"
  [[ "$operator_release" == "$operator_application" ]] || \
    error "ArkMQ operator Application $argocd_namespace/$operator_application uses Helm release $operator_release; expected $operator_application"
  [[ "$operator_environment_count" -eq 1 ]] || \
    error "ArkMQ operator Application $argocd_namespace/$operator_application must set global.requiredLabels.env=$environment exactly once"
  [[ "$operator_cluster_scope_count" -eq 1 ]] || \
    error "ArkMQ operator Application $argocd_namespace/$operator_application must set arkmq-org-broker-operator.clusterScoped=true exactly once"
  if [[ "$operator_server" != "$local_server" || "$operator_namespace" != "$platform_namespace" ]]; then
    error "ArkMQ operator Application $argocd_namespace/$operator_application targets $operator_server namespace $operator_namespace; expected $local_server namespace $platform_namespace"
  fi

  operator_sync_status=$(yq -r '.status.sync.status // ""' \
    <<<"$operator_application_json")
  operator_health_status=$(yq -r '.status.health.status // ""' \
    <<<"$operator_application_json")
  operator_reconciled_revision=$(yq -r '.status.sync.revision // ""' \
    <<<"$operator_application_json")
  [[ "$operator_sync_status" == Synced ]] || \
    error "ArkMQ operator Application $argocd_namespace/$operator_application sync status is $operator_sync_status; expected Synced"
  [[ "$operator_health_status" == Healthy ]] || \
    error "ArkMQ operator Application $argocd_namespace/$operator_application health is $operator_health_status; expected Healthy"
  if [[ -n "$checkout_revision" && -n "$operator_reconciled_revision" && \
        "$operator_reconciled_revision" != "$checkout_revision" ]]; then
    error "ArkMQ operator Application $argocd_namespace/$operator_application reconciled revision $operator_reconciled_revision differs from repository checkout $checkout_revision"
  fi

  operator_repeated_resource_message=$(yq -r '
    [.status.conditions[]?
      | select(.type == "RepeatedResourceWarning")
      | .message
    ] | join("; ")
  ' <<<"$operator_application_json")
  if [[ -n "$operator_repeated_resource_message" ]]; then
    error "ArkMQ operator Application $argocd_namespace/$operator_application has RepeatedResourceWarning: $operator_repeated_resource_message"
  fi

  tracked_operator_cluster_role_count=$(yq -r '
    [.status.resources[]?
      | select(
          .group == "rbac.authorization.k8s.io" and
          .kind == "ClusterRole" and
          .name == "activemq-artemis-operator-role"
        )
    ] | length
  ' <<<"$operator_application_json")
  tracked_operator_cluster_role_binding_count=$(yq -r '
    [.status.resources[]?
      | select(
          .group == "rbac.authorization.k8s.io" and
          .kind == "ClusterRoleBinding" and
          .name == "activemq-artemis-operator-rolebinding"
        )
    ] | length
  ' <<<"$operator_application_json")
  [[ "$tracked_operator_cluster_role_count" -eq 1 ]] || \
    error "ArkMQ operator Application $argocd_namespace/$operator_application does not track expected ClusterRole activemq-artemis-operator-role"
  [[ "$tracked_operator_cluster_role_binding_count" -eq 1 ]] || \
    error "ArkMQ operator Application $argocd_namespace/$operator_application does not track expected ClusterRoleBinding activemq-artemis-operator-rolebinding"

  printf 'ArkMQ operator Application: %s/%s revision=%s\n' \
    "$operator_sync_status" "$operator_health_status" \
    "${operator_reconciled_revision:-unknown}"
fi

operator_json=
if [[ -n "$platform_namespace" ]]; then
  if ! operator_json=$(kubectl --context "$context" --namespace "$platform_namespace" \
    get deployment "$operator_deployment" -o json); then
    error "ArkMQ operator Deployment $platform_namespace/$operator_deployment is not readable; the broker CR cannot be reconciled without it"
  else
    operator_available=$(yq -r '.status.availableReplicas // 0' <<<"$operator_json")
    operator_desired=$(yq -r '.spec.replicas // 1' <<<"$operator_json")
    if [[ "$operator_available" -lt 1 ]]; then
      error "ArkMQ operator has $operator_available available replicas (desired: $operator_desired); a synced broker CR cannot produce a StatefulSet until the operator runs"
    else
      printf 'ArkMQ operator: available (%s/%s replicas)\n' \
        "$operator_available" "$operator_desired"
    fi

    operator_lifecycle_toleration_count=$(yq -r '
      [.spec.template.spec.tolerations[]?
        | select(
            .key == "eid-platform/node-lifecycle" and
            .operator == "Equal" and
            .value == "ondemand" and
            .effect == "NoSchedule"
          )
      ] | length
    ' <<<"$operator_json")
    if [[ "$operator_lifecycle_toleration_count" -ne 1 ]]; then
      error "ArkMQ operator Deployment does not contain exactly one eid-platform/node-lifecycle=ondemand:NoSchedule toleration"
    fi

    watch_namespace_count=$(yq -r '
      [.spec.template.spec.containers[]?
        | select(.name == "manager")
        | .env[]?
        | select(.name == "WATCH_NAMESPACE")
      ] | length
    ' <<<"$operator_json")
    watch_namespace=$(yq -r '
      [.spec.template.spec.containers[]?
        | select(.name == "manager")
        | .env[]?
        | select(.name == "WATCH_NAMESPACE")
        | .value // ""
      ][0] // ""
    ' <<<"$operator_json")
    if [[ "$watch_namespace_count" -ne 1 ]]; then
      error "ArkMQ operator Deployment must declare exactly one WATCH_NAMESPACE environment variable"
    elif [[ -n "$watch_namespace" ]]; then
      error "ArkMQ operator WATCH_NAMESPACE is '$watch_namespace'; this repository requires cluster-wide watch scope"
    else
      printf '%s\n' 'ArkMQ operator watch scope: cluster-wide'
    fi

    operator_identity="system:serviceaccount:$platform_namespace:$operator_service_account"
    for authorization_check in \
      'list activemqartemises.broker.amq.io' \
      'watch activemqartemises.broker.amq.io' \
      'list configmaps' \
      'watch configmaps' \
      'list statefulsets.apps' \
      'watch statefulsets.apps'; do
      read -r verb resource <<<"$authorization_check"
      if authorization_result=$(kubectl --context "$context" auth can-i \
        "$verb" "$resource" \
        --all-namespaces \
        --as "$operator_identity" 2>&1); then
        if [[ "$authorization_result" != "yes" ]]; then
          error "ArkMQ operator authorization denied: $verb $resource at cluster scope ($authorization_result)"
        fi
      else
        error "ArkMQ operator authorization review failed for $verb $resource at cluster scope: $authorization_result"
      fi
    done

    for authorization_check in \
      'create statefulsets.apps' \
      'update statefulsets.apps' \
      'create persistentvolumeclaims' \
      'create services' \
      'create secrets' \
      'create configmaps'; do
      read -r verb resource <<<"$authorization_check"
      if authorization_result=$(kubectl --context "$context" auth can-i \
        "$verb" "$resource" \
        --namespace "$platform_namespace" \
        --as "$operator_identity" 2>&1); then
        if [[ "$authorization_result" != "yes" ]]; then
          error "ArkMQ operator authorization denied for namespaced write: $verb $resource ($authorization_result)"
        fi
      else
        error "ArkMQ operator authorization review failed for namespaced write $verb $resource: $authorization_result"
      fi
    done
  fi
fi

applicationset_json=
declared_parameter_names=
declared_repo_url=
declared_revision=
declared_path=
declared_value_files=
declared_release_name=
if ! applicationset_json=$(kubectl "${kubectl_args[@]}" get applicationset "$applicationset" -o json); then
  error "ApplicationSet $argocd_namespace/$applicationset is not readable"
else
  condition_count=$(yq -r '.status.conditions // [] | length' <<<"$applicationset_json")
  if [[ "$condition_count" -eq 0 ]]; then
    error "ApplicationSet has no status conditions; its controller has not reconciled it"
  else
    printf '%s\n' 'ApplicationSet conditions:'
    yq -r '.status.conditions[] | "  \(.type)=\(.status): \(.message // \"\")"' <<<"$applicationset_json"
    error_count=$(yq -r '[.status.conditions[] | select(.type == "ErrorOccurred" and .status == "True")] | length' <<<"$applicationset_json")
    [[ "$error_count" -eq 0 ]] || error 'ApplicationSet reports ErrorOccurred=True'
  fi
  parent_multi_source_count=$(yq -r '.spec.template.spec.sources // [] | length' \
    <<<"$applicationset_json")
  if [[ "$parent_multi_source_count" -ne 0 ]]; then
    error "ApplicationSet $argocd_namespace/$applicationset declares spec.sources with $parent_multi_source_count entries; Artemis workloads require exactly one Git/Helm source"
  fi
  if [[ "$(yq -r '.spec.template.spec.source == null' <<<"$applicationset_json")" == "true" ]]; then
    error "ApplicationSet $argocd_namespace/$applicationset does not declare spec.source"
  fi
  declared_repo_url=$(yq -r '.spec.template.spec.source.repoURL // ""' \
    <<<"$applicationset_json")
  declared_revision=$(yq -r '.spec.template.spec.source.targetRevision // ""' \
    <<<"$applicationset_json")
  declared_path=$(yq -r '.spec.template.spec.source.path // ""' \
    <<<"$applicationset_json")
  declared_value_files=$(yq -o=json -I=0 \
    '.spec.template.spec.source.helm.valueFiles // []' <<<"$applicationset_json" |
    sed "s/{{\\.environment}}/$environment/g")
  declared_release_name=$(yq -r \
    '.spec.template.spec.source.helm.releaseName // ""' <<<"$applicationset_json")
  declared_parameter_names=$(yq -r \
    '.spec.template.spec.source.helm.parameters // [] | map(.name) | sort | .[]' \
    <<<"$applicationset_json")
  invalid_empty_selector_parameters=$(yq -r '
    [.spec.template.spec.source.helm.parameters[]?
      | select(
          (.value == "{}") and
          (.name | test("^networkPolicy\\.(clientSources|managementSources|monitoringSources)\\[[0-9]+\\]\\.(namespaceSelector|podSelector)$"))
        )
      | .name
    ] | sort | .[]
  ' <<<"$applicationset_json")
  if [[ -n "$invalid_empty_selector_parameters" ]]; then
    error "ApplicationSet $argocd_namespace/$applicationset declares selector parameters with value {}; Helm parses {} as an array, not an object: $(paste -sd, - <<<"$invalid_empty_selector_parameters")"
  fi
fi

project_json=
if ! project_json=$(kubectl "${kubectl_args[@]}" get appproject "$project" -o json); then
  error "AppProject $argocd_namespace/$project is not readable"
fi

enabled_pairs=()
while IFS= read -r enabled_pair; do
  enabled_pairs[${#enabled_pairs[@]}]=$enabled_pair
done < <(
  yq -r '.brokerPairs[] | select(.enabled == "true") | [.brokerPairName, .workloadNamespace] | @tsv' "$topology"
)
if [[ "${#enabled_pairs[@]}" -eq 0 ]]; then
  error "$environment topology has no enabled broker pairs"
fi

for enabled_pair in "${enabled_pairs[@]}"; do
  IFS=$'\t' read -r broker_pair workload_namespace <<<"$enabled_pair"
  application="$broker_pair-artemis"

  if [[ -n "$project_json" ]]; then
    destination_count=$(SERVER="$local_server" NAMESPACE="$workload_namespace" yq -r '
      [.spec.destinations[]?
        | select(.server == strenv(SERVER) and .namespace == strenv(NAMESPACE))
      ] | length
    ' <<<"$project_json")
    if [[ "$destination_count" -ne 1 ]]; then
      error "AppProject $argocd_namespace/$project does not allow destination $local_server namespace $workload_namespace for enabled broker pair $broker_pair"
    else
      printf 'Approved project destination: %s/%s\n' "$local_server" "$workload_namespace"
    fi
  fi

  application_json=
  if ! application_json=$(kubectl "${kubectl_args[@]}" get application "$application" -o json); then
    error "enabled broker pair $broker_pair did not produce Application $argocd_namespace/$application"
    continue
  fi

  owner_count=$(APPLICATIONSET="$applicationset" yq -r \
    '[.metadata.ownerReferences[]? | select(.kind == "ApplicationSet" and .name == strenv(APPLICATIONSET))] | length' \
    <<<"$application_json")
  if [[ "$owner_count" -ne 1 ]]; then
    error "Application $argocd_namespace/$application is not owned by ApplicationSet $applicationset"
  else
    printf 'Generated Application: %s/%s\n' "$argocd_namespace" "$application"
  fi

  actual_release_name=$(yq -r \
    '.spec.source.helm.releaseName // ""' <<<"$application_json")

  if [[ -n "$applicationset_json" ]]; then
    child_multi_source_count=$(yq -r '.spec.sources // [] | length' \
      <<<"$application_json")
    if [[ "$child_multi_source_count" -ne 0 ]]; then
      error "Application $argocd_namespace/$application declares spec.sources with $child_multi_source_count entries; this can render the same ActiveMQArtemis identity more than once"
    fi
    if [[ "$(yq -r '.spec.source == null' <<<"$application_json")" == "true" ]]; then
      error "Application $argocd_namespace/$application does not declare the single spec.source owned by ApplicationSet $applicationset"
    fi

    actual_repo_url=$(yq -r '.spec.source.repoURL // ""' <<<"$application_json")
    actual_revision=$(yq -r '.spec.source.targetRevision // ""' <<<"$application_json")
    actual_path=$(yq -r '.spec.source.path // ""' <<<"$application_json")
    actual_value_files=$(yq -o=json -I=0 \
      '.spec.source.helm.valueFiles // []' <<<"$application_json")
    [[ "$actual_repo_url" == "$declared_repo_url" ]] || \
      error "Application $argocd_namespace/$application repoURL differs from ApplicationSet $applicationset"
    [[ "$actual_revision" == "$declared_revision" ]] || \
      error "Application $argocd_namespace/$application targetRevision differs from ApplicationSet $applicationset"
    [[ "$actual_path" == "$declared_path" ]] || \
      error "Application $argocd_namespace/$application path differs from ApplicationSet $applicationset"
    [[ "$actual_value_files" == "$declared_value_files" ]] || \
      error "Application $argocd_namespace/$application valueFiles differ from ApplicationSet $applicationset"
    [[ "$actual_release_name" == "$declared_release_name" ]] || \
      error "Application $argocd_namespace/$application releaseName differs from ApplicationSet $applicationset"

    actual_parameter_names=$(yq -r \
      '.spec.source.helm.parameters // [] | map(.name) | sort | .[]' \
      <<<"$application_json")
    if [[ "$actual_parameter_names" != "$declared_parameter_names" ]]; then
      unexpected_parameter_names=$(comm -13 \
        <(printf '%s\n' "$declared_parameter_names" | sed '/^$/d') \
        <(printf '%s\n' "$actual_parameter_names" | sed '/^$/d'))
      missing_parameter_names=$(comm -23 \
        <(printf '%s\n' "$declared_parameter_names" | sed '/^$/d') \
        <(printf '%s\n' "$actual_parameter_names" | sed '/^$/d'))
      parameter_drift=''
      if [[ -n "$unexpected_parameter_names" ]]; then
        parameter_drift=" unexpected: $(paste -sd, - <<<"$unexpected_parameter_names")"
      fi
      if [[ -n "$missing_parameter_names" ]]; then
        parameter_drift="$parameter_drift missing: $(paste -sd, - <<<"$missing_parameter_names")"
      fi
      error "Application $argocd_namespace/$application Helm parameters differ from ApplicationSet $applicationset;$parameter_drift"
    fi
  fi

  actual_server=$(yq -r '.spec.destination.server // ""' <<<"$application_json")
  actual_namespace=$(yq -r '.spec.destination.namespace // ""' <<<"$application_json")
  if [[ "$actual_server" != "$local_server" || "$actual_namespace" != "$workload_namespace" ]]; then
    error "Application $argocd_namespace/$application targets $actual_server namespace $actual_namespace; expected $local_server namespace $workload_namespace"
  fi

  invalid_spec_count=$(yq -r '
    [.status.conditions[]? | select(.type == "InvalidSpecError")]
    | length
  ' <<<"$application_json")
  if [[ "$invalid_spec_count" -ne 0 ]]; then
    invalid_spec_message=$(yq -r '
      [.status.conditions[]? | select(.type == "InvalidSpecError") | .message]
      | join("; ")
    ' <<<"$application_json")
    error "Application $argocd_namespace/$application has InvalidSpecError: $invalid_spec_message"
  fi

  repeated_resource_count=$(yq -r '
    [.status.conditions[]? | select(.type == "RepeatedResourceWarning")]
    | length
  ' <<<"$application_json")
  if [[ "$repeated_resource_count" -ne 0 ]]; then
    repeated_resource_message=$(yq -r '
      [.status.conditions[]?
        | select(.type == "RepeatedResourceWarning")
        | .message]
      | join("; ")
    ' <<<"$application_json")
    error "Application $argocd_namespace/$application has RepeatedResourceWarning: $repeated_resource_message"
  fi

  # Argo owns the chart resources, but the operator owns the broker
  # StatefulSet. A green ActiveMQArtemis node in Argo proves only that the CR
  # was applied; its status and generated StatefulSet prove reconciliation.
  helm_release_name=$actual_release_name
  [[ -n "$helm_release_name" ]] || helm_release_name=$application
  broker_cr="${helm_release_name}-artemis-ha"
  if ((${#broker_cr} > 63)); then
    broker_cr=${broker_cr:0:63}
    broker_cr=${broker_cr%-}
  fi

  broker_json=
  if ! broker_json=$(kubectl --context "$context" --namespace "$workload_namespace" \
    get activemqartemis "$broker_cr" -o json); then
    error "Application $argocd_namespace/$application did not produce readable ActiveMQArtemis $workload_namespace/$broker_cr"
    continue
  fi

  missing_metadata_labels=()
  missing_deployment_labels=()
  missing_resource_template_labels=()
  for required_label in "${required_resource_labels[@]}"; do
    if [[ "$(LABEL="$required_label" yq -r '.metadata.labels[strenv(LABEL)] // ""' \
      <<<"$broker_json")" == "" ]]; then
      missing_metadata_labels+=("$required_label")
    fi
    if [[ "$(LABEL="$required_label" yq -r '.spec.deploymentPlan.labels[strenv(LABEL)] // ""' \
      <<<"$broker_json")" == "" ]]; then
      missing_deployment_labels+=("$required_label")
    fi
    matching_template_count=$(LABEL="$required_label" yq -r '
      [.spec.resourceTemplates[]?
        | select(
            (.selector.apiGroup // "") == "" and
            (.selector.kind // "") == "" and
            (.selector.name // "") == "" and
            (.labels[strenv(LABEL)] // "") != ""
          )]
      | length
    ' <<<"$broker_json")
    if [[ "$matching_template_count" -eq 0 ]]; then
      missing_resource_template_labels+=("$required_label")
    fi
  done
  if ((${#missing_metadata_labels[@]})); then
    error "ActiveMQArtemis $workload_namespace/$broker_cr metadata.labels is missing required labels: $(IFS=,; printf '%s' "${missing_metadata_labels[*]}")"
  fi
  if ((${#missing_deployment_labels[@]})); then
    error "ActiveMQArtemis $workload_namespace/$broker_cr spec.deploymentPlan.labels is missing required labels: $(IFS=,; printf '%s' "${missing_deployment_labels[*]}")"
  fi
  if ((${#missing_resource_template_labels[@]})); then
    error "ActiveMQArtemis $workload_namespace/$broker_cr has no unscoped spec.resourceTemplates entry carrying required labels: $(IFS=,; printf '%s' "${missing_resource_template_labels[*]}"); sync gitops/charts/artemis-ha/templates/activemqartemis.yaml"
  fi

  broker_generation=$(yq -r '.metadata.generation // 0' <<<"$broker_json")
  broker_condition_count=$(yq -r '.status.conditions // [] | length' <<<"$broker_json")
  if [[ "$broker_condition_count" -eq 0 ]]; then
    error "ActiveMQArtemis $workload_namespace/$broker_cr has no status conditions; the ArkMQ operator has not processed generation $broker_generation"
  else
    printf 'Broker reconciliation conditions: %s/%s generation=%s\n' \
      "$workload_namespace" "$broker_cr" "$broker_generation"
    yq -r '.status.conditions[] |
      "  \(.type)=\(.status) reason=\(.reason) observedGeneration=\(.observedGeneration // 0): \(.message // \"\")"' \
      <<<"$broker_json"

    failed_conditions=$(yq -r '
      (.status.conditions // [])
      | map(select(
          .status == "False" and
          (.type == "Valid" or .type == "Deployed")
        ))
      | map(.type + "=False reason=" + .reason + ": " + (.message // ""))
      | join("; ")
    ' <<<"$broker_json")
    if [[ -n "$failed_conditions" ]]; then
      error "ActiveMQArtemis $workload_namespace/$broker_cr reconciliation failed: $failed_conditions"
    fi
  fi

  statefulset="$broker_cr-ss"
  statefulset_json=
  if ! statefulset_json=$(kubectl --context "$context" --namespace "$workload_namespace" \
    get statefulset "$statefulset" -o json); then
    error "ArkMQ operator has not created expected StatefulSet $workload_namespace/$statefulset"
  else
    desired_replicas=$(yq -r '.spec.replicas // 0' <<<"$statefulset_json")
    current_replicas=$(yq -r '.status.currentReplicas // 0' <<<"$statefulset_json")
    ready_replicas=$(yq -r '.status.readyReplicas // 0' <<<"$statefulset_json")
    printf 'Broker StatefulSet: %s/%s desired=%s current=%s ready=%s\n' \
      "$workload_namespace" "$statefulset" "$desired_replicas" \
      "$current_replicas" "$ready_replicas"
  fi
done

if [[ "$errors" -ne 0 ]]; then
  printf 'ApplicationSet verification: FAIL (%s errors)\n' "$errors" >&2
  exit 1
fi

printf 'ApplicationSet verification: PASS (%s enabled broker pairs)\n' "${#enabled_pairs[@]}"
