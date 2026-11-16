# ==============================================================================
# Makefile: AIOps Observability & Incident Management Platform
# ==============================================================================

.PHONY: help up-obs down-obs logs-obs status-obs test-obs deploy-vm-shippers

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Observability Stack Targets:"
	@echo "  up-obs              Start VictoriaMetrics, VictoriaLogs, Grafana & Exporter"
	@echo "  down-obs            Stop Observability containers"
	@echo "  logs-obs            Tail logs of Observability services"
	@echo "  status-obs          Show status and health of Observability services"
	@echo "  test-obs            Run end-to-end verification of metrics & logs ingestion"
	@echo ""
	@echo "VM Telemetry Deployment:"
	@echo "  deploy-vm-shippers  Run Ansible to deploy Promtail & Node Exporter on VMs"

up-obs:
	docker compose up -d victoriametrics victorialogs grafana opnsense-exporter

down-obs:
	docker compose down

logs-obs:
	docker compose logs -f --tail=100

status-obs:
	docker compose ps

test-obs:
	@chmod +x scripts/verify_observability.sh 2>/dev/null || true
	./scripts/verify_observability.sh

deploy-vm-shippers:
	cd ansible && ansible-playbook -i inventory.ini site.yml --tags "telemetry,node_exporter,promtail"
