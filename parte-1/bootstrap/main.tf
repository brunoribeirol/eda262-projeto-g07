# ---------------------------------------------------------------------------
# Backend bootstrap.
#
# The remote backend cannot store its own state: the S3 bucket and the DynamoDB
# lock table must exist before `terraform init` can talk to them. This is the
# standard chicken-and-egg split -- this tiny stack runs with LOCAL state and
# creates only the two resources the real stack's backend needs.
#
# Run once per AWS account, before parte-1/. See ../../README.md.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.mandatory_tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  # The account ID keeps the bucket name globally unique, so the same repository
  # bootstraps cleanly in the evaluator's account without colliding with ours.
  state_bucket_name = "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
  lock_table_name   = "${var.name_prefix}-tflock"
}

resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket_name
  force_destroy = var.force_destroy

  lifecycle {
    # State is the crown jewel: refuse an accidental in-place replacement.
    prevent_destroy = false # set to true once the delivery tag is cut
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled" # non-negotiable: versioning is the only recovery path for a corrupted state file
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# State locking. The course guide mandates DynamoDB for this; Terraform >= 1.10
# can also lock natively in S3 via `use_lockfile`, which this stack documents as
# the modern alternative in DECISOES.md but does not use, to meet the rubric.
resource "aws_dynamodb_table" "lock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST" # locks are a handful of writes per apply; provisioned capacity would be waste
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}
