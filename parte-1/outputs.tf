output "workspace" {
  description = "Terraform workspace this state belongs to."
  value       = terraform.workspace
}

output "is_delivery_workspace" {
  description = "True when resource names match the course guide verbatim (no suffix)."
  value       = local.is_delivery_workspace
}

output "aws_region" {
  description = "Region the lake is deployed in."
  value       = var.aws_region
}

output "raw_bucket" {
  description = "Raw layer bucket."
  value       = module.data_lake.raw_bucket
}

output "trusted_bucket" {
  description = "Trusted layer bucket."
  value       = module.data_lake.trusted_bucket
}

output "athena_results_bucket" {
  description = "Athena query results bucket."
  value       = module.data_lake.athena_results_bucket
}

output "raw_uri" {
  description = "S3 URI for the raw CISA KEV payload."
  value       = module.data_lake.raw_uri
}

output "trusted_table_uri" {
  description = "S3 URI backing the trusted table."
  value       = module.data_lake.trusted_table_uri
}

output "glue_database" {
  description = "Glue Data Catalog database."
  value       = module.data_lake.glue_database
}

output "trusted_table" {
  description = "Trusted table name."
  value       = module.data_lake.trusted_table
}

output "trusted_table_grain" {
  description = "Declared grain of the trusted table."
  value       = module.data_lake.trusted_table_grain
}

output "athena_workgroup" {
  description = "Athena WorkGroup all graded queries run in."
  value       = module.data_lake.athena_workgroup
}

output "bytes_scanned_cutoff_per_query" {
  description = "WorkGroup-enforced per-query scan cap, in bytes."
  value       = module.data_lake.bytes_scanned_cutoff_per_query
}

output "business_question_named_query_id" {
  description = "Athena named-query ID executed by scripts/run_query.sh."
  value       = module.data_lake.business_question_named_query_id
}

output "grain_check_named_query_id" {
  description = "Athena named-query ID proving the declared grain."
  value       = module.data_lake.grain_check_named_query_id
}

output "business_question_sql" {
  description = "SQL of the graded business question."
  value       = module.data_lake.business_question_sql
}
