SHELL := /bin/sh

COMPOSE ?= docker compose
COMPOSE_FILE ?= compose.yaml
ENV_FILE ?= .env.example
COMPOSE_PROJECT_NAME ?= artemis
REPORT_DIR ?= ../reports

COMPOSE_ARGS = --project-name $(COMPOSE_PROJECT_NAME) --env-file $(ENV_FILE) -f $(COMPOSE_FILE)

.PHONY: help up down reset logs status smoke validate

help:
	@printf '%s\n' \
		'up       Start the standalone broker and wait for readiness' \
		'down     Stop the broker and preserve its named volume' \
		'reset    Stop the broker and remove its named volume' \
		'logs     Follow broker logs' \
		'status   Show Compose service status' \
		'smoke    Run OpenWire and AMQP smoke tests' \
		'validate Validate the Compose configuration'

up:
	$(COMPOSE) $(COMPOSE_ARGS) up -d --wait broker

down:
	$(COMPOSE) $(COMPOSE_ARGS) down --remove-orphans

reset:
	$(COMPOSE) $(COMPOSE_ARGS) down --remove-orphans --volumes

logs:
	$(COMPOSE) $(COMPOSE_ARGS) logs --follow --tail=100 broker

status:
	$(COMPOSE) $(COMPOSE_ARGS) ps

smoke:
	$(COMPOSE) $(COMPOSE_ARGS) --profile smoke run --rm --build validation-smoke

validate:
	./scripts/validate-compose.sh --report "$(REPORT_DIR)/compose-validation.json"
