variable "deployment_target" {
  description = "Deployment target: local Floci or AWS."
  type        = string
  default     = "floci"

  validation {
    condition     = contains(["floci", "aws"], var.deployment_target)
    error_message = "deployment_target must be either floci or aws."
  }
}

variable "aws_region" {
  description = "AWS Region for the stack and Bedrock image model."
  type        = string
  default     = "us-west-2"
}

variable "aws_account_id" {
  description = "Expected 12-digit account ID used to guard AWS deployments and name resources."
  type        = string
  default     = ""

  validation {
    condition     = var.aws_account_id == "" || can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be empty or a 12-digit account ID."
  }
}

variable "floci_endpoint_url" {
  description = "Floci endpoint as seen from the host running Terraform and AWS CLI."
  type        = string
  default     = "http://localhost:4567"
}

variable "lambda_endpoint_url" {
  description = "Floci endpoint as seen from Lambda runtime containers."
  type        = string
  default     = "http://floci:4566"
}

variable "floci_presign_endpoint_url" {
  description = "Floci endpoint host that browsers use for presigned S3 URLs."
  type        = string
  default     = "http://localhost:4567"
}

variable "bedrock_model_id" {
  description = "Bedrock image-to-image model invoked by the worker."
  type        = string
  default     = "stability.stable-image-ultra-v1:1"
}

variable "local_image_backend" {
  description = "Image backend for a local Floci deployment: stub (free) or bedrock (real inference)."
  type        = string
  default     = "stub"

  validation {
    condition     = contains(["stub", "bedrock"], var.local_image_backend)
    error_message = "local_image_backend must be either stub or bedrock."
  }
}

variable "bedrock_region" {
  description = "AWS Region used for Bedrock inference in the local Floci deployment."
  type        = string
  default     = "us-west-2"
}

variable "bedrock_access_key_id" {
  description = "Temporary AWS credentials passed to a local Floci Lambda for Bedrock calls."
  type        = string
  default     = ""
  sensitive   = true
}

variable "bedrock_secret_access_key" {
  description = "Temporary AWS credentials passed to a local Floci Lambda for Bedrock calls."
  type        = string
  default     = ""
  sensitive   = true
}

variable "bedrock_session_token" {
  description = "Temporary AWS credentials passed to a local Floci Lambda for Bedrock calls."
  type        = string
  default     = ""
  sensitive   = true
}

variable "image_strength" {
  description = "How strongly Stable Image Ultra follows its prompt (0.0 to 1.0)."
  type        = number
  default     = 0.75

  validation {
    condition     = var.image_strength >= 0 && var.image_strength <= 1
    error_message = "image_strength must be between 0.0 and 1.0."
  }
}

variable "image_retention_days" {
  description = "Days before S3 inputs/results and DynamoDB jobs expire."
  type        = number
  default     = 1

  validation {
    condition     = var.image_retention_days >= 1
    error_message = "image_retention_days must be at least one day."
  }
}
