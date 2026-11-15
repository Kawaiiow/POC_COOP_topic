.DEFAULT_GOAL := help

INVENTORY ?= inventory.ini
PLAYBOOK ?= site.yml

.PHONY: help ping syntax check apply clean

help:
	@echo "Available targets:"
	@echo "  make ping     - Test Ansible connectivity to all hosts"
	@echo "  make syntax   - Validate playbook syntax"
	@echo "  make check    - Perform a dry-run (check mode) with diffs"
	@echo "  make apply    - Execute the full initial setup playbook"
	@echo "  make clean    - Remove local cache and temporary retry files"

ping:
	ansible ubuntu_fleet -i $(INVENTORY) -m ping

syntax:
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --syntax-check

check:
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --check --diff

apply:
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --diff

clean:
	find . -type f -name "*.retry" -delete
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -delete
