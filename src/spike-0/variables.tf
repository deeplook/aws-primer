variable "aws_region" {
  description = "AWS Region for the website bucket."
  type        = string
  default     = "us-east-1"
}

variable "deployment_target" {
  description = "Where to deploy this spike: local Floci or AWS."
  type        = string
  default     = "floci"

  validation {
    condition     = contains(["floci", "aws"], var.deployment_target)
    error_message = "deployment_target must be either floci or aws."
  }
}

variable "aws_account_id" {
  description = "Expected 12-digit AWS account ID; included in the AWS bucket name."
  type        = string
  default     = ""

  validation {
    condition     = var.aws_account_id == "" || can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be empty or a 12-digit AWS account ID."
  }
}

variable "floci_endpoint_url" {
  description = "Floci S3 endpoint as seen from the host running Terraform and AWS CLI."
  type        = string
  default     = "http://localhost:4566"
}
