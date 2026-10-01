SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

TF_DIR := .
TF_FORMAT_FILES := $(wildcard *.tf) floci.tfvars
AWS_TFVARS := aws.tfvars
FLOCI_REGION := $(shell sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' floci.tfvars)
FLOCI_ENDPOINT := $(shell sed -n 's/^floci_endpoint_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' floci.tfvars)
AWS_REGION := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
AWS_ACCOUNT_ID := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^aws_account_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
AWS_TARGET := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^deployment_target[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
COMPOSE := docker compose --project-directory . -f compose.yaml
LOCAL_AWS_ENV := AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=$(FLOCI_REGION) AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
LOCAL_AWS := $(LOCAL_AWS_ENV) aws --endpoint-url $(FLOCI_ENDPOINT)
export ORDER_ID CUSTOMER_ID AMOUNT_CENTS

.PHONY: help tools local-up local-down local-logs local-log-tail package terraform-init aws-terraform-init \
	terraform-fmt terraform-fmt-check python-check shell-check validate check-all plan apply \
	send-event verify destroy e2e aws-target-check aws-plan aws-apply \
	aws-send-event aws-verify aws-e2e aws-destroy clean

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tools: ## Check the local tools required by the spike
	@command -v docker >/dev/null || { echo "missing: docker" >&2; exit 1; }
	@command -v terraform >/dev/null || { echo "missing: terraform" >&2; exit 1; }
	@command -v aws >/dev/null || { echo "missing: AWS CLI" >&2; exit 1; }
	@command -v python3 >/dev/null || { echo "missing: python3" >&2; exit 1; }
	@echo "Required tools are available."

local-up: tools ## Start Floci locally and wait until its AWS API responds
	@docker info >/dev/null
	@$(COMPOSE) up -d
	@for attempt in {1..30}; do \
		if $(LOCAL_AWS) sts get-caller-identity >/dev/null 2>&1; then \
			echo "Floci is ready at $(FLOCI_ENDPOINT)"; exit 0; \
		fi; \
		sleep 1; \
	done; \
	$(COMPOSE) logs --tail=80 floci; \
	echo "Floci did not become ready within 30 seconds." >&2; exit 1

local-down: ## Stop Floci without removing its ignored local data directory
	@$(COMPOSE) down

local-logs: ## Follow Floci logs
	@$(COMPOSE) logs --follow floci

local-log-tail: ## Show the last 80 Floci log lines
	@$(COMPOSE) logs --tail=80 floci

package: ## Package the Lambda handlers into the ignored worker.zip
	@python3 -c 'from zipfile import ZipFile, ZIP_DEFLATED; z=ZipFile("worker.zip", "w", ZIP_DEFLATED); z.write("handler.py", "handler.py"); z.close()'

terraform-init: ## Initialize the separate local Floci Terraform state
	@terraform -chdir=$(TF_DIR) init -reconfigure -lockfile=readonly -backend-config=path=terraform.tfstate

aws-terraform-init: ## Initialize the separate AWS Terraform state
	@test -f $(AWS_TFVARS) || { echo "copy aws.tfvars.example to aws.tfvars and set the account ID" >&2; exit 2; }
	@terraform -chdir=$(TF_DIR) init -reconfigure -lockfile=readonly -backend-config=path=terraform.aws.tfstate

terraform-fmt: ## Format Terraform files
	@terraform fmt $(TF_FORMAT_FILES)

terraform-fmt-check: ## Check Terraform formatting without changing files
	@terraform fmt -check $(TF_FORMAT_FILES)

python-check: ## Check Python syntax without creating bytecode files
	@python3 -c 'from pathlib import Path; compile(Path("handler.py").read_text(), "handler.py", "exec")'

shell-check: ## Check shell script syntax
	@bash -n e2e.sh e2e-aws.sh

validate: package terraform-init ## Package the handlers and validate the Terraform configuration
	@terraform -chdir=$(TF_DIR) validate

check-all: terraform-fmt-check python-check shell-check validate ## Run the safe local quality gate

plan: ## Start Floci, package the functions, and show the local Terraform plan
	@$(MAKE) local-up
	@$(MAKE) package
	@$(MAKE) terraform-init
	@terraform -chdir=$(TF_DIR) validate
	@terraform -chdir=$(TF_DIR) plan -var-file=floci.tfvars

apply: ## Start Floci and apply the stack to its localhost endpoint
	@$(MAKE) local-up
	@$(MAKE) package
	@$(MAKE) terraform-init
	@terraform -chdir=$(TF_DIR) validate
	@terraform -chdir=$(TF_DIR) apply -var-file=floci.tfvars -auto-approve

send-event: ## Publish an OrderPlaced event locally (set ORDER_ID=...)
	@test -n "$${ORDER_ID:-}" || { echo "usage: make send-event ORDER_ID=..." >&2; exit 2; }
	@bus="$$(terraform -chdir=$(TF_DIR) output -raw event_bus_name)"; \
	entries="$$(ORDER_ID="$$ORDER_ID" CUSTOMER_ID="$${CUSTOMER_ID:-demo-customer}" AMOUNT_CENTS="$${AMOUNT_CENTS:-4200}" EVENT_BUS="$$bus" python3 -c 'import json, os; detail={"order_id":os.environ["ORDER_ID"],"customer_id":os.environ["CUSTOMER_ID"],"amount_cents":int(os.environ["AMOUNT_CENTS"])}; print(json.dumps([{"Source":"aws-primer.orders","DetailType":"OrderPlaced","Detail":json.dumps(detail),"EventBusName":os.environ["EVENT_BUS"]}]))')"; \
	$(LOCAL_AWS) events put-events --entries "$$entries"

verify: ## Verify a stored local order (set ORDER_ID=...)
	@test -n "$${ORDER_ID:-}" || { echo "usage: make verify ORDER_ID=..." >&2; exit 2; }
	@table="$$(terraform -chdir=$(TF_DIR) output -raw orders_table_name)"; \
	$(LOCAL_AWS) dynamodb get-item --table-name "$$table" --key "{\"order_id\":{\"S\":\"$$ORDER_ID\"}}" --query 'Item.{status:status.S,amount:amount_cents.N}' --output json

destroy: ## Remove local Terraform resources (keeps Floci running)
	@$(MAKE) local-up
	@$(MAKE) terraform-init
	@terraform -chdir=$(TF_DIR) destroy -var-file=floci.tfvars -auto-approve -parallelism=1

e2e: ## Run the EventBridge -> Lambda -> Step Functions -> DynamoDB flow locally, then clean up
	@AWS_DEFAULT_REGION="$(FLOCI_REGION)" AWS_ENDPOINT_URL="$(FLOCI_ENDPOINT)" bash e2e.sh

aws-target-check: ## Confirm AWS profile and configured account ID match
	@test -f $(AWS_TFVARS) || { echo "copy aws.tfvars.example to aws.tfvars and set the account ID" >&2; exit 2; }
	@test "$(AWS_TARGET)" = "aws" || { echo "set deployment_target = \"aws\" in aws.tfvars" >&2; exit 2; }
	@test -n "$(AWS_REGION)" || { echo "set aws_region in aws.tfvars" >&2; exit 2; }
	@[[ "$(AWS_ACCOUNT_ID)" =~ ^[0-9]{12}$$ ]] || { echo "set aws_account_id to a 12-digit account ID in aws.tfvars" >&2; exit 2; }
	@test -n "$${AWS_PROFILE:-}" || { echo "set AWS_PROFILE to an authenticated profile" >&2; exit 2; }
	@actual="$$(aws --profile "$${AWS_PROFILE}" sts get-caller-identity --query Account --output text)"; \
	if [[ "$$actual" != "$(AWS_ACCOUNT_ID)" ]]; then \
		echo "AWS profile account $$actual does not match aws.tfvars account $(AWS_ACCOUNT_ID)." >&2; exit 1; \
	fi; \
	echo "AWS profile is authenticated to account $$actual."

aws-plan: ## Show the AWS plan without applying it (set AWS_PROFILE)
	@$(MAKE) aws-target-check
	@$(MAKE) package
	@$(MAKE) aws-terraform-init
	@terraform -chdir=$(TF_DIR) validate
	@AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) plan -var-file=$(AWS_TFVARS)

aws-apply: ## Apply the AWS stack after confirmation (set AWS_PROFILE)
	@$(MAKE) aws-target-check
	@$(MAKE) package
	@$(MAKE) aws-terraform-init
	@terraform -chdir=$(TF_DIR) validate
	@AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) apply -var-file=$(AWS_TFVARS)

aws-send-event: ## Publish an OrderPlaced event to AWS (set AWS_PROFILE and ORDER_ID)
	@test -n "$${ORDER_ID:-}" || { echo "usage: make aws-send-event AWS_PROFILE=... ORDER_ID=..." >&2; exit 2; }
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@bus="$$(AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) output -raw event_bus_name)"; \
	entries="$$(ORDER_ID="$$ORDER_ID" CUSTOMER_ID="$${CUSTOMER_ID:-demo-customer}" AMOUNT_CENTS="$${AMOUNT_CENTS:-4200}" EVENT_BUS="$$bus" python3 -c 'import json, os; detail={"order_id":os.environ["ORDER_ID"],"customer_id":os.environ["CUSTOMER_ID"],"amount_cents":int(os.environ["AMOUNT_CENTS"])}; print(json.dumps([{"Source":"aws-primer.orders","DetailType":"OrderPlaced","Detail":json.dumps(detail),"EventBusName":os.environ["EVENT_BUS"]}]))')"; \
	aws --profile "$${AWS_PROFILE}" --region "$(AWS_REGION)" events put-events --entries "$$entries"

aws-verify: ## Verify an AWS order write (set AWS_PROFILE and ORDER_ID)
	@test -n "$${ORDER_ID:-}" || { echo "usage: make aws-verify AWS_PROFILE=... ORDER_ID=..." >&2; exit 2; }
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@table="$$(AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) output -raw orders_table_name)"; \
	aws --profile "$${AWS_PROFILE}" --region "$(AWS_REGION)" dynamodb get-item --table-name "$$table" --key '{"order_id":{"S":"$(ORDER_ID)"}}' --query 'Item.{status:status.S,amount:amount_cents.N}' --output json

aws-e2e: ## Deploy and verify one AWS order; leaves resources running (set AWS_PROFILE)
	@AWS_PROFILE="$${AWS_PROFILE:-}" bash e2e-aws.sh

aws-destroy: ## Destroy the AWS stack after Terraform confirmation (set AWS_PROFILE)
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) destroy -var-file=$(AWS_TFVARS)

clean: ## Remove the generated Lambda archive only
	@rm -f worker.zip
