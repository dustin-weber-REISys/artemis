#!/usr/bin/env bash
set -euo pipefail

operator_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
gitops_dir=$(CDPATH= cd -- "$operator_dir/../.." && pwd)
release_file="$gitops_dir/releases/current.yaml"
renderer="$gitops_dir/scripts/render-arkmq-operator.sh"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/arkmq-operator-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

for command_name in rg yq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
done

operator_version=$(yq -r '.operator.version' "$release_file")
operator_image_tag=$(yq -r '.operator.image.tag' "$release_file")
broker_version=$(yq -r '.broker.version' "$release_file")
broker_init_image_tag=$(yq -r '.broker.images.init.tag' "$release_file")
broker_runtime_image_tag=$(yq -r '.broker.images.runtime.tag' "$release_file")
broker_compact=${broker_version//./}

if [[ -z "${ARKMQ_UPSTREAM_CHART:-}" ]]; then
  if [[ "${ARTEMIS_RELEASE_GATE:-false}" == true ]]; then
    printf '%s\n' 'ArkMQ operator rendered tests require ARKMQ_UPSTREAM_CHART in the release gate' >&2
    exit 2
  fi
  printf '%s\n' 'ArkMQ operator rendered tests: NOT_RUN (set ARKMQ_UPSTREAM_CHART to the approved upstream .tgz)'
  exit 0
fi

for environment in test nonprod prod; do
  rendered="$work_dir/$environment.yaml"
  ecr_repository=PLACEHOLDER_NONPROD_ECR_REPOSITORY
  if [[ "$environment" == prod ]]; then
    ecr_repository=PLACEHOLDER_PROD_ECR_REPOSITORY
  fi
  "$renderer" --environment "$environment" \
    --artifact "$ARKMQ_UPSTREAM_CHART" > "$rendered"

  if rg -F 'quay.io/arkmq-org/' "$rendered" >/dev/null; then
    printf '%s operator render contains an unapproved public runtime image\n' \
      "$environment" >&2
    exit 1
  fi

  duplicate_resources=$(
    yq -r '
      select(.apiVersion != null and .kind != null and .metadata.name != null)
      | [.apiVersion, .kind, (.metadata.namespace // ""), .metadata.name]
      | @tsv
    ' "$rendered" |
      sort |
      uniq -d
  )
  if [[ -n "$duplicate_resources" ]]; then
    printf 'duplicate rendered resource identities for %s:\n%s\n' \
      "$environment" "$duplicate_resources" >&2
    exit 1
  fi

  yq eval-all -e '
    [.] |
      (([.[] | select(.kind == "Deployment")] | length) == 1 and
       ([.[] |
         select(.kind == "Deployment") |
         select(.metadata.name == "activemq-artemis-controller-manager-v2")
        ] | length) == 1)
  ' "$rendered" >/dev/null

  ENVIRONMENT="$environment" yq eval-all -e '
    [.] | ([.[] | select(
      .metadata.labels.app != "artemis" or
      .metadata.labels.contact != "PLACEHOLDER_ARTEMIS_CONTACT" or
      .metadata.labels.env != strenv(ENVIRONMENT) or
      .metadata.labels.fismaid != "PLACEHOLDER_ARTEMIS_FISMAID")
    ] | length) == 0
  ' "$rendered" >/dev/null

  ENVIRONMENT="$environment" ECR_REPOSITORY="$ecr_repository" OPERATOR_IMAGE_TAG="$operator_image_tag" BROKER_COMPACT="$broker_compact" INIT_IMAGE_TAG="$broker_init_image_tag" RUNTIME_IMAGE_TAG="$broker_runtime_image_tag" yq -e '
    select(.kind == "Deployment")
    | (.metadata.name == "activemq-artemis-controller-manager-v2")
      and (.spec.replicas == 2)
      and (.spec.template.spec.containers[0].args | contains(["--leader-elect"]))
      and (.spec.template.spec.containers[0].image == (strenv(ECR_REPOSITORY) + "/arkmq-operator:" + strenv(OPERATOR_IMAGE_TAG)))
      and ([.spec.template.spec.containers[0].env[] |
        select(.name == ("RELATED_IMAGE_ActiveMQ_Artemis_Broker_Init_" + strenv(BROKER_COMPACT)) and
          .value == (strenv(ECR_REPOSITORY) + "/activemq-artemis-broker-init:" + strenv(INIT_IMAGE_TAG)))] | length == 1)
      and ([.spec.template.spec.containers[0].env[] |
        select(.name == ("RELATED_IMAGE_ActiveMQ_Artemis_Broker_Kubernetes_" + strenv(BROKER_COMPACT)) and
          .value == (strenv(ECR_REPOSITORY) + "/activemq-artemis-broker-kubernetes:" + strenv(RUNTIME_IMAGE_TAG)))] | length == 1)
      and (.spec.template.spec.topologySpreadConstraints | length == 2)
      and (.spec.template.spec.topologySpreadConstraints[0].topologyKey == "kubernetes.io/hostname")
      and (.spec.template.spec.topologySpreadConstraints[0].whenUnsatisfiable == "ScheduleAnyway")
      and (.spec.template.spec.topologySpreadConstraints[1].topologyKey == "topology.kubernetes.io/zone")
      and (.spec.template.spec.topologySpreadConstraints[1].whenUnsatisfiable == "ScheduleAnyway")
      and (.spec.template.spec.tolerations | length == 1)
      and (.spec.template.spec.tolerations[0].key == "eid-platform/node-lifecycle")
      and (.spec.template.spec.tolerations[0].operator == "Equal")
      and (.spec.template.spec.tolerations[0].value == "ondemand")
      and (.spec.template.spec.tolerations[0].effect == "NoSchedule")
      and (.metadata.labels.app == "artemis")
      and (.metadata.labels.contact == "PLACEHOLDER_ARTEMIS_CONTACT")
      and (.metadata.labels.env == strenv(ENVIRONMENT))
      and (.metadata.labels.fismaid == "PLACEHOLDER_ARTEMIS_FISMAID")
      and (.spec.template.metadata.labels.app == "artemis")
      and (.spec.template.metadata.labels.contact == "PLACEHOLDER_ARTEMIS_CONTACT")
      and (.spec.template.metadata.labels.env == strenv(ENVIRONMENT))
      and (.spec.template.metadata.labels.fismaid == "PLACEHOLDER_ARTEMIS_FISMAID")
      and (.spec.selector.matchLabels["control-plane"] == "controller-manager")
      and (.spec.selector.matchLabels.name == "activemq-artemis-operator")
      and (.spec.selector.matchLabels | length == 2)
  ' "$rendered" >/dev/null

  yq -e '
    select(.kind == "PodDisruptionBudget")
    | (.metadata.name == "activemq-artemis-controller-manager-v2")
      and (.spec.minAvailable == 1)
      and (.spec.selector.matchLabels["control-plane"] == "controller-manager")
      and (.spec.selector.matchLabels.name == "activemq-artemis-operator")
      and (.spec.selector.matchLabels | length == 2)
  ' "$rendered" >/dev/null

  yq eval-all -e '
    [.] | ([.[] | select(.kind == "CustomResourceDefinition")] | length) > 0
  ' "$rendered" >/dev/null
  yq eval-all -e '
    [.] | ([.[] | select(
      .kind == "CustomResourceDefinition" and
      .metadata.annotations."argocd.argoproj.io/sync-options" != "Prune=false,Delete=false"
    )] | length) == 0
  ' "$rendered" >/dev/null

  yq -e '
    select(.kind == "ClusterRole" and .metadata.name == "activemq-artemis-operator-role")
    | ([.rules[]
        | select(
            (.apiGroups | contains(["broker.amq.io"])) and
            (.resources | contains(["activemqartemises"])) and
            (.verbs | contains(["list", "watch"]))
          )
      ] | length) == 1
      and ([.rules[]
        | select(
            (.apiGroups | contains([""])) and
            (.resources | contains(["configmaps"])) and
            (.verbs | contains(["list", "watch"]))
          )
      ] | length) == 1
  ' "$rendered" >/dev/null

  RELEASE_NAMESPACE=artemis-platform yq -e '
    select(.kind == "ClusterRoleBinding" and .metadata.name == "activemq-artemis-operator-rolebinding")
    | .roleRef.kind == "ClusterRole"
      and .roleRef.name == "activemq-artemis-operator-role"
      and ([.subjects[]
        | select(
            .kind == "ServiceAccount" and
            .name == "activemq-artemis-controller-manager" and
            .namespace == strenv(RELEASE_NAMESPACE)
          )
      ] | length) == 1
  ' "$rendered" >/dev/null
done

printf '%s\n' 'ArkMQ operator Kustomize tests passed'
