SHELL := /bin/sh

CLIENT_DIR ?= images/test-client
MAVEN ?= mvn
REPORT_DIR ?= reports
IMAGE ?= validation-client:local
BUILD_IMAGE ?= maven:3.9.16-eclipse-temurin-17
RUNTIME_IMAGE ?= eclipse-temurin:17-jre
BUILD_IMAGE_DIGEST ?=
RUNTIME_IMAGE_DIGEST ?=

.PHONY: help test package validate validate-static validate-scenarios validate-charts build-image

help:
	@printf '%s\n' \
		'test              Run the deterministic client unit tests' \
		'package           Build the client jar and runtime dependency directory' \
		'validate          Run repository, scenario, and chart/static checks' \
		'validate-static   Check owned implementation invariants' \
		'validate-scenarios Validate declarative EKS scenario definitions' \
		'validate-charts   Lint/render charts when charts are present' \
		'build-image       Build an immutable client image (digest args required)'

test:
	$(MAVEN) -B -ntp -f $(CLIENT_DIR)/pom.xml test

package:
	$(MAVEN) -B -ntp -f $(CLIENT_DIR)/pom.xml package

validate-static:
	./scripts/validate-static.sh --report $(REPORT_DIR)/static-validation.json

validate-scenarios:
	./scripts/validate-scenarios.sh --report $(REPORT_DIR)/scenario-validation.json

validate-charts:
	./scripts/validate-charts.sh --report $(REPORT_DIR)/chart-validation.json

validate: validate-static validate-scenarios validate-charts test

build-image:
	@test -n "$(BUILD_IMAGE_DIGEST)" || (printf '%s\n' 'BUILD_IMAGE_DIGEST is required' >&2; exit 2)
	@test -n "$(RUNTIME_IMAGE_DIGEST)" || (printf '%s\n' 'RUNTIME_IMAGE_DIGEST is required' >&2; exit 2)
	docker build \
		--build-arg BUILD_IMAGE=$(BUILD_IMAGE) \
		--build-arg BUILD_IMAGE_DIGEST=$(BUILD_IMAGE_DIGEST) \
		--build-arg RUNTIME_IMAGE=$(RUNTIME_IMAGE) \
		--build-arg RUNTIME_IMAGE_DIGEST=$(RUNTIME_IMAGE_DIGEST) \
		--tag $(IMAGE) $(CLIENT_DIR)
