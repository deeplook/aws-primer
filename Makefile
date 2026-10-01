SPIKE ?= spike-1
SPIKE_DIR := src/$(SPIKE)
NODE ?= node
ARCHIFY_CLI ?= $(firstword $(wildcard $(HOME)/.agents/skills/archify/bin/archify.mjs $(HOME)/.codex/skills/archify/bin/archify.mjs $(HOME)/.claude/skills/archify/bin/archify.mjs))

SPIKE_1_DIAGRAM_DIR := src/spike-1/.archify/dataflow-sqs-persistence-20261001-130013
SPIKE_2_DIAGRAM_DIR := src/spike-2/.archify/workflow-order-event-20261001-130013

SPIKE_TARGETS := tools local-up local-down local-logs local-log-tail package terraform-init \
	terraform-fmt terraform-fmt-check python-check shell-check validate check-all plan apply \
	send-message verify destroy e2e aws-plan aws-apply aws-send-message aws-send-event aws-verify \
	aws-e2e aws-destroy clean

.PHONY: help list diagrams diagram-spike-1 diagram-spike-2 $(SPIKE_TARGETS)

help: ## Show root targets (select a spike with SPIKE=...)
	@echo "Usage: make [SPIKE=<spike-name>] <target>"
	@echo "Diagram targets: diagrams, diagram-spike-1, diagram-spike-2"
	@echo "Available spikes:"
	@$(MAKE) --no-print-directory list
	@$(MAKE) --no-print-directory -C "$(SPIKE_DIR)" help

list: ## List available spikes
	@find src -mindepth 1 -maxdepth 1 -type d -name 'spike-*' -exec basename {} \; | sort

diagrams: diagram-spike-1 diagram-spike-2 ## Regenerate both diagrams and README previews

diagram-spike-1: ## Regenerate spike 1's data-flow diagram and preview
	@test -f "$(ARCHIFY_CLI)" || { echo "Archify CLI not found. Install the Archify skill or set ARCHIFY_CLI to its bin/archify.mjs path." >&2; exit 2; }
	@$(NODE) "$(ARCHIFY_CLI)" finalize dataflow \
		$(SPIKE_1_DIAGRAM_DIR)/candidate.json \
		$(SPIKE_1_DIAGRAM_DIR)/sqs-message-dataflow.html \
		--repo-root . --quality showcase --json
	@$(NODE) "$(ARCHIFY_CLI)" visual-check \
		$(SPIKE_1_DIAGRAM_DIR)/sqs-message-dataflow.html \
		--summary --require-provenance

diagram-spike-2: ## Regenerate spike 2's workflow diagram and preview
	@test -f "$(ARCHIFY_CLI)" || { echo "Archify CLI not found. Install the Archify skill or set ARCHIFY_CLI to its bin/archify.mjs path." >&2; exit 2; }
	@$(NODE) "$(ARCHIFY_CLI)" finalize workflow \
		$(SPIKE_2_DIAGRAM_DIR)/candidate.json \
		$(SPIKE_2_DIAGRAM_DIR)/order-event-workflow.html \
		--repo-root . --quality showcase --json
	@$(NODE) "$(ARCHIFY_CLI)" visual-check \
		$(SPIKE_2_DIAGRAM_DIR)/order-event-workflow.html \
		--summary --require-provenance

$(SPIKE_TARGETS):
	@test -f "$(SPIKE_DIR)/Makefile" || { echo "unknown spike: $(SPIKE)" >&2; exit 2; }
	@$(MAKE) -C "$(SPIKE_DIR)" $@ $(filter-out $@,$(MAKECMDGOALS))

# Keep arbitrary Make variable assignments (for example MESSAGE=...) when
# forwarding root commands into the selected spike.
