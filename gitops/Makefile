SHELL := /bin/sh

REPORT_DIR ?= ../reports

.PHONY: help versions prepare-upgrade validate-release validate test-upgrade-workflow validate-scenarios validate-topology verify-applicationset diagnose-pod-startup test-diagnose-pod-startup test-verify-applicationset test-topology test-argocd-ecr-credentials validate-charts validate-zookeeper-kustomize validate-operator-kustomize validate-operator-schema

help:
	@printf '%s\n' \
		'versions                 Show centrally selected platform and application versions' \
		'prepare-upgrade          Preview one platform/component upgrade (COMPONENT, VERSION, UPGRADE_ARGS)' \
		'validate-release         Validate central versions and generated consumers' \
		'test-upgrade-workflow    Exercise Platform Release preview regressions' \
		'validate                 Run all GitOps and Helm checks' \
		'validate-scenarios       Validate EKS acceptance definitions' \
		'validate-topology        Validate Workload Cell catalogs and rendered cluster composition' \
		'verify-applicationset    Verify live ApplicationSet reconciliation (requires CONTEXT, ARGOCD_NAMESPACE, ENVIRONMENT)' \
		'diagnose-pod-startup     Classify one live pod startup failure (requires CONTEXT, NAMESPACE, POD)' \
		'test-diagnose-pod-startup Test pod startup failure classification and read-only collection' \
		'test-verify-applicationset Test ApplicationSet live verification failure detection' \
		'test-topology            Exercise topology regression cases' \
		'test-argocd-ecr-credentials Test the shared ECR credential refresh helper' \
		'validate-charts          Lint and render the Artemis Helm chart' \
		'validate-zookeeper-kustomize Render and validate ZooKeeper overlays' \
		'validate-operator-kustomize Render operator overlays (ARKMQ_UPSTREAM_CHART=/path/chart.tgz)' \
		'validate-operator-schema Validate broker CRs against the selected ArkMQ release'

validate: validate-release test-upgrade-workflow validate-scenarios validate-topology test-diagnose-pod-startup test-verify-applicationset test-topology test-argocd-ecr-credentials validate-charts validate-zookeeper-kustomize validate-operator-kustomize validate-operator-schema

versions:
	@yq -r '"Kubernetes " + .platform.kubernetesVersion, "ArkMQ operator " + .operator.version + " (image OS " + .operator.image.baseOs.id + " " + .operator.image.baseOs.versionId + ")", "Artemis broker " + .broker.version + " (runtime image OS " + .broker.images.runtime.baseOs.id + " " + .broker.images.runtime.baseOs.versionId + ", init image OS " + .broker.images.init.baseOs.id + " " + .broker.images.init.baseOs.versionId + ")", "ZooKeeper " + .zookeeper.version + " (image OS " + .zookeeper.image.baseOs.id + " " + .zookeeper.image.baseOs.versionId + ")"' releases/current.yaml

prepare-upgrade:
	./scripts/prepare-upgrade.sh --component "$(COMPONENT)" --version "$(VERSION)" $(UPGRADE_ARGS)

validate-release:
	./scripts/validate-release.sh

test-upgrade-workflow:
	./tests/releases/test-prepare-upgrade.sh

validate-scenarios:
	./scripts/validate-scenarios.sh --report "$(REPORT_DIR)/scenario-validation.json"

validate-topology:
	./scripts/validate-topology.sh --report "$(REPORT_DIR)/topology-validation.json"

verify-applicationset:
	./scripts/verify-argocd-applicationset.sh --context "$(CONTEXT)" --argocd-namespace "$(ARGOCD_NAMESPACE)" --environment "$(ENVIRONMENT)"

diagnose-pod-startup:
	./scripts/diagnose-pod-startup.sh --context "$(CONTEXT)" --namespace "$(NAMESPACE)" --pod "$(POD)"

test-diagnose-pod-startup:
	./tests/incidents/test-diagnose-pod-startup.sh

test-verify-applicationset:
	./tests/argocd/test-verify-applicationset.sh

test-topology:
	./tests/topology/test.sh

test-argocd-ecr-credentials:
	./tests/argocd/test-ecr-credential-refresh.sh

validate-charts:
	./scripts/validate-charts.sh --report "$(REPORT_DIR)/chart-validation.json"

validate-zookeeper-kustomize:
	./kustomize/zookeeper/tests/test.sh

validate-operator-kustomize:
	ARKMQ_UPSTREAM_CHART="$(ARKMQ_UPSTREAM_CHART)" ./kustomize/arkmq-operator/tests/test.sh

validate-operator-schema:
	ARKMQ_UPSTREAM_CHART="$(ARKMQ_UPSTREAM_CHART)" ./scripts/validate-operator-schema.sh
