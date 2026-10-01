terraform {
  required_version = ">= 1.6.0"

  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  access_key                  = var.deployment_target == "floci" ? "test" : null
  secret_key                  = var.deployment_target == "floci" ? "test" : null
  skip_credentials_validation = var.deployment_target == "floci"
  skip_metadata_api_check     = var.deployment_target == "floci"
  skip_requesting_account_id  = var.deployment_target == "floci"
  s3_use_path_style           = var.deployment_target == "floci"
  allowed_account_ids         = var.deployment_target == "aws" && length(var.aws_account_id) == 12 ? [var.aws_account_id] : null

  endpoints {
    iam      = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    lambda   = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    s3       = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    sqs      = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    dynamodb = var.deployment_target == "floci" ? var.floci_endpoint_url : null
  }
}

locals {
  aws_account_id  = var.deployment_target == "floci" ? "000000000000" : var.aws_account_id
  resource_prefix = var.deployment_target == "floci" ? "aws-primer-spike-1" : "aws-primer-${var.aws_account_id}-spike-1"
}

resource "aws_iam_role" "worker" {
  name = "${local.resource_prefix}-worker"

  lifecycle {
    precondition {
      condition     = var.deployment_target != "aws" || can(regex("^[0-9]{12}$", var.aws_account_id))
      error_message = "AWS deployments require aws_account_id to be the intended 12-digit account ID."
    }
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "worker" {
  name = "${local.resource_prefix}-worker"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.uploads.arn}/processed/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.processed.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${local.aws_account_id}:log-group:/aws/lambda/${local.resource_prefix}-worker:*"
      }
    ]
  })
}

resource "aws_s3_bucket" "uploads" {
  bucket        = var.deployment_target == "floci" ? "${local.resource_prefix}-uploads" : null
  bucket_prefix = var.deployment_target == "aws" ? "${local.resource_prefix}-uploads-" : null
  force_destroy = var.deployment_target == "floci"
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${local.resource_prefix}-jobs"
  visibility_timeout_seconds = 60
}

resource "aws_dynamodb_table" "processed" {
  name         = "${local.resource_prefix}-processed"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "message_id"

  attribute {
    name = "message_id"
    type = "S"
  }
}

resource "aws_lambda_function" "worker" {
  function_name    = "${local.resource_prefix}-worker"
  role             = aws_iam_role.worker.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = "worker.zip"
  source_code_hash = filebase64sha256("worker.zip")
  timeout          = 10

  environment {
    variables = merge({
      OUTPUT_BUCKET = aws_s3_bucket.uploads.bucket
      TABLE_NAME    = aws_dynamodb_table.processed.name
      }, var.deployment_target == "floci" ? {
      AWS_ENDPOINT_URL = var.lambda_endpoint_url
    } : {})
  }

  depends_on = [aws_iam_role_policy.worker]
}

resource "aws_lambda_event_source_mapping" "jobs" {
  event_source_arn = aws_sqs_queue.jobs.arn
  function_name    = aws_lambda_function.worker.arn
  batch_size       = 1
  enabled          = true
}

output "queue_url" {
  value = aws_sqs_queue.jobs.url
}

output "uploads_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}

output "processed_table_name" {
  value = aws_dynamodb_table.processed.name
}
