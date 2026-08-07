SHELL := /bin/sh

REPORT_DIR ?= ../reports

.PHONY: help validate validate-scenarios validate-topology verify-applicationset test-verify-applicationset test-topology test-argocd-ecr-credentials validate-charts validate-operator-schema

help:
	@printf '%s\n' \
		'validate                 Run all GitOps and Helm checks' \
		'validate-scenarios       Validate EKS acceptance definitions' \
		'validate-topology        Validate broker-pair catalogs and local-cluster bootstraps' \
		'verify-applicationset    Verify live ApplicationSet reconciliation (requires CONTEXT, ARGOCD_NAMESPACE, ENVIRONMENT)' \
		'test-verify-applicationset Test ApplicationSet live verification failure detection' \
		'test-topology            Exercise topology regression cases' \
		'test-argocd-ecr-credentials Test the shared ECR credential refresh helper' \
		'validate-charts          Lint and render charts and overlays' \
		'validate-operator-schema Validate broker CRs against ArkMQ 2.2.0'

validate: validate-scenarios validate-topology test-verify-applicationset test-topology test-argocd-ecr-credentials validate-charts validate-operator-schema

validate-scenarios:
	./scripts/validate-scenarios.sh --report "$(REPORT_DIR)/scenario-validation.json"

validate-topology:
	./scripts/validate-topology.sh --report "$(REPORT_DIR)/topology-validation.json"

verify-applicationset:
	./scripts/verify-argocd-applicationset.sh --context "$(CONTEXT)" --argocd-namespace "$(ARGOCD_NAMESPACE)" --environment "$(ENVIRONMENT)"

test-verify-applicationset:
	./tests/argocd/test-verify-applicationset.sh

test-topology:
	./tests/topology/test.sh

test-argocd-ecr-credentials:
	./tests/argocd/test-ecr-credential-refresh.sh

validate-charts:
	./scripts/validate-charts.sh --report "$(REPORT_DIR)/chart-validation.json"

validate-operator-schema:
	./scripts/validate-operator-schema.sh
