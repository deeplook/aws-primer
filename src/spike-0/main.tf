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
    s3 = var.deployment_target == "floci" ? var.floci_endpoint_url : null
  }
}

locals {
  bucket_name = var.deployment_target == "floci" ? "aws-primer-spike-0-site" : "aws-primer-${var.aws_account_id}-spike-0-site"
}

resource "aws_s3_bucket" "website" {
  bucket        = local.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "website" {
  bucket = aws_s3_bucket.website.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "website" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadWebsiteFiles"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.website.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.website]
}

resource "aws_s3_bucket_website_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  index_document {
    suffix = "index.html"
  }
}

locals {
  site_files = fileset(path.module, "site/*")
}

resource "aws_s3_object" "site" {
  for_each = local.site_files

  bucket = aws_s3_bucket.website.id
  key    = trimprefix(each.value, "site/")
  source = "${path.module}/${each.value}"
  etag   = filemd5("${path.module}/${each.value}")
  content_type = lookup({
    "html" = "text/html; charset=utf-8"
    "css"  = "text/css; charset=utf-8"
    "js"   = "text/javascript; charset=utf-8"
  }, reverse(split(".", each.value))[0], "application/octet-stream")

  depends_on = [aws_s3_bucket_policy.website]
}

output "bucket_name" {
  value = aws_s3_bucket.website.bucket
}

output "website_url" {
  value = var.deployment_target == "floci" ? "http://${aws_s3_bucket.website.bucket}.s3-website-${var.aws_region}.localhost:4566" : "http://${aws_s3_bucket_website_configuration.website.website_endpoint}"
}
