# Archify: renders src/<spike>/diagrams/archify/<type>-<slug>.json (tracked sources) and publishes, per diagram,
#   src/<spike>/diagrams/<type>-<slug>.html       interactive diagram to download or open locally (tracked)
#   src/<spike>/diagrams/<type>-<slug>.light.png  README preview (tracked)
# Receipts, dark PNGs and other evidence stay in the ignored src/<spike>/build/diagrams/archify/.
# Select the spike with SPIKE=spike-1; `make diagrams` does all spikes. Needs Node 18+, a local Chrome and uv.
# Source citations are verified against ARCHIFY_REPO_ROOT (default: this repo): its `origin` must match
# meta.repository.url and HEAD must contain meta.repository.revision, so the cited files must be committed.
ARCHIFY_SRC_DIR := $(SPIKE_DIR)/diagrams/archify
ARCHIFY_OUT_DIR := $(SPIKE_DIR)/build/diagrams/archify
ARCHIFY_PUBLISH_DIR := $(SPIKE_DIR)/diagrams
ARCHIFY_SRC := $(sort $(wildcard $(ARCHIFY_SRC_DIR)/*.json))
ARCHIFY_REPO_ROOT ?= $(CURDIR)

.PHONY: diagrams-archify diagrams-archify-clean

diagrams-archify: ## Render and publish the selected spike's Archify diagrams (SPIKE=...)
	@test -f "$(ARCHIFY_CLI)" || { echo "Archify CLI not found. Install the Archify skill or set ARCHIFY_CLI to its bin/archify.mjs path." >&2; exit 2; }
	@test -n "$(ARCHIFY_SRC)" || { echo "no diagram sources in $(ARCHIFY_SRC_DIR)" >&2; exit 2; }
	@mkdir -p $(ARCHIFY_OUT_DIR)
	@for src in $(ARCHIFY_SRC); do \
	  name=$$(basename $$src .json); type=$${name%%-*}; \
	  echo "archify $$type: $(SPIKE)/$$name"; \
	  rm -rf $(ARCHIFY_OUT_DIR)/$$name.*; \
	  (cd $(SPIKE_DIR) && $(NODE) "$(ARCHIFY_CLI)" finalize $$type diagrams/archify/$$name.json build/diagrams/archify/$$name.html \
	    --quality showcase --repo-root "$(ARCHIFY_REPO_ROOT)" --json >/dev/null) || { echo "failed: $$src" >&2; exit 1; }; \
	done
	@uv run --with playwright python scripts/diagrams_png.py $(ARCHIFY_OUT_DIR)/*.html >/dev/null
	@for html in $(ARCHIFY_OUT_DIR)/*.html; do \
	  name=$$(basename $$html .html); \
	  cp $$html $(ARCHIFY_PUBLISH_DIR)/$$name.html; \
	  cp $(ARCHIFY_OUT_DIR)/$$name.light.png $(ARCHIFY_PUBLISH_DIR)/$$name.light.png; \
	  echo "published $(ARCHIFY_PUBLISH_DIR)/$$name.{html,light.png}"; \
	done

diagrams-archify-clean: ## Remove the selected spike's ignored Archify build output
	rm -rf $(ARCHIFY_OUT_DIR)
