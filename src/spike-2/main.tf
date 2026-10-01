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
    dynamodb = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    events   = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    iam      = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    lambda   = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    sfn      = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    sqs      = var.deployment_target == "floci" ? var.floci_endpoint_url : null
  }
}

locals {
  aws_account_id  = var.deployment_target == "floci" ? "000000000000" : var.aws_account_id
  resource_prefix = var.deployment_target == "floci" ? "aws-primer-spike-2" : "aws-primer-${var.aws_account_id}-spike-2"
}

resource "aws_dynamodb_table" "orders" {
  name         = "${local.resource_prefix}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }
}

resource "aws_iam_role" "processor" {
  name = "${local.resource_prefix}-processor"

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

resource "aws_iam_role_policy" "processor" {
  name = "${local.resource_prefix}-processor"
  role = aws_iam_role.processor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.orders.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${local.aws_account_id}:log-group:/aws/lambda/${local.resource_prefix}-process-order:*"
      }
    ]
  })
}

resource "aws_iam_role" "workflow_starter" {
  name = "${local.resource_prefix}-workflow-starter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "workflow_starter" {
  name = "${local.resource_prefix}-workflow-starter"
  role = aws_iam_role.workflow_starter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["states:StartExecution"]
        # Floci evaluates StartExecution against "*"; AWS gets the exact state machine ARN.
        Resource = var.deployment_target == "floci" ? "*" : aws_sfn_state_machine.order_workflow.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${local.aws_account_id}:log-group:/aws/lambda/${local.resource_prefix}-start-workflow:*"
      }
    ]
  })
}

resource "aws_lambda_function" "process_order" {
  function_name    = "${local.resource_prefix}-process-order"
  role             = aws_iam_role.processor.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = "worker.zip"
  source_code_hash = filebase64sha256("worker.zip")
  timeout          = 10

  environment {
    variables = merge({
      TABLE_NAME = aws_dynamodb_table.orders.name
      }, var.deployment_target == "floci" ? {
      AWS_ENDPOINT_URL = var.lambda_endpoint_url
    } : {})
  }

  depends_on = [aws_iam_role_policy.processor]
}

resource "aws_lambda_function" "start_workflow" {
  function_name    = "${local.resource_prefix}-start-workflow"
  role             = aws_iam_role.workflow_starter.arn
  runtime          = "python3.12"
  handler          = "handler.starter"
  filename         = "worker.zip"
  source_code_hash = filebase64sha256("worker.zip")
  timeout          = 10

  environment {
    variables = merge({
      STATE_MACHINE_ARN = aws_sfn_state_machine.order_workflow.arn
      }, var.deployment_target == "floci" ? {
      AWS_ENDPOINT_URL = var.lambda_endpoint_url
    } : {})
  }

  depends_on = [aws_iam_role_policy.workflow_starter]
}

resource "aws_iam_role" "workflow" {
  name = "${local.resource_prefix}-workflow"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "workflow" {
  name = "${local.resource_prefix}-workflow"
  role = aws_iam_role.workflow.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.process_order.arn, "${aws_lambda_function.process_order.arn}:*"]
    }]
  })
}

resource "aws_sfn_state_machine" "order_workflow" {
  name     = "${local.resource_prefix}-order-workflow"
  role_arn = aws_iam_role.workflow.arn
  type     = "STANDARD"

  definition = jsonencode({
    StartAt        = "ProcessOrder"
    TimeoutSeconds = 60
    States = {
      ProcessOrder = {
        Type           = "Task"
        Resource       = "arn:aws:states:::lambda:invoke"
        TimeoutSeconds = 20
        Parameters = {
          FunctionName = aws_lambda_function.process_order.arn
          "Payload.$"  = "$"
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 1
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        End = true
      }
    }
  })

  depends_on = [aws_iam_role_policy.workflow]
}

resource "aws_sqs_queue" "delivery_failures" {
  name = "${local.resource_prefix}-event-delivery-failures"
}

resource "aws_sqs_queue_policy" "delivery_failures" {
  queue_url = aws_sqs_queue.delivery_failures.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeDeliveryFailures"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.delivery_failures.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.order_placed.arn } }
    }]
  })
}

resource "aws_iam_role" "eventbridge" {
  count = var.deployment_target == "floci" ? 1 : 0

  name = "${local.resource_prefix}-eventbridge"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge" {
  count = var.deployment_target == "floci" ? 1 : 0

  name = "${local.resource_prefix}-eventbridge"
  role = aws_iam_role.eventbridge[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.start_workflow.arn
    }]
  })
}

resource "aws_cloudwatch_event_bus" "orders" {
  name = "${local.resource_prefix}-orders"
}

resource "aws_cloudwatch_event_rule" "order_placed" {
  name           = "${local.resource_prefix}-order-placed"
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  event_pattern = jsonencode({
    source        = ["aws-primer.orders"]
    "detail-type" = ["OrderPlaced"]
  })
}

resource "aws_cloudwatch_event_target" "order_workflow" {
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  rule           = aws_cloudwatch_event_rule.order_placed.name
  target_id      = "order-workflow"
  arn            = aws_lambda_function.start_workflow.arn
  role_arn       = var.deployment_target == "floci" ? aws_iam_role.eventbridge[0].arn : null

  dead_letter_config {
    arn = aws_sqs_queue.delivery_failures.arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }

  depends_on = [aws_iam_role_policy.eventbridge, aws_sqs_queue_policy.delivery_failures, aws_lambda_permission.eventbridge]
}

# AWS Lambda targets use a Lambda resource policy; Floci uses the local IAM role above.
resource "aws_lambda_permission" "eventbridge" {
  count = var.deployment_target == "aws" ? 1 : 0

  statement_id  = "AllowEventBridgeOrderRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_workflow.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.order_placed.arn
}

output "event_bus_name" {
  value = aws_cloudwatch_event_bus.orders.name
}

output "orders_table_name" {
  value = aws_dynamodb_table.orders.name
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.order_workflow.arn
}
