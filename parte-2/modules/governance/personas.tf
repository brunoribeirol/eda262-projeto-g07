# ---------------------------------------------------------------------------
# Personas: one IAM role + one isolated Athena WorkGroup per access profile.
#
# The IAM policy is identical across personas apart from their own WorkGroup and
# results prefix. That is deliberate: IAM lets every persona *ask* for any layer,
# and Lake Formation alone decides what it gets. A denied query therefore proves
# the Lake Formation grant is doing the work -- not an IAM difference.
#
# Separate WorkGroups follow the AWS guidance for Athena with Lake Formation: the
# results location and the query history cannot be governed by Lake Formation,
# so each persona writes results to its own prefix and sees only its own history.
# Otherwise a business user could read the CSV of a data engineer's raw query.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region # provider >= 6 exposes `region`; `name` is deprecated
  partition  = data.aws_partition.current.partition

  # One entry per (persona, layer) the persona may read.
  grants = merge([
    for persona, cfg in var.personas : {
      for layer in cfg.layers : "${persona}/${layer}" => { persona = persona, layer = layer }
    }
  ]...)

  workgroup_names = {
    for persona in keys(var.personas) : persona => "${var.name_prefix}-wg-${persona}${var.name_suffix}"
  }

  glue_arn_prefix = "arn:${local.partition}:glue:${local.region}:${local.account_id}"
}

resource "aws_iam_role" "persona" {
  for_each = var.personas

  name        = "${var.name_prefix}-${each.key}${var.name_suffix}"
  description = each.value.description

  # Any principal of this account whose own IAM policy allows sts:AssumeRole on this
  # role (an administrator, the acceptance script) can act as the persona. No
  # cross-account trust.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy" "persona" {
  for_each = var.personas

  name = "athena-through-lake-formation"
  role = aws_iam_role.persona[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "QueryInOwnWorkGroupOnly"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:StopQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:GetQueryResultsStream",
          "athena:BatchGetQueryExecution",
          "athena:ListQueryExecutions",
          "athena:GetWorkGroup",
          "athena:GetNamedQuery",
          "athena:BatchGetNamedQuery",
          "athena:ListNamedQueries",
        ]
        Resource = "arn:${local.partition}:athena:${local.region}:${local.account_id}:workgroup/${local.workgroup_names[each.key]}"
      },
      {
        Sid      = "ResolveDefaultDataCatalog"
        Effect   = "Allow"
        Action   = ["athena:GetDataCatalog"]
        Resource = "arn:${local.partition}:athena:${local.region}:${local.account_id}:datacatalog/AwsDataCatalog"
      },
      {
        # Metadata reads on the lake databases. Lake Formation filters the answer:
        # a table the persona has no grant on is not even described.
        Sid    = "ReadLakeCatalogMetadata"
        Effect = "Allow"
        Action = [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition",
        ]
        Resource = concat(
          ["${local.glue_arn_prefix}:catalog", "${local.glue_arn_prefix}:database/default"],
          [for db in values(var.layer_databases) : "${local.glue_arn_prefix}:database/${db}"],
          [for db in values(var.layer_databases) : "${local.glue_arn_prefix}:table/${db}/*"],
        )
      },
      {
        Sid      = "LakeFormationCredentialVending"
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*" # GetDataAccess does not support resource-level permissions
      },
      {
        Sid    = "OwnQueryResultsObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${var.athena_results_bucket.arn}/${each.key}/*"
      },
      {
        Sid      = "OwnQueryResultsPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.athena_results_bucket.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${each.key}/*"] }
        }
      },
      {
        Sid      = "ResultsBucketLocation"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = var.athena_results_bucket.arn
      },
    ]
  })
}

resource "aws_athena_workgroup" "persona" {
  for_each = var.personas

  name        = local.workgroup_names[each.key]
  description = "EDA262 g07 Part 2 -- ${each.key}: ${each.value.description}"
  state       = "ENABLED"

  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.persona_bytes_scanned_cutoff

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${var.athena_results_bucket.id}/${each.key}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# The business question, ready to run in the WorkGroup of every persona allowed to
# read the refined layer -- the same SQL the pipeline measures.
resource "aws_athena_named_query" "business_question" {
  for_each = { for persona, cfg in var.personas : persona => cfg if contains(cfg.layers, "refined") }

  name        = "${var.name_prefix}-business-question${var.name_suffix}"
  description = "Part 2 business question (refined layer). Params: first day, last day of the EPSS window."
  workgroup   = aws_athena_workgroup.persona[each.key].id
  database    = var.layer_databases["refined"]
  query       = var.business_question_sql
}
