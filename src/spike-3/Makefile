SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

TF_DIR := .
AWS_TFVARS := aws.tfvars
AWS_PROFILE ?= dinu
REGION ?= us-west-2
MODEL_ID ?= stability.stable-image-ultra-v1:1
OUTPUT ?= output/professional-portrait.png
STRENGTH ?= 0.75
PROMPT ?= A polished professional business portrait of the same person in the input photo. Preserve their recognizable face, facial features, age, skin tone, hair, and natural expression. Change the clothing to elegant business attire and replace the surroundings with a softly lit modern office studio. Photorealistic, natural skin texture, flattering soft light, head-and-shoulders composition.
JOB_PROMPT ?= Professional photo headshot of this person in a business suit standing alone in an elevator looking into the camera.
AWS_REGION := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
AWS_ACCOUNT_ID := $(shell if test -f $(AWS_TFVARS); then sed -n 's/^aws_account_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS); fi)
FLOCI_REGION := $(shell sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' floci.tfvars)
FLOCI_ENDPOINT := $(shell sed -n 's/^floci_endpoint_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' floci.tfvars)
COMPOSE := docker compose --project-directory . -f compose.yaml
LOCAL_AWS_ENV := AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=$(FLOCI_REGION) AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
LOCAL_AWS := env -u AWS_PROFILE $(LOCAL_AWS_ENV) aws --endpoint-url $(FLOCI_ENDPOINT)

.PHONY: help tools local-up local-down local-clean local-logs local-log-tail package terraform-init aws-terraform-init \
	terraform-fmt terraform-fmt-check python-check shell-check validate check-all plan apply destroy e2e \
	serve apply-bedrock aws-target-check aws-plan aws-apply aws-e2e aws-destroy clean experiment fetch-sample

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tools: ## Check tools required by the spike
	@command -v docker >/dev/null || { echo "missing: docker" >&2; exit 1; }
	@command -v terraform >/dev/null || { echo "missing: terraform" >&2; exit 1; }
	@command -v aws >/dev/null || { echo "missing: AWS CLI" >&2; exit 1; }
	@command -v python3 >/dev/null || { echo "missing: python3" >&2; exit 1; }
	@command -v curl >/dev/null || { echo "missing: curl" >&2; exit 1; }
	@echo "Required tools are available."

local-up: tools ## Start Floci on port 4567 and wait for its API
	@docker info >/dev/null
	@$(COMPOSE) up -d
	@for attempt in {1..30}; do \
		if $(LOCAL_AWS) sts get-caller-identity >/dev/null 2>&1; then echo "Floci is ready at $(FLOCI_ENDPOINT)"; exit 0; fi; \
		sleep 1; \
	done; \
	$(COMPOSE) logs --tail=80 floci; echo "Floci did not become ready within 30 seconds." >&2; exit 1

local-down: ## Stop Floci and its Lambda runtimes while keeping local data
	@$(COMPOSE) down
	@containers="$$(docker ps --filter status=running --filter name=floci-aws-primer-spike-3 -q)"; \
	if [[ -n "$$containers" ]]; then docker stop $$containers; fi

local-clean: ## Destroy the local stack, stop Floci, and remove local data and provider plugins
	@$(MAKE) destroy
	@$(MAKE) local-down
	@rm -rf data .terraform
	@echo "Removed Spike 3 Floci data and Terraform provider plugins."

local-logs: ## Follow Floci logs
	@$(COMPOSE) logs --follow floci

local-log-tail: ## Show recent Floci logs
	@$(COMPOSE) logs --tail=80 floci

package: ## Package Lambda code as worker.zip
	@python3 -c 'from zipfile import ZipFile, ZIP_DEFLATED; z=ZipFile("worker.zip", "w", ZIP_DEFLATED); z.write("handler.py", "handler.py"); z.close()'

terraform-init: ## Initialize the separate local Floci state
	@terraform -chdir=$(TF_DIR) init -reconfigure -lockfile=readonly -backend-config=path=terraform.tfstate

aws-terraform-init: ## Initialize the separate AWS state
	@test -f $(AWS_TFVARS) || { echo "copy aws.tfvars.example to aws.tfvars and set the account ID" >&2; exit 2; }
	@terraform -chdir=$(TF_DIR) init -reconfigure -lockfile=readonly -backend-config=path=terraform.aws.tfstate

terraform-fmt: ## Format Terraform files
	@terraform fmt $(wildcard *.tf) floci.tfvars

terraform-fmt-check: ## Check Terraform formatting
	@terraform fmt -check $(wildcard *.tf) floci.tfvars

python-check: ## Check Python syntax
	@python3 -c 'from pathlib import Path; [compile(Path(p).read_text(), p, "exec") for p in ("handler.py", "serve.py", "apply_bedrock.py", "experiment.py", "aws-e2e.py")]'

shell-check: ## Check shell syntax
	@bash -n e2e.sh

validate: package terraform-init ## Package code and validate Terraform
	@terraform -chdir=$(TF_DIR) validate

check-all: terraform-fmt-check python-check shell-check validate ## Run local static checks

plan: ## Show the local Floci plan
	@$(MAKE) local-up
	@$(MAKE) package
	@$(MAKE) terraform-init
	@terraform -chdir=$(TF_DIR) validate
	@terraform -chdir=$(TF_DIR) plan -var-file=floci.tfvars

apply: ## Apply the local Floci stack
	@$(MAKE) local-up
	@$(MAKE) package
	@$(MAKE) terraform-init
	@terraform -chdir=$(TF_DIR) apply -var-file=floci.tfvars -auto-approve -parallelism=1

destroy: ## Destroy local Terraform resources while Floci stays running
	@$(MAKE) local-up
	@$(MAKE) terraform-init
	@bucket="$$(terraform -chdir=$(TF_DIR) output -raw uploads_bucket_name 2>/dev/null || true)"; \
	if [[ -n "$$bucket" ]] && $(LOCAL_AWS) s3api head-bucket --bucket "$$bucket" >/dev/null 2>&1; then \
		echo "Emptying local portraits bucket before Terraform destroy..."; \
		$(LOCAL_AWS) s3 rm "s3://$$bucket" --recursive --only-show-errors; \
	fi
	@terraform -chdir=$(TF_DIR) destroy -var-file=floci.tfvars -auto-approve -parallelism=1

e2e: ## Exercise the full local flow, then destroy local resources
	@AWS_DEFAULT_REGION="$(FLOCI_REGION)" AWS_ENDPOINT_URL="$(FLOCI_ENDPOINT)" bash e2e.sh

serve: ## Serve the local page (set API_URL=... to override its API)
	@api_url="$${API_URL:-$$(terraform -chdir=$(TF_DIR) output -raw api_endpoint)}"; \
	image_backend="$$(terraform -chdir=$(TF_DIR) output -raw image_backend 2>/dev/null || echo stub)"; \
	python3 serve.py --api-url "$$api_url" --image-backend "$$image_backend"

apply-bedrock: ## Enable real Bedrock inference in local Floci (set AWS_PROFILE; incurs model charges per upload)
	@$(MAKE) local-up
	@$(MAKE) package
	@$(MAKE) terraform-init
	@terraform -chdir=$(TF_DIR) validate
	@python3 apply_bedrock.py --profile "$(AWS_PROFILE)"

aws-target-check: ## Confirm profile and account ID match before AWS operations
	@test -f $(AWS_TFVARS) || { echo "copy aws.tfvars.example to aws.tfvars and set the account ID" >&2; exit 2; }
	@test "$$(sed -n 's/^deployment_target[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(AWS_TFVARS))" = aws || { echo 'set deployment_target = "aws" in aws.tfvars' >&2; exit 2; }
	@test -n "$${AWS_PROFILE:-}" || { echo "set AWS_PROFILE to an authenticated profile" >&2; exit 2; }
	@test "$(AWS_ACCOUNT_ID)" != REPLACE_WITH_12_DIGIT_ACCOUNT_ID && [[ "$(AWS_ACCOUNT_ID)" =~ ^[0-9]{12}$$ ]] || { echo "set aws_account_id in aws.tfvars" >&2; exit 2; }
	@actual="$$(aws --profile "$${AWS_PROFILE}" sts get-caller-identity --query Account --output text)"; \
	[[ "$$actual" == "$(AWS_ACCOUNT_ID)" ]] || { echo "AWS profile account $$actual does not match configured account $(AWS_ACCOUNT_ID)." >&2; exit 1; }
	@echo "AWS profile account matches $(AWS_ACCOUNT_ID)."

aws-plan: ## Show the AWS plan without applying it
	@$(MAKE) aws-target-check
	@$(MAKE) package
	@$(MAKE) aws-terraform-init
	@terraform -chdir=$(TF_DIR) validate
	@AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) plan -var-file=$(AWS_TFVARS)

aws-apply: ## Apply AWS infrastructure (Bedrock inference is invoked only by uploads)
	@$(MAKE) aws-target-check
	@$(MAKE) package
	@$(MAKE) aws-terraform-init
	@AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) apply -var-file=$(AWS_TFVARS)

aws-e2e: ## Deploy AWS stack and process IMAGE (set AWS_PROFILE and IMAGE; incurs Bedrock inference charges)
	@test -f "$${IMAGE:-}" || { echo "usage: make aws-e2e AWS_PROFILE=... IMAGE=path/to/photo.jpg" >&2; exit 2; }
	@$(MAKE) aws-target-check
	@$(MAKE) aws-apply AWS_PROFILE="$${AWS_PROFILE}"
	@python3 aws-e2e.py --image "$(IMAGE)" --prompt "$(JOB_PROMPT)"

aws-destroy: ## Destroy AWS resources after account and profile verification
	@$(MAKE) aws-target-check
	@$(MAKE) aws-terraform-init
	@AWS_PROFILE="$${AWS_PROFILE}" terraform -chdir=$(TF_DIR) destroy -var-file=$(AWS_TFVARS)

experiment: ## Run the direct Bedrock experiment (set IMAGE=path/to/photo.jpg)
	@test -n "$(IMAGE)" -a -f "$(IMAGE)" || { echo "usage: make experiment IMAGE=path/to/photo.jpg" >&2; exit 2; }
	@command -v uv >/dev/null && command -v aws >/dev/null || { echo "missing uv or AWS CLI" >&2; exit 1; }
	@mkdir -p output
	@uv run --with boto3 python3 experiment.py --profile "$(AWS_PROFILE)" --region "$(REGION)" --model-id "$(MODEL_ID)" --image "$(IMAGE)" --output "$(OUTPUT)" --prompt "$(PROMPT)" --strength "$(STRENGTH)"

fetch-sample: ## Download the sample portrait used by the model experiment
	@mkdir -p data
	@curl --fail --location --output data/portrait.jpg 'https://commons.wikimedia.org/wiki/Special:FilePath/Example_of_person_portrait.jpg'

clean: ## Remove experiment outputs and the generated Lambda archive
	@rm -rf output worker.zip
