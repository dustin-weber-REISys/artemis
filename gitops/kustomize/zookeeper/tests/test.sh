#!/usr/bin/env bash
set -euo pipefail

zookeeper_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
gitops_dir=$(CDPATH= cd -- "$zookeeper_dir/../.." && pwd)
release_file="$gitops_dir/releases/current.yaml"
applicationset="$gitops_dir/argocd/bootstrap/base/artemis-workloads-applicationset.yaml"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zookeeper-kustomize-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
schema_mode=${ARTEMIS_SCHEMA_MODE:-offline}
schema_args=(--mode "$schema_mode" --quiet-offline)
if [[ -n "${ARTEMIS_KUBERNETES_VERSION:-}" ]]; then
  schema_args+=(--kubernetes-version "$ARTEMIS_KUBERNETES_VERSION")
fi

for command_name in kubectl rg yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 2
  }
done

zookeeper_version=$(yq -er '.zookeeper.version' "$release_file")
zookeeper_image_tag=$(yq -er '.zookeeper.image.tag' "$release_file")
connect_template=$(yq -er \
  '.spec.template.spec.source.helm.parameters[] | select(.name == "zookeeper.connectString") | .value' \
  "$applicationset")
expected_connect_template='{{.environment}}-shared-zookeeper-zookeeper-client.{{.platformNamespace}}.svc.cluster.local:2181'
[[ "$connect_template" == "$expected_connect_template" ]] || {
  printf 'ApplicationSet ZooKeeper endpoint changed: expected %s, got %s\n' \
    "$expected_connect_template" "$connect_template" >&2
  exit 1
}

for environment in test nonprod prod; do
  overlay="$zookeeper_dir/overlays/$environment"
  rendered="$work_dir/$environment.yaml"
  rendered_again="$work_dir/$environment-again.yaml"
  sed '/^server\.[0-9][0-9]*=/d' "$zookeeper_dir/base/zoo.cfg" >"$work_dir/base-common.cfg"
  sed '/^server\.[0-9][0-9]*=/d' "$overlay/zoo.cfg" >"$work_dir/$environment-common.cfg"
  cmp -s "$work_dir/base-common.cfg" "$work_dir/$environment-common.cfg" || {
    printf 'ZooKeeper %s overlay configuration drifted from the base\n' "$environment" >&2
    diff -u "$work_dir/base-common.cfg" "$work_dir/$environment-common.cfg" >&2 || true
    exit 1
  }
  kubectl kustomize "$overlay" > "$rendered"
  kubectl kustomize "$overlay" > "$rendered_again"
  cmp -s "$rendered" "$rendered_again" || {
    printf 'ZooKeeper %s overlay is not deterministic\n' "$environment" >&2
    exit 1
  }

  expected_ecr=PLACEHOLDER_NONPROD_ECR_REPOSITORY
  expected_storage=PLACEHOLDER_NONPROD_GP3_STORAGE_CLASS
  expected_memory=2Gi
  expected_heap='-Xms512m -Xmx1Gi'
  expected_zone_domains=3
  expected_zone_schedule=DoNotSchedule
  expected_size=20Gi
  if [[ "$environment" == test ]]; then
    expected_storage=PLACEHOLDER_TEST_GP3_STORAGE_CLASS
    expected_memory=1Gi
    expected_heap='-Xms256m -Xmx512m'
    expected_zone_schedule=ScheduleAnyway
    expected_size=10Gi
  elif [[ "$environment" == prod ]]; then
    expected_ecr=PLACEHOLDER_PROD_ECR_REPOSITORY
    expected_storage=PLACEHOLDER_PROD_GP3_STORAGE_CLASS
  fi

  ENVIRONMENT="$environment" yq eval-all -e '
    [.] | ([.[] | select(
      .metadata.labels.app != "artemis" or
      .metadata.labels.contact != "PLACEHOLDER_ARTEMIS_CONTACT" or
      .metadata.labels.env != strenv(ENVIRONMENT) or
      .metadata.labels.fismaid != "PLACEHOLDER_ARTEMIS_FISMAID")
    ] | length) == 0
  ' "$rendered" >/dev/null

  ENVIRONMENT="$environment" ECR="$expected_ecr" STORAGE="$expected_storage" MEMORY="$expected_memory" HEAP="$expected_heap" DOMAINS="$expected_zone_domains" ZONE_SCHEDULE="$expected_zone_schedule" SIZE="$expected_size" VERSION="$zookeeper_version" IMAGE_TAG="$zookeeper_image_tag" yq -e '
    select(.kind == "StatefulSet") |
      .metadata.name == (strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper") and
      .spec.serviceName == (strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper-headless") and
      .spec.replicas == 3 and
      .spec.minReadySeconds == 30 and
      .spec.persistentVolumeClaimRetentionPolicy.whenDeleted == "Retain" and
      .spec.persistentVolumeClaimRetentionPolicy.whenScaled == "Retain" and
      .spec.selector.matchLabels."app.kubernetes.io/instance" == (strenv(ENVIRONMENT) + "-shared-zookeeper") and
      .spec.template.metadata.labels."app.kubernetes.io/instance" == (strenv(ENVIRONMENT) + "-shared-zookeeper") and
      .spec.template.metadata.labels."app.kubernetes.io/version" == strenv(VERSION) and
      (.spec.template.spec.topologySpreadConstraints | length) == 1 and
      .spec.template.spec.topologySpreadConstraints[0].whenUnsatisfiable == strenv(ZONE_SCHEDULE) and
      (
        (strenv(ZONE_SCHEDULE) == "DoNotSchedule" and
          .spec.template.spec.topologySpreadConstraints[0].minDomains == (strenv(DOMAINS) | tonumber)) or
        (strenv(ZONE_SCHEDULE) == "ScheduleAnyway" and
          (.spec.template.spec.topologySpreadConstraints[0] | has("minDomains") | not))
      ) and
      .spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey == "kubernetes.io/hostname" and
      .spec.template.spec.initContainers[0].image == (strenv(ECR) + "/zookeeper:" + strenv(IMAGE_TAG)) and
      .spec.template.spec.initContainers[0].resources.requests.memory == strenv(MEMORY) and
      .spec.template.spec.containers[0].image == (strenv(ECR) + "/zookeeper:" + strenv(IMAGE_TAG)) and
      .spec.template.spec.containers[0].resources.requests.memory == strenv(MEMORY) and
      (.spec.template.spec.containers[0].env[] | select(.name == "JVMFLAGS").value) == strenv(HEAP) and
      (.spec.volumeClaimTemplates[0].metadata | keys | sort | join(",")) == "labels,name" and
      (.spec.volumeClaimTemplates[0].metadata.labels | keys | sort | join(",")) == "app,app.kubernetes.io/instance,app.kubernetes.io/managed-by,app.kubernetes.io/name,app.kubernetes.io/version,contact,env,fismaid,helm.sh/chart" and
      .spec.volumeClaimTemplates[0].metadata.name == "data" and
      .spec.volumeClaimTemplates[0].metadata.labels."helm.sh/chart" == "zookeeper-0.1.0" and
      .spec.volumeClaimTemplates[0].metadata.labels."app.kubernetes.io/name" == "zookeeper" and
      .spec.volumeClaimTemplates[0].metadata.labels."app.kubernetes.io/instance" == (strenv(ENVIRONMENT) + "-shared-zookeeper") and
      .spec.volumeClaimTemplates[0].metadata.labels."app.kubernetes.io/version" == "3.9.5" and
      .spec.volumeClaimTemplates[0].metadata.labels."app.kubernetes.io/managed-by" == "Helm" and
      .spec.volumeClaimTemplates[0].metadata.labels.app == "artemis" and
      .spec.volumeClaimTemplates[0].metadata.labels.contact == "PLACEHOLDER_ARTEMIS_CONTACT" and
      .spec.volumeClaimTemplates[0].metadata.labels.env == strenv(ENVIRONMENT) and
      .spec.volumeClaimTemplates[0].metadata.labels.fismaid == "PLACEHOLDER_ARTEMIS_FISMAID" and
      .spec.volumeClaimTemplates[0].spec.storageClassName == strenv(STORAGE) and
      .spec.volumeClaimTemplates[0].spec.resources.requests.storage == strenv(SIZE)
  ' "$rendered" >/dev/null

  yq -e '
    select(.kind == "StatefulSet") |
      .spec.template.spec.initContainers[0].name == "wait-for-peer-dns" and
      (.spec.template.spec.initContainers[0].args[0] | contains("statefulset=\"${HOSTNAME%-*}\"")) and
      (.spec.template.spec.initContainers[0].args[0] | contains("/generated-conf/zoo.cfg") | not) and
      (.spec.template.spec.initContainers[0].args[0] | contains("for ordinal in 0 1 2")) and
      (.spec.template.spec.initContainers[0].args[0] | contains("until getent hosts \"$peer\"")) and
      (.spec.template.spec.initContainers[0].volumeMounts // [] | length) == 0 and
      (.spec.template.spec.containers[0].args[0] | contains("/data/data/myid")) and
      .spec.template.spec.containers[0].readinessProbe.initialDelaySeconds == 30 and
      .spec.template.spec.containers[0].livenessProbe.initialDelaySeconds == 30 and
      (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "config-source").subPath) == "zoo.cfg" and
      ([.spec.template.spec.volumes[] | select(.name == "config")] | length) == 0
  ' "$rendered" >/dev/null

  ENVIRONMENT="$environment" yq -e '
    select(.kind == "PrometheusRule") |
      .spec.groups[0].name == ("zookeeper-" + strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper")
  ' "$rendered" >/dev/null

  ENVIRONMENT="$environment" yq -e '
    select(.kind == "ConfigMap") |
      (.metadata.name | test("-shared-zookeeper-zookeeper-config-[a-z0-9]+$")) and
      (.data."zoo.cfg" | contains("standaloneEnabled=false")) and
      (.data."zoo.cfg" | contains("metricsProvider.httpPort=7000")) and
      (.data."zoo.cfg" | contains("server.1=" + strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper-0." + strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper-headless.artemis-platform.svc.cluster.local:2888:3888")) and
      (.data."zoo.cfg" | contains("server.2=" + strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper-1." + strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper-headless.artemis-platform.svc.cluster.local:2888:3888")) and
      (.data."zoo.cfg" | contains("server.3=" + strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper-2." + strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper-headless.artemis-platform.svc.cluster.local:2888:3888"))
  ' "$rendered" >/dev/null

  yq -e '
    select(.kind == "NetworkPolicy") |
      .spec.podSelector.matchLabels."app.kubernetes.io/instance" != null and
      .spec.ingress[0].from[0].podSelector.matchLabels."app.kubernetes.io/instance" != null and
      .spec.ingress[1].from[0].podSelector.matchExpressions[0].key == "ActiveMQArtemis" and
      .spec.ingress[1].from[0].podSelector.matchLabels."app.kubernetes.io/instance" == null and
      .spec.ingress[2].from[0].podSelector.matchLabels."app.kubernetes.io/instance" == null and
      .spec.egress[1].to[0].podSelector.matchLabels."app.kubernetes.io/instance" == null
  ' "$rendered" >/dev/null

  for kind in ServiceAccount StatefulSet NetworkPolicy PodDisruptionBudget ServiceMonitor PrometheusRule; do
    KIND="$kind" yq eval-all -e '[.] | [.[] | select(.kind == strenv(KIND))] | length >= 1' "$rendered" >/dev/null
  done
  yq eval-all -e '[.] | [.[] | select(.kind == "Service")] | length == 2' "$rendered" >/dev/null
  ENVIRONMENT="$environment" yq -e '
    select(.kind == "Service" and .metadata.labels."zookeeper.example.io/service" == "client") |
      .metadata.name == (strenv(ENVIRONMENT) + "-shared-zookeeper-zookeeper-client") and
      .metadata.namespace == "artemis-platform" and
      .spec.ports[0].name == "client" and
      .spec.ports[0].port == 2181
  ' "$rendered" >/dev/null

  if [[ "$environment" == test ]]; then
    yq -e '
      select(.kind == "StatefulSet") |
        (.spec.template.spec.tolerations | length) == 1 and
        .spec.template.spec.tolerations[0].key == "eid-platform/node-lifecycle" and
        .spec.template.spec.tolerations[0].operator == "Equal" and
        .spec.template.spec.tolerations[0].value == "ondemand" and
        .spec.template.spec.tolerations[0].effect == "NoSchedule"
    ' "$rendered" >/dev/null
  else
    yq -e 'select(.kind == "StatefulSet") | (.spec.template.spec.tolerations // []) | length == 0' "$rendered" >/dev/null
  fi

  "$gitops_dir/scripts/validate-rendered-schema.sh" "${schema_args[@]}" "$rendered" >/dev/null
done

if [[ "$schema_mode" == offline ]]; then
  printf '%s\n' 'ZooKeeper Kustomize tests passed (Kubernetes schema: NOT_RUN/offline)'
else
  printf '%s\n' 'ZooKeeper Kustomize tests passed (Kubernetes schema: PASS/network)'
fi
