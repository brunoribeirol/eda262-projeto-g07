locals {
  is_delivery_workspace = terraform.workspace == var.delivery_workspace

  # Delivery workspace -> exact mandated names. Any other workspace -> suffixed,
  # so parallel experiments never collide with the graded resources.
  name_suffix = local.is_delivery_workspace ? "" : "-${terraform.workspace}"

  # The principal running Terraform. For an assumed role, the session ARN
  # (arn:aws:sts::...:assumed-role/...) is resolved to the role ARN itself, which is
  # the only form Lake Formation accepts as an administrator.
  deployer_arn = data.aws_iam_session_context.current.issuer_arn
}

# Fails `plan` on the default workspace instead of silently provisioning a
# fourth, unnamed environment. Costs nothing: terraform_data holds no cloud resource.
resource "terraform_data" "workspace_guard" {
  input = terraform.workspace

  lifecycle {
    precondition {
      condition     = terraform.workspace != "default"
      error_message = "Refusing to run in the 'default' workspace. Run: terraform workspace new av2 (or select an existing one)."
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# ---------------------------------------------------------------------------
# Lake Formation account settings -- an account-level singleton, so it lives in
# the root module where it is visible, not buried in a child module.
#
# Two effects, both deliberate:
#   1. The deploying principal becomes the only data lake administrator. It runs
#      the pipeline (the only writer) and creates every catalog object.
#   2. create_database_default_permissions / create_table_default_permissions are
#      omitted, which CLEARS them. New databases and tables therefore do not get
#      the IAMAllowedPrincipals "Super" grant, so Lake Formation -- not IAM --
#      decides who reads each layer. With the AWS default left in place, any IAM
#      principal with glue:GetTable + s3:GetObject would bypass every grant below.
#
# Destroying this resource clears admins and defaults (verified in the provider
# source); scripts/part-2/destroy.sh then restores the settings captured before
# the first deploy, so the account is left as it was found.
# ---------------------------------------------------------------------------
resource "aws_lakeformation_data_lake_settings" "this" {
  admins = [local.deployer_arn]

  lifecycle {
    precondition {
      condition     = !endswith(data.aws_caller_identity.current.arn, ":root")
      error_message = "Deploy with an IAM user or role, not the root user: Lake Formation cannot use root as a data lake administrator."
    }
  }
}

module "data_lake" {
  source = "./modules/data-lake"

  name_prefix = var.name_prefix
  name_suffix = local.name_suffix

  pipeline_bytes_scanned_cutoff = var.pipeline_bytes_scanned_cutoff
  cost_target_bytes_per_query   = var.cost_target_bytes_per_query

  # Databases must be created AFTER the defaults are cleared; otherwise they are
  # born with the IAMAllowedPrincipals grant and Lake Formation is bypassed.
  # On destroy the order reverses: the settings are cleared last.
  depends_on = [aws_lakeformation_data_lake_settings.this]
}

module "governance" {
  source = "./modules/governance"

  name_prefix = var.name_prefix
  name_suffix = local.name_suffix

  layer_buckets         = module.data_lake.layer_buckets
  layer_databases       = module.data_lake.layer_databases
  athena_results_bucket = module.data_lake.athena_results_bucket

  personas                     = var.personas
  persona_bytes_scanned_cutoff = var.persona_bytes_scanned_cutoff
  business_question_sql        = module.data_lake.business_question_sql

  # No module-level depends_on: consuming module.data_lake outputs already orders every
  # grant after the databases, which come after the settings. A depends_on here would also
  # defer this module's data sources to apply time and blur the plan.
}
