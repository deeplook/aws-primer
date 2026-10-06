SPIKE ?= spike-1
SPIKE_DIR := src/$(SPIKE)
NODE ?= node
ARCHIFY_CLI ?= $(firstword $(wildcard $(HOME)/.agents/skills/archify/bin/archify.mjs $(HOME)/.codex/skills/archify/bin/archify.mjs $(HOME)/.claude/skills/archify/bin/archify.mjs))

SPIKE_TARGETS := tools local-up local-down local-clean local-logs local-log-tail package terraform-init \
	terraform-fmt terraform-fmt-check python-check shell-check validate check-all plan apply \
	send-message verify destroy e2e iam-probe aws-plan aws-apply aws-send-message aws-send-event aws-verify \
	aws-e2e aws-iam-probe aws-destroy experiment fetch-sample clean serve apply-bedrock

.PHONY: help list diagrams $(SPIKE_TARGETS)

# Per-spike Archify diagrams: one fragment per tool in docs/diagrams/tools/<tool>.mk.
-include docs/diagrams/tools/*.mk

help: ## Show root targets (select a spike with SPIKE=...)
	@echo "Usage: make [SPIKE=<spike-name>] <target>"
	@echo "Diagram targets: diagrams (all spikes), diagrams-archify, diagrams-archify-clean (SPIKE=...)"
	@echo "Available spikes:"
	@$(MAKE) --no-print-directory list
	@$(MAKE) --no-print-directory -C "$(SPIKE_DIR)" help

list: ## List available spikes
	@find src -mindepth 1 -maxdepth 1 -type d -name 'spike-*' -exec basename {} \; | sort

diagrams: ## Render every spike's Archify diagrams
	@for d in src/spike-*/diagrams/archify; do \
	  $(MAKE) --no-print-directory SPIKE=$$(basename $$(dirname $$(dirname $$d))) diagrams-archify || exit 1; \
	done

$(SPIKE_TARGETS):
	@test -f "$(SPIKE_DIR)/Makefile" || { echo "unknown spike: $(SPIKE)" >&2; exit 2; }
	@$(MAKE) -C "$(SPIKE_DIR)" $@ $(filter-out $@,$(MAKECMDGOALS))

# Keep arbitrary Make variable assignments (for example MESSAGE=...) when
# forwarding root commands into the selected spike.
