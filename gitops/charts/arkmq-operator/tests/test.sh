#!/usr/bin/env bash
set -euo pipefail

chart_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/arkmq-operator-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

cp -R "$chart_dir/." "$work_dir/chart"
helm dependency build "$work_dir/chart" >/dev/null

if helm template invalid "$work_dir/chart" \
  --set-string 'global.requiredLabels.contact=ELISSkynet@uscis.dhs.gov' \
  >/dev/null 2>&1; then
  printf '%s\n' 'expected an email address used as a label value to fail' >&2
  exit 1
fi

for environment in test nonprod prod; do
  rendered="$work_dir/$environment.yaml"
  ecr_repository=PLACEHOLDER_NONPROD_ECR_REPOSITORY
  if [[ "$environment" == prod ]]; then
    ecr_repository=PLACEHOLDER_PROD_ECR_REPOSITORY
  fi
  helm template "$environment-arkmq-operator" "$work_dir/chart" \
    --namespace example-platform \
    --set-string "global.requiredLabels.env=$environment" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.image.repository=$ecr_repository/arkmq-operator" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.image.tag=2.2.0" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerInitRepository=$ecr_repository/activemq-artemis-broker-init" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerInit2530.tag=2.53.0" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerKubernetesRepository=$ecr_repository/activemq-artemis-broker-kubernetes" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerKubernetes2530.tag=2.53.0" \
    > "$rendered"

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

  ENVIRONMENT="$environment" ECR_REPOSITORY="$ecr_repository" yq -e '
    select(.kind == "Deployment")
    | (.metadata.name == "activemq-artemis-controller-manager-v2")
      and (.spec.replicas == 2)
      and (.spec.template.spec.containers[0].args | contains(["--leader-elect"]))
      and (.spec.template.spec.containers[0].image == (strenv(ECR_REPOSITORY) + "/arkmq-operator:2.2.0"))
      and ([.spec.template.spec.containers[0].env[] |
        select(.name == "RELATED_IMAGE_ActiveMQ_Artemis_Broker_Init_2530" and
          .value == (strenv(ECR_REPOSITORY) + "/activemq-artemis-broker-init:2.53.0"))] | length == 1)
      and ([.spec.template.spec.containers[0].env[] |
        select(.name == "RELATED_IMAGE_ActiveMQ_Artemis_Broker_Kubernetes_2530" and
          .value == (strenv(ECR_REPOSITORY) + "/activemq-artemis-broker-kubernetes:2.53.0"))] | length == 1)
      and (.spec.template.spec.topologySpreadConstraints | length == 2)
      and (.spec.template.spec.topologySpreadConstraints[0].maxSkew == 1)
      and (.spec.template.spec.topologySpreadConstraints[0].topologyKey == "kubernetes.io/hostname")
      and (.spec.template.spec.topologySpreadConstraints[0].whenUnsatisfiable == "ScheduleAnyway")
      and (.spec.template.spec.topologySpreadConstraints[1].maxSkew == 1)
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

  ENVIRONMENT="$environment" yq -e '
    select(.kind == "PodDisruptionBudget")
    | (.metadata.name == "activemq-artemis-controller-manager-v2")
      and (.spec.minAvailable == 1)
      and (.spec.selector.matchLabels["control-plane"] == "controller-manager")
      and (.spec.selector.matchLabels.name == "activemq-artemis-operator")
      and (.spec.selector.matchLabels.app == null)
      and (.spec.selector.matchLabels.contact == null)
      and (.spec.selector.matchLabels.env == null)
      and (.spec.selector.matchLabels.fismaid == null)
      and (.spec.selector.matchLabels["app.kubernetes.io/name"] == null)
      and (.spec.selector.matchLabels["app.kubernetes.io/instance"] == null)
      and (.spec.selector.matchLabels | length == 2)
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

  RELEASE_NAMESPACE=example-platform yq -e '
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

printf '%s\n' 'ArkMQ operator wrapper tests passed'
