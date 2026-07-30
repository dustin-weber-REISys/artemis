SHELL := /bin/sh

REPORT_DIR ?= ../reports

.PHONY: help validate validate-scenarios validate-topology test-topology validate-charts validate-operator-schema

help:
	@printf '%s\n' \
		'validate                 Run all GitOps and Helm checks' \
		'validate-scenarios       Validate EKS acceptance definitions' \
		'validate-topology        Validate broker-pair catalogs and local-cluster bootstraps' \
		'test-topology            Exercise topology regression cases' \
		'validate-charts          Lint and render charts and overlays' \
		'validate-operator-schema Validate broker CRs against ArkMQ 2.2.0'

validate: validate-scenarios validate-topology test-topology validate-charts validate-operator-schema

validate-scenarios:
	./scripts/validate-scenarios.sh --report "$(REPORT_DIR)/scenario-validation.json"

validate-topology:
	./scripts/validate-topology.sh --report "$(REPORT_DIR)/topology-validation.json"

test-topology:
	./tests/topology/test.sh

validate-charts:
	./scripts/validate-charts.sh --report "$(REPORT_DIR)/chart-validation.json"

validate-operator-schema:
	./scripts/validate-operator-schema.sh
