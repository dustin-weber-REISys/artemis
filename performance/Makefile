SHELL := /bin/sh

CLIENT_DIR ?= client
MAVEN ?= mvn
IMAGE ?= artemis-validation-client:local
BUILD_IMAGE ?= maven:3.9.16-eclipse-temurin-17
RUNTIME_IMAGE ?= eclipse-temurin:17-jre
PROFILE ?= burst
REPORT_DIR ?= ../reports/performance

.PHONY: help test package build-local-image build-image run-local run-deployed run-tunneled failure-deployed failure-tunneled

help:
	@printf '%s\n' \
		'test              Run validation-client unit tests' \
		'package           Package the validation client and dependencies' \
		'build-local-image Build the development client image' \
		'build-image       Build the version-tagged promotion image' \
		'run-local         Run PROFILE against the local Compose broker' \
		'run-deployed      Run PROFILE against PERF_URL' \
		'run-tunneled      Run PROFILE through supervised two-pod kubectl tunnels' \
		'failure-deployed  Run the destructive acknowledged-message failover test' \
		'failure-tunneled  Run failover test through supervised two-pod tunnels'

test:
	$(MAVEN) -B -ntp -f $(CLIENT_DIR)/pom.xml test
	./test-kubectl-tunnel.sh
	./test-profile-script.sh
	./test-failure-script.sh

package:
	$(MAVEN) -B -ntp -f $(CLIENT_DIR)/pom.xml package

build-local-image:
	IMAGE="$(IMAGE)" MAVEN="$(MAVEN)" ./build-local-image.sh

build-image:
	docker build \
		--build-arg BUILD_IMAGE="$(BUILD_IMAGE)" \
		--build-arg RUNTIME_IMAGE="$(RUNTIME_IMAGE)" \
		-t "$(IMAGE)" "$(CLIENT_DIR)"

run-local: build-local-image
	IMAGE="$(IMAGE)" ./run-profile.sh --target local --profile "$(PROFILE)" --report-dir "$(REPORT_DIR)"

run-deployed: build-local-image
	IMAGE="$(IMAGE)" ./run-profile.sh --target deployed --profile "$(PROFILE)" --report-dir "$(REPORT_DIR)"

run-tunneled: build-local-image
	IMAGE="$(IMAGE)" ./run-profile.sh \
		--target tunneled \
		--context "$(CONTEXT)" \
		--cluster "$(CLUSTER)" \
		--namespace "$(NAMESPACE)" \
		--profile "$(PROFILE)" \
		--report-dir "$(REPORT_DIR)" \
		$(TUNNEL_ARGS)

failure-deployed: build-local-image
	IMAGE="$(IMAGE)" ./run-failure-test.sh \
		--context "$(CONTEXT)" \
		--cluster "$(CLUSTER)" \
		--namespace "$(NAMESPACE)" \
		--profile "$(PROFILE)" \
		--report-dir "$(REPORT_DIR)" \
		$(FAILURE_ARGS)

failure-tunneled: build-local-image
	IMAGE="$(IMAGE)" ./run-failure-test.sh \
		--context "$(CONTEXT)" \
		--cluster "$(CLUSTER)" \
		--namespace "$(NAMESPACE)" \
		--profile "$(PROFILE)" \
		--report-dir "$(REPORT_DIR)" \
		--tunnel \
		$(FAILURE_ARGS)
