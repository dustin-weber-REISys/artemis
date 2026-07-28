SHELL := /bin/sh

CLIENT_DIR ?= images/test-client
MAVEN ?= mvn
REPORT_DIR ?= reports
COMPOSE ?= docker compose
COMPOSE_FILE ?= compose.yaml
IMAGE ?= validation-client:local
BUILD_IMAGE ?= maven:3.9.16-eclipse-temurin-17
RUNTIME_IMAGE ?= eclipse-temurin:17-jre
BUILD_IMAGE_DIGEST ?=
RUNTIME_IMAGE_DIGEST ?=

.PHONY: help test test-topology package validate validate-static validate-scenarios validate-topology validate-charts validate-operator-schema validate-compose local-up local-down local-reset local-logs local-status local-smoke build-image

help:
	@printf '%s\n' \
		'test              Run the deterministic client unit tests' \
		'test-topology     Exercise topology validation regression cases' \
		'package           Build the client jar and runtime dependency directory' \
		'validate          Run the complete repository validation suite' \
		'validate-static   Check owned implementation invariants' \
		'validate-scenarios Validate declarative EKS scenario definitions' \
		'validate-topology Validate the generated 2/4/4 workload topology' \
		'validate-charts   Lint/render charts when charts are present' \
		'validate-operator-schema Validate broker CRs against ArkMQ 2.2.0' \
		'validate-compose  Validate the local Docker Compose configuration' \
		'local-up          Start the local standalone broker and wait for readiness' \
		'local-down        Stop the local broker and keep its named volume' \
		'local-reset       Stop the local broker and remove its named volume' \
		'local-logs        Follow local broker logs' \
		'local-status      Show local Compose service status' \
		'local-smoke       Run OpenWire and AMQP smoke tests in Compose' \
		'build-image       Build an immutable client image (digest args required)'

test:
	$(MAVEN) -B -ntp -f $(CLIENT_DIR)/pom.xml test

test-topology:
	./tests/topology/test.sh

package:
	$(MAVEN) -B -ntp -f $(CLIENT_DIR)/pom.xml package

validate-static:
	./scripts/validate-static.sh --report "$(REPORT_DIR)/static-validation.json"

validate-scenarios:
	./scripts/validate-scenarios.sh --report "$(REPORT_DIR)/scenario-validation.json"

validate-topology:
	./scripts/validate-topology.sh --report "$(REPORT_DIR)/topology-validation.json"

validate-charts:
	./scripts/validate-charts.sh --report "$(REPORT_DIR)/chart-validation.json"

validate-operator-schema:
	./scripts/validate-operator-schema.sh

validate-compose:
	./scripts/validate-compose.sh --report "$(REPORT_DIR)/compose-validation.json"

validate:
	CLIENT_DIR="$(CLIENT_DIR)" MAVEN="$(MAVEN)" REPORT_DIR="$(REPORT_DIR)" \
		./scripts/validate-repository.sh

local-up:
	$(COMPOSE) -f $(COMPOSE_FILE) up -d --wait broker

local-down:
	$(COMPOSE) -f $(COMPOSE_FILE) down --remove-orphans

local-reset:
	$(COMPOSE) -f $(COMPOSE_FILE) down --remove-orphans --volumes

local-logs:
	$(COMPOSE) -f $(COMPOSE_FILE) logs --follow --tail=100 broker

local-status:
	$(COMPOSE) -f $(COMPOSE_FILE) ps

local-smoke:
	$(COMPOSE) -f $(COMPOSE_FILE) --profile smoke run --rm --build validation-smoke

build-image:
	@test -n "$(BUILD_IMAGE_DIGEST)" || (printf '%s\n' 'BUILD_IMAGE_DIGEST is required' >&2; exit 2)
	@test -n "$(RUNTIME_IMAGE_DIGEST)" || (printf '%s\n' 'RUNTIME_IMAGE_DIGEST is required' >&2; exit 2)
	docker build \
		--build-arg BUILD_IMAGE=$(BUILD_IMAGE) \
		--build-arg BUILD_IMAGE_DIGEST=$(BUILD_IMAGE_DIGEST) \
		--build-arg RUNTIME_IMAGE=$(RUNTIME_IMAGE) \
		--build-arg RUNTIME_IMAGE_DIGEST=$(RUNTIME_IMAGE_DIGEST) \
		--tag $(IMAGE) $(CLIENT_DIR)
