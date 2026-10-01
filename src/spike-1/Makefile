SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

TF_DIR := .
TF_FORMAT_FILES := $(wildcard *.tf) floci.tfvars
COMPOSE := docker compose --project-directory . -f compose.yaml
FLOCI_REGION := $(shell sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' floci.tfvars)
FLOCI_ENDPOINT := $(shell sed -n 's/^floci_endpoint_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' floci.tfvars)
AWS_TFVARS := aws.tfvars
AWS_REGION := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
AWS_ACCOUNT_ID := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^aws_account_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
LOCAL_AWS_ENV := AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=$(FLOCI_REGION) AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
LOCAL_AWS := $(LOCAL_AWS_ENV) aws --endpoint-url $(FLOCI_ENDPOINT)

export MESSAGE MESSAGE_ID

.PHONY: help tools local-up local-down local-logs local-log-tail package terraform-init aws-terraform-init \
	terraform-fmt terraform-fmt-check python-check shell-check validate check-all plan \
	apply send-message verify destroy e2e aws-target-check aws-plan aws-apply \
	aws-send-message aws-verify aws-e2e aws-destroy clean

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tools: ## Check the local tools required by the lessons
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

package: ## Package the Lambda handler into the ignored worker.zip
	@python3 -c 'from zipfile import ZipFile, ZIP_DEFLATED; z=ZipFile("$(TF_DIR)/worker.zip", "w", ZIP_DEFLATED); z.write("$(TF_DIR)/handler.py", "handler.py"); z.close()'

terraform-init: ## Initialize the Floci Terraform state
	@terraform -chdir=$(TF_DIR) init -reconfigure -lockfile=readonly -backend-config=path=terraform.tfstate

aws-terraform-init: ## Initialize the separate AWS Terraform state
	@test -f $(AWS_TFVARS) || { echo "copy aws.tfvars.example to aws.tfvars and set the account ID" >&2; exit 2; }
	@terraform -chdir=$(TF_DIR) init -reconfigure -lockfile=readonly -backend-config=path=terraform.aws.tfstate

terraform-fmt: ## Format Terraform files
	@terraform fmt $(TF_FORMAT_FILES)

terraform-fmt-check: ## Check Terraform formatting without changing files
	@terraform fmt -check $(TF_FORMAT_FILES)

python-check: ## Check Python syntax without creating bytecode files
	@python3 -c 'from pathlib import Path; compile(Path("$(TF_DIR)/handler.py").read_text(), "$(TF_DIR)/handler.py", "exec")'

shell-check: ## Check shell script syntax
	@bash -n e2e.sh e2e-aws.sh

validate: terraform-init ## Validate the Terraform configuration
	@terraform -chdir=$(TF_DIR) validate

check-all: terraform-fmt-check python-check shell-check validate ## Run the safe local quality gate

plan: ## Start Floci, package the function, and show the local Terraform plan
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

send-message: ## Send a test message (set MESSAGE=...)
	@test -n "$${MESSAGE:-}" || { echo "usage: make send-message MESSAGE='hello'" >&2; exit 2; }
	@queue_url="$$(terraform -chdir=$(TF_DIR) output -raw queue_url)"; \
	$(LOCAL_AWS) sqs send-message --queue-url "$$queue_url" --message-body "$$MESSAGE"

verify: ## Verify one message (set MESSAGE_ID=... MESSAGE=...)
	@test -n "$${MESSAGE_ID:-}" -a -n "$${MESSAGE:-}" || { echo "usage: make verify MESSAGE_ID=... MESSAGE='hello'" >&2; exit 2; }
	@bucket="$$(terraform -chdir=$(TF_DIR) output -raw uploads_bucket_name)"; \
	table="$$(terraform -chdir=$(TF_DIR) output -raw processed_table_name)"; \
	$(LOCAL_AWS) s3api head-object --bucket "$$bucket" --key "processed/$$MESSAGE_ID.txt"; \
	$(LOCAL_AWS) dynamodb get-item --table-name "$$table" --key "{\"message_id\":{\"S\":\"$$MESSAGE_ID\"}}" --query 'Item.body.S' --output text | grep -Fx -- "$$MESSAGE"

destroy: ## Remove local Terraform resources (keeps Floci running)
	@$(MAKE) local-up
	@$(MAKE) terraform-init
	@bucket="$$(terraform -chdir=$(TF_DIR) output -raw uploads_bucket_name 2>/dev/null || true)"; \
	if [[ -n "$$bucket" ]] && $(LOCAL_AWS) s3api head-bucket --bucket "$$bucket" >/dev/null 2>&1; then \
		$(LOCAL_AWS) s3 rm "s3://$$bucket/processed/" --recursive; \
	fi
	@terraform -chdir=$(TF_DIR) destroy -var-file=floci.tfvars -auto-approve -parallelism=1

e2e: ## Run the full local SQS -> Lambda -> S3 + DynamoDB flow, then clean up
	@AWS_DEFAULT_REGION="$(FLOCI_REGION)" AWS_ENDPOINT_URL="$(FLOCI_ENDPOINT)" bash e2e.sh

aws-target-check: ## Confirm AWS profile and configured account ID match
	@test -f $(AWS_TFVARS) || { echo "copy aws.tfvars.example to aws.tfvars and set the account ID" >&2; exit 2; }
	@test -n "$${AWS_PROFILE:-}" || { echo "set AWS_PROFILE to an authenticated profile" >&2; exit 2; }
	@test -n "$(AWS_ACCOUNT_ID)" && test "$(AWS_ACCOUNT_ID)" != "REPLACE_WITH_12_DIGIT_ACCOUNT_ID" || { echo "set aws_account_id in aws.tfvars" >&2; exit 2; }
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

aws-send-message: ## Send a message to the AWS queue (set AWS_PROFILE and MESSAGE)
	@test -n "$${MESSAGE:-}" || { echo "usage: make aws-send-message AWS_PROFILE=... MESSAGE='hello'" >&2; exit 2; }
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@queue_url="$$(AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) output -raw queue_url)"; \
	aws --profile "$${AWS_PROFILE}" --region "$(AWS_REGION)" sqs send-message --queue-url "$$queue_url" --message-body "$$MESSAGE"

aws-verify: ## Verify AWS S3 and DynamoDB writes (set AWS_PROFILE and MESSAGE_ID)
	@test -n "$${MESSAGE_ID:-}" || { echo "usage: make aws-verify AWS_PROFILE=... MESSAGE_ID=..." >&2; exit 2; }
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@bucket="$$(AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) output -raw uploads_bucket_name)"; \
	table="$$(AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) output -raw processed_table_name)"; \
	aws --profile "$${AWS_PROFILE}" --region "$(AWS_REGION)" s3api head-object --bucket "$$bucket" --key "processed/$(MESSAGE_ID).txt"; \
	aws --profile "$${AWS_PROFILE}" --region "$(AWS_REGION)" dynamodb get-item --table-name "$$table" --key '{"message_id":{"S":"$(MESSAGE_ID)"}}' --query 'Item.body.S' --output text

aws-e2e: ## Deploy and verify one AWS message; leaves resources running (set AWS_PROFILE)
	@AWS_PROFILE="$${AWS_PROFILE:-}" bash e2e-aws.sh

aws-destroy: ## Destroy the AWS stack only when its S3 bucket is empty (set AWS_PROFILE)
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@bucket="$$(AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) output -raw uploads_bucket_name)"; \
	object_count="$$(aws --profile "$${AWS_PROFILE}" --region "$(AWS_REGION)" s3api list-objects-v2 --max-keys 1 --bucket "$$bucket" --query 'length(Contents || `[]`)' --output text)"; \
	if [[ "$$object_count" != "0" ]]; then \
		echo "S3 bucket $$bucket contains at least one object. Empty it explicitly with: aws --profile $${AWS_PROFILE} --region $(AWS_REGION) s3 rm s3://$$bucket --recursive" >&2; exit 1; \
	fi; \
	AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) destroy -var-file=$(AWS_TFVARS)

clean: ## Remove the generated Lambda archive only
	@rm -f $(TF_DIR)/worker.zip
