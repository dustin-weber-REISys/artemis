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
    --values "$chart_dir/../../operator-values.yaml" \
    --set-string "global.requiredLabels.env=$environment" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.image.repository=$ecr_repository/arkmq-operator" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerInitRepository=$ecr_repository/activemq-artemis-broker-init" \
    --set-string "arkmq-org-broker-operator.controllerManager.manager.relatedImages.activemqArtemisBrokerKubernetesRepository=$ecr_repository/activemq-artemis-broker-kubernetes" \
    > "$rendered"

  ENVIRONMENT="$environment" yq -e '
    select(.kind == "Deployment")
    | (.spec.replicas == 2)
      and (.spec.template.spec.containers[0].args | contains(["--leader-elect"]))
      and (.spec.template.spec.topologySpreadConstraints | length == 2)
      and (.spec.template.spec.topologySpreadConstraints[0].maxSkew == 1)
      and (.spec.template.spec.topologySpreadConstraints[0].topologyKey == "kubernetes.io/hostname")
      and (.spec.template.spec.topologySpreadConstraints[0].whenUnsatisfiable == "ScheduleAnyway")
      and (.spec.template.spec.topologySpreadConstraints[1].maxSkew == 1)
      and (.spec.template.spec.topologySpreadConstraints[1].topologyKey == "topology.kubernetes.io/zone")
      and (.spec.template.spec.topologySpreadConstraints[1].whenUnsatisfiable == "ScheduleAnyway")
      and (.metadata.labels.app == "artemis")
      and (.metadata.labels.contact == "PLACEHOLDER_ARTEMIS_CONTACT")
      and (.metadata.labels.env == strenv(ENVIRONMENT))
      and (.metadata.labels.fismaid == "PLACEHOLDER_ARTEMIS_FISMAID")
      and (.spec.template.metadata.labels.app == "artemis")
      and (.spec.template.metadata.labels.contact == "PLACEHOLDER_ARTEMIS_CONTACT")
      and (.spec.template.metadata.labels.env == strenv(ENVIRONMENT))
      and (.spec.template.metadata.labels.fismaid == "PLACEHOLDER_ARTEMIS_FISMAID")
  ' "$rendered" >/dev/null

  ENVIRONMENT="$environment" yq -e '
    select(.kind == "PodDisruptionBudget")
    | (.metadata.name == "activemq-artemis-controller-manager")
      and (.spec.minAvailable == 1)
      and (.spec.selector.matchLabels["control-plane"] == "controller-manager")
      and (.spec.selector.matchLabels.name == "activemq-artemis-operator")
      and (.spec.selector.matchLabels.app == "artemis")
      and (.spec.selector.matchLabels.contact == "PLACEHOLDER_ARTEMIS_CONTACT")
      and (.spec.selector.matchLabels.env == strenv(ENVIRONMENT))
      and (.spec.selector.matchLabels.fismaid == "PLACEHOLDER_ARTEMIS_FISMAID")
  ' "$rendered" >/dev/null
done

printf '%s\n' 'ArkMQ operator wrapper tests passed'
