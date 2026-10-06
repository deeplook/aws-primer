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
  allowed_account_ids         = var.deployment_target == "aws" && can(regex("^[0-9]{12}$", var.aws_account_id)) ? [var.aws_account_id] : null

  endpoints {
    apigatewayv2   = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    cloudwatchlogs = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    dynamodb       = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    iam            = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    lambda         = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    s3             = var.deployment_target == "floci" ? var.floci_endpoint_url : null
    sqs            = var.deployment_target == "floci" ? var.floci_endpoint_url : null
  }
}

locals {
  is_aws           = var.deployment_target == "aws"
  account_id       = local.is_aws ? var.aws_account_id : "000000000000"
  resource_prefix  = local.is_aws ? "aws-primer-${var.aws_account_id}-spike-3" : "aws-primer-spike-3"
  uploads_bucket   = "${local.resource_prefix}-portraits"
  jobs_table       = "${local.resource_prefix}-jobs"
  jobs_queue_name  = "${local.resource_prefix}-jobs"
  dlq_name         = "${local.resource_prefix}-jobs-dlq"
  api_name         = "${local.resource_prefix}-api"
  api_handler_name = "${local.resource_prefix}-api"
  worker_name      = "${local.resource_prefix}-worker"
  frontend_origin  = local.is_aws ? "https://${aws_cloudfront_distribution.site[0].domain_name}" : "http://localhost:8080"
  runtime_endpoint = local.is_aws ? "" : var.lambda_endpoint_url
  presign_endpoint = local.is_aws ? "" : var.floci_presign_endpoint_url
  api_endpoint     = local.is_aws ? aws_apigatewayv2_api.api.api_endpoint : "http://${aws_apigatewayv2_api.api.id}.execute-api.${var.aws_region}.localhost${trimprefix(var.floci_endpoint_url, "http://localhost")}"
}

resource "aws_s3_bucket" "portraits" {
  bucket        = local.uploads_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "portraits" {
  bucket = aws_s3_bucket.portraits.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "portraits" {
  bucket                  = aws_s3_bucket.portraits.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "portraits" {
  bucket = aws_s3_bucket.portraits.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "portraits" {
  bucket = aws_s3_bucket.portraits.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "HEAD"]
    allowed_origins = [local.frontend_origin]
    expose_headers  = ["ETag"]
    max_age_seconds = 300
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "portraits" {
  bucket = aws_s3_bucket.portraits.id

  rule {
    id     = "expire-portrait-objects"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = var.image_retention_days
    }
  }
}

resource "aws_dynamodb_table" "jobs" {
  name         = local.jobs_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_sqs_queue" "jobs_dlq" {
  name                      = local.dlq_name
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "jobs" {
  name                       = local.jobs_queue_name
  visibility_timeout_seconds = 1800
  message_retention_seconds  = 86400
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "jobs" {
  queue_url = aws_sqs_queue.jobs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowPortraitBucketNotifications"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.jobs.arn
      Condition = {
        ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.portraits.arn }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "portraits" {
  bucket = aws_s3_bucket.portraits.id

  queue {
    queue_arn     = aws_sqs_queue.jobs.arn
    events        = ["s3:ObjectCreated:Put"]
    filter_prefix = "uploads/"
    filter_suffix = "/input"
  }

  depends_on = [aws_sqs_queue_policy.jobs]
}

resource "aws_iam_role" "api" {
  name = "${local.resource_prefix}-api-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role" "worker" {
  name = "${local.resource_prefix}-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.api_handler_name}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${local.worker_name}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.api_name}"
  retention_in_days = 7
}

resource "aws_iam_role_policy" "api" {
  name = "${local.resource_prefix}-api"
  role = aws_iam_role.api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["${aws_s3_bucket.portraits.arn}/uploads/*", "${aws_s3_bucket.portraits.arn}/results/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.api.arn}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "worker" {
  name = "${local.resource_prefix}-worker"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.portraits.arn}/uploads/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.portraits.arn}/results/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.worker.arn}:*"
      }
      ], local.is_aws ? [{
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}"
    }] : [])
  })
}

resource "aws_lambda_function" "api" {
  function_name    = local.api_handler_name
  role             = aws_iam_role.api.arn
  filename         = "${path.module}/worker.zip"
  source_code_hash = filebase64sha256("${path.module}/worker.zip")
  handler          = "handler.api_handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 256

  environment {
    variables = {
      JOBS_TABLE                  = aws_dynamodb_table.jobs.name
      PORTRAITS_BUCKET            = aws_s3_bucket.portraits.bucket
      S3_ENDPOINT_URL             = local.runtime_endpoint
      S3_PRESIGN_ENDPOINT_URL     = local.presign_endpoint
      FRONTEND_ORIGIN             = local.frontend_origin
      JOB_RETENTION_SECONDS       = tostring(var.image_retention_days * 86400)
      UPLOAD_URL_EXPIRY_SECONDS   = "900"
      DOWNLOAD_URL_EXPIRY_SECONDS = "300"
      MAX_IMAGE_BYTES             = "10485760"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.api.name
  }
}

resource "aws_lambda_function" "worker" {
  function_name                  = local.worker_name
  role                           = aws_iam_role.worker.arn
  filename                       = "${path.module}/worker.zip"
  source_code_hash               = filebase64sha256("${path.module}/worker.zip")
  handler                        = "handler.worker_handler"
  runtime                        = "python3.12"
  timeout                        = 300
  memory_size                    = 1024
  reserved_concurrent_executions = local.is_aws ? 1 : -1

  environment {
    variables = {
      JOBS_TABLE                = aws_dynamodb_table.jobs.name
      PORTRAITS_BUCKET          = aws_s3_bucket.portraits.bucket
      IMAGE_BACKEND             = local.is_aws ? "bedrock" : var.local_image_backend
      BEDROCK_MODEL_ID          = var.bedrock_model_id
      BEDROCK_REGION            = local.is_aws ? var.aws_region : var.bedrock_region
      BEDROCK_ACCESS_KEY_ID     = local.is_aws ? "" : var.bedrock_access_key_id
      BEDROCK_SECRET_ACCESS_KEY = local.is_aws ? "" : var.bedrock_secret_access_key
      BEDROCK_SESSION_TOKEN     = local.is_aws ? "" : var.bedrock_session_token
      IMAGE_STRENGTH            = tostring(var.image_strength)
      S3_ENDPOINT_URL           = local.runtime_endpoint
      MAX_IMAGE_BYTES           = "10485760"
      MAX_RECEIVE_COUNT         = "3"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.worker.name
  }
}

resource "aws_lambda_event_source_mapping" "jobs" {
  event_source_arn                   = aws_sqs_queue.jobs.arn
  function_name                      = aws_lambda_function.worker.arn
  batch_size                         = 1
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true
  maximum_batching_window_in_seconds = 0
}

resource "aws_apigatewayv2_api" "api" {
  name          = local.api_name
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = [local.frontend_origin]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "create_job" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /jobs"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_route" "get_job" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /jobs/{job_id}"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_stage" "api" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  route_settings {
    route_key              = "POST /jobs"
    throttling_burst_limit = 5
    throttling_rate_limit  = 1
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId   = "$context.requestId"
      routeKey    = "$context.routeKey"
      status      = "$context.status"
      sourceIp    = "$context.identity.sourceIp"
      requestTime = "$context.requestTime"
    })
  }
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

locals {
  site_files = fileset(path.module, "site/*")
}

resource "aws_s3_bucket" "site" {
  count         = local.is_aws ? 1 : 0
  bucket        = "${local.resource_prefix}-site"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  count  = local.is_aws ? 1 : 0
  bucket = aws_s3_bucket.site[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  count                   = local.is_aws ? 1 : 0
  bucket                  = aws_s3_bucket.site[0].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "site" {
  count  = local.is_aws ? 1 : 0
  bucket = aws_s3_bucket.site[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontReadOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site[0].arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn"     = aws_cloudfront_distribution.site[0].arn
          "AWS:SourceAccount" = var.aws_account_id
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

resource "aws_cloudfront_origin_access_control" "site" {
  count                             = local.is_aws ? 1 : 0
  name                              = "${local.resource_prefix}-site-oac"
  description                       = "Private S3 origin for the portrait studio"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  count               = local.is_aws ? 1 : 0
  enabled             = true
  comment             = "${local.resource_prefix} website"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.site[0].bucket_regional_domain_name
    origin_id                = "${local.resource_prefix}-site-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site[0].id
  }

  default_cache_behavior {
    target_origin_id       = "${local.resource_prefix}-site-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 60
    max_ttl     = 300
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_object" "site_files" {
  for_each = local.is_aws ? toset(local.site_files) : toset([])

  bucket       = aws_s3_bucket.site[0].id
  key          = basename(each.value)
  source       = "${path.module}/${each.value}"
  etag         = filemd5("${path.module}/${each.value}")
  content_type = lookup({ html = "text/html; charset=utf-8", css = "text/css; charset=utf-8", js = "text/javascript; charset=utf-8" }, reverse(split(".", each.value))[0], "application/octet-stream")
}

resource "aws_s3_object" "site_config" {
  count        = local.is_aws ? 1 : 0
  bucket       = aws_s3_bucket.site[0].id
  key          = "config.js"
  content      = "window.SPIKE_CONFIG = ${jsonencode({ apiBaseUrl = local.api_endpoint, imageBackend = "bedrock" })};"
  content_type = "text/javascript; charset=utf-8"
}

output "api_endpoint" {
  value = local.api_endpoint
}

output "image_backend" {
  value = local.is_aws ? "bedrock" : var.local_image_backend
}

output "uploads_bucket_name" {
  value = aws_s3_bucket.portraits.bucket
}

output "jobs_table_name" {
  value = aws_dynamodb_table.jobs.name
}

output "jobs_queue_url" {
  value = aws_sqs_queue.jobs.url
}

output "jobs_dlq_url" {
  value = aws_sqs_queue.jobs_dlq.url
}

output "website_url" {
  value = local.is_aws ? "https://${aws_cloudfront_distribution.site[0].domain_name}" : "http://localhost:8080"
}
