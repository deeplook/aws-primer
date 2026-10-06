SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

TF_FORMAT_FILES := $(wildcard *.tf) floci.tfvars
COMPOSE := docker compose --project-directory . -f compose.yaml
FLOCI_REGION := $(shell sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' floci.tfvars)
FLOCI_ENDPOINT := $(shell sed -n 's/^floci_endpoint_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' floci.tfvars)
AWS_TFVARS := aws.tfvars
AWS_REGION := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
AWS_ACCOUNT_ID := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^aws_account_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
AWS_TARGET := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^deployment_target[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
LOCAL_AWS_ENV := env -u AWS_PROFILE AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=$(FLOCI_REGION) AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
LOCAL_AWS := $(LOCAL_AWS_ENV) aws --endpoint-url $(FLOCI_ENDPOINT)

.PHONY: help tools local-up local-down local-clean local-logs local-log-tail terraform-init aws-terraform-init \
	terraform-fmt terraform-fmt-check validate check-all plan apply destroy e2e \
	aws-target-check aws-plan aws-apply aws-e2e aws-destroy

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tools: ## Check the tools required by the spike
	@command -v docker >/dev/null || { echo "missing: docker" >&2; exit 1; }
	@command -v terraform >/dev/null || { echo "missing: terraform" >&2; exit 1; }
	@command -v aws >/dev/null || { echo "missing: AWS CLI" >&2; exit 1; }
	@command -v curl >/dev/null || { echo "missing: curl" >&2; exit 1; }
	@echo "Required tools are available."

local-up: tools ## Start Floci locally and wait until its S3 API responds
	@docker info >/dev/null
	@$(COMPOSE) up -d
	@for attempt in {1..30}; do \
		if $(LOCAL_AWS) s3api list-buckets >/dev/null 2>&1; then \
			echo "Floci is ready at $(FLOCI_ENDPOINT)"; exit 0; \
		fi; \
		sleep 1; \
	done; \
	$(COMPOSE) logs --tail=80 floci; \
	echo "Floci did not become ready within 30 seconds." >&2; exit 1

local-down: ## Stop Floci without removing its ignored local data directory
	@$(COMPOSE) down

local-clean: ## Destroy the local stack, stop Floci, and remove local data and Terraform plugins
	@$(MAKE) destroy
	@$(MAKE) local-down
	@rm -rf data .terraform
	@echo "Removed local Floci data and Terraform's downloaded provider plugins."

local-logs: ## Follow Floci logs
	@$(COMPOSE) logs --follow floci

local-log-tail: ## Show the last 80 Floci log lines
	@$(COMPOSE) logs --tail=80 floci

terraform-init: ## Initialize the separate local Floci Terraform state
	@terraform init -reconfigure -lockfile=readonly -backend-config=path=terraform.tfstate

aws-terraform-init: ## Initialize the separate AWS Terraform state
	@test -f $(AWS_TFVARS) || { echo "copy aws.tfvars.example to aws.tfvars and set the account ID" >&2; exit 2; }
	@terraform init -reconfigure -lockfile=readonly -backend-config=path=terraform.aws.tfstate

terraform-fmt: ## Format Terraform files
	@terraform fmt $(TF_FORMAT_FILES)

terraform-fmt-check: ## Check Terraform formatting
	@terraform fmt -check $(TF_FORMAT_FILES)

validate: terraform-init ## Validate the local Floci configuration
	@terraform validate

check-all: terraform-fmt-check validate ## Run the safe local quality gate

plan: ## Start Floci and show the local Terraform plan
	@$(MAKE) local-up
	@$(MAKE) terraform-init
	@terraform validate
	@terraform plan -var-file=floci.tfvars

apply: ## Start Floci and apply the local stack
	@$(MAKE) local-up
	@$(MAKE) terraform-init
	@terraform validate
	@terraform apply -var-file=floci.tfvars -auto-approve

destroy: ## Remove local Terraform resources (keeps Floci running)
	@$(MAKE) local-up
	@$(MAKE) terraform-init
	@terraform destroy -var-file=floci.tfvars -auto-approve -parallelism=1

e2e: ## Run the local public S3 website check; leaves the stack and Floci running
	@AWS_DEFAULT_REGION="$(FLOCI_REGION)" AWS_ENDPOINT_URL="$(FLOCI_ENDPOINT)" bash e2e.sh

aws-target-check: ## Confirm AWS profile and configured account ID match
	@test -f $(AWS_TFVARS) || { echo "copy aws.tfvars.example to aws.tfvars and set the account ID" >&2; exit 2; }
	@test "$(AWS_TARGET)" = "aws" || { echo "set deployment_target = \"aws\" in aws.tfvars" >&2; exit 2; }
	@test -n "$(AWS_REGION)" || { echo "set aws_region in aws.tfvars" >&2; exit 2; }
	@[[ "$(AWS_ACCOUNT_ID)" =~ ^[0-9]{12}$$ ]] || { echo "set aws_account_id to a 12-digit account ID in aws.tfvars" >&2; exit 2; }
	@test -n "$${AWS_PROFILE:-}" || { echo "set AWS_PROFILE to an authenticated AWS profile" >&2; exit 2; }
	@actual="$$(aws --profile "$${AWS_PROFILE}" sts get-caller-identity --query Account --output text)" || { echo "Could not verify AWS_PROFILE=$${AWS_PROFILE} with AWS STS." >&2; exit 1; }; \
	if [[ "$$actual" != "$(AWS_ACCOUNT_ID)" ]]; then \
		echo "AWS profile account does not match the account configured in aws.tfvars." >&2; exit 1; \
	fi; \
	echo "AWS profile is authenticated to the configured account."

aws-plan: ## Show the AWS plan (set AWS_PROFILE)
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@AWS_PROFILE="$${AWS_PROFILE}" terraform plan -var-file=$(AWS_TFVARS)

aws-apply: ## Create the public S3 website in AWS (set AWS_PROFILE)
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@AWS_PROFILE="$${AWS_PROFILE}" terraform apply -var-file=$(AWS_TFVARS)

aws-e2e: ## Deploy and anonymously fetch the AWS website (set AWS_PROFILE); leaves it running
	@AWS_PROFILE="$${AWS_PROFILE:-}" bash e2e-aws.sh

aws-destroy: ## Remove the AWS bucket and its objects (set AWS_PROFILE)
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@AWS_PROFILE="$${AWS_PROFILE}" terraform destroy -var-file=$(AWS_TFVARS)
