SHELL := /bin/sh

REPORT_DIR ?= reports

.PHONY: help versions prepare-upgrade validate-release validate-toolchain release-gate test-upgrade-workflow test-chef-import test test-topology test-zookeeper-rollout-preflight test-diagnose-pod-startup test-argocd-ecr-credentials package validate validate-static validate-scenarios validate-topology validate-charts validate-zookeeper-kustomize validate-operator-kustomize validate-operator-schema validate-compose local-up local-down local-reset local-logs local-status local-smoke performance-local performance-deployed failure-deployed build-image

help:
	@printf '%s\n' \
		'Local development:' \
		'  local-up          Start the standalone local broker' \
		'  local-down        Stop the local broker and keep its volume' \
		'  local-reset       Stop the local broker and remove its volume' \
		'  local-logs        Follow local broker logs' \
		'  local-status      Show local broker status' \
		'  local-smoke       Run OpenWire and AMQP smoke tests locally' \
		'' \
		'GitOps and Helm:' \
		'  versions          Show centrally selected platform and application versions' \
		'  prepare-upgrade   Preview one platform/component upgrade (COMPONENT, VERSION, UPGRADE_ARGS)' \
		'  validate-release  Validate central versions and generated consumers' \
		'  validate-toolchain Validate exact Kustomize, Helm, and yq renderer versions' \
		'  release-gate      Run mandatory artifact-backed release validation' \
		'  test-upgrade-workflow Exercise Platform Release preview regressions' \
		'  test-chef-import  Exercise Chef ActiveMQ import and redaction regressions' \
		'  validate-topology Validate Workload Cell catalogs and rendered Argo composition' \
		'  test-topology     Exercise topology validation regression cases' \
		'  test-zookeeper-rollout-preflight Test the read-only ZooKeeper rollout gate' \
		'  test-diagnose-pod-startup Test pod startup failure classification and read-only collection' \
		'  test-argocd-ecr-credentials Test the shared ECR credential refresh helper' \
		'  validate-charts   Lint and render the Artemis Helm chart' \
		'  validate-zookeeper-kustomize Render and validate ZooKeeper overlays' \
		'  validate-operator-kustomize Render operator overlays from the approved upstream chart' \
		'  validate-scenarios Validate the EKS acceptance definitions' \
		'  validate-operator-schema Validate broker CRs against the selected ArkMQ release' \
		'' \
		'Performance and validation client:' \
		'  test              Run deterministic client unit tests' \
		'  package           Package the validation client' \
		'  performance-local Run a load profile against the local broker' \
		'  performance-deployed Run a load profile against PERF_URL' \
		'  failure-deployed Run a destructive acknowledged-message failover test' \
		'  build-image       Build the version-tagged validation client image' \
		'' \
		'Repository:' \
		'  validate          Run the complete validation suite' \
		'  validate-static   Check cross-area repository invariants' \
		'  validate-compose  Validate the local Compose configuration'

test:
	$(MAKE) -C performance test

package:
	$(MAKE) -C performance package

build-image:
	$(MAKE) -C performance build-image

performance-local:
	$(MAKE) -C performance run-local REPORT_DIR="$(abspath $(REPORT_DIR))/performance"

performance-deployed:
	$(MAKE) -C performance run-deployed REPORT_DIR="$(abspath $(REPORT_DIR))/performance"

failure-deployed:
	$(MAKE) -C performance failure-deployed REPORT_DIR="$(abspath $(REPORT_DIR))/failure"

local-up:
	$(MAKE) -C local up

local-down:
	$(MAKE) -C local down

local-reset:
	$(MAKE) -C local reset

local-logs:
	$(MAKE) -C local logs

local-status:
	$(MAKE) -C local status

local-smoke:
	$(MAKE) -C local smoke

validate-compose:
	$(MAKE) -C local validate REPORT_DIR="$(abspath $(REPORT_DIR))"

validate-scenarios:
	$(MAKE) -C gitops validate-scenarios REPORT_DIR="$(abspath $(REPORT_DIR))"

validate-topology:
	$(MAKE) -C gitops validate-topology REPORT_DIR="$(abspath $(REPORT_DIR))"

test-topology:
	$(MAKE) -C gitops test-topology

test-zookeeper-rollout-preflight:
	$(MAKE) -C gitops test-zookeeper-rollout-preflight

test-diagnose-pod-startup:
	$(MAKE) -C gitops test-diagnose-pod-startup

test-argocd-ecr-credentials:
	$(MAKE) -C gitops test-argocd-ecr-credentials

validate-charts:
	$(MAKE) -C gitops validate-charts REPORT_DIR="$(abspath $(REPORT_DIR))"

validate-zookeeper-kustomize:
	$(MAKE) -C gitops validate-zookeeper-kustomize

validate-operator-kustomize:
	$(MAKE) -C gitops validate-operator-kustomize ARKMQ_UPSTREAM_CHART="$(ARKMQ_UPSTREAM_CHART)"

validate-operator-schema:
	$(MAKE) -C gitops validate-operator-schema ARKMQ_UPSTREAM_CHART="$(ARKMQ_UPSTREAM_CHART)"

versions:
	$(MAKE) -C gitops versions

prepare-upgrade:
	$(MAKE) -C gitops prepare-upgrade COMPONENT="$(COMPONENT)" VERSION="$(VERSION)" UPGRADE_ARGS="$(UPGRADE_ARGS)"

validate-release:
	$(MAKE) -C gitops validate-release

validate-toolchain:
	$(MAKE) -C gitops validate-toolchain

release-gate:
	@test -f "$(ARKMQ_UPSTREAM_CHART)" || { printf '%s\n' 'ARKMQ_UPSTREAM_CHART must name the approved chart .tgz' >&2; exit 2; }
	$(MAKE) validate-toolchain
	ARTEMIS_RELEASE_GATE=true ARKMQ_UPSTREAM_CHART="$(ARKMQ_UPSTREAM_CHART)" REPORT_DIR="$(REPORT_DIR)" ./scripts/validate-repository.sh

test-upgrade-workflow:
	$(MAKE) -C gitops test-upgrade-workflow

test-chef-import:
	$(MAKE) -C gitops test-chef-import

validate-static:
	./scripts/validate-static.sh --report "$(REPORT_DIR)/static-validation.json"

validate:
	REPORT_DIR="$(REPORT_DIR)" ./scripts/validate-repository.sh
