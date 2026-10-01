SPIKE ?= spike-1
SPIKE_DIR := src/$(SPIKE)

SPIKE_TARGETS := tools local-up local-down local-logs local-log-tail package terraform-init \
	terraform-fmt terraform-fmt-check python-check validate check-all plan apply \
	send-message verify destroy e2e aws-plan aws-apply aws-send-message aws-send-event aws-verify \
	aws-e2e aws-destroy clean

.PHONY: help list $(SPIKE_TARGETS)

help: ## Show root targets (select a spike with SPIKE=...)
	@echo "Usage: make [SPIKE=<spike-name>] <target>"
	@echo "Available spikes:"
	@$(MAKE) --no-print-directory list
	@$(MAKE) --no-print-directory -C "$(SPIKE_DIR)" help

list: ## List available spikes
	@find src -mindepth 1 -maxdepth 1 -type d -name 'spike-*' -exec basename {} \; | sort

$(SPIKE_TARGETS):
	@test -f "$(SPIKE_DIR)/Makefile" || { echo "unknown spike: $(SPIKE)" >&2; exit 2; }
	@$(MAKE) -C "$(SPIKE_DIR)" $@ $(filter-out $@,$(MAKECMDGOALS))

# Keep arbitrary Make variable assignments (for example MESSAGE=...) when
# forwarding root commands into the selected spike.
