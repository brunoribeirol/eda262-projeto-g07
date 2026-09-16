output "raw_bucket" {
  description = "Name of the raw layer bucket holding the untouched CISA KEV payload."
  value       = aws_s3_bucket.this["raw"].id
}

output "trusted_bucket" {
  description = "Name of the trusted layer bucket backing the Glue table."
  value       = aws_s3_bucket.this["trusted"].id
}

output "athena_results_bucket" {
  description = "Name of the bucket receiving Athena query results."
  value       = aws_s3_bucket.this["athena_results"].id
}

output "raw_uri" {
  description = "S3 URI the ingestion script writes the raw payload to."
  value       = local.raw_location
}

output "trusted_table_uri" {
  description = "S3 URI backing the trusted table."
  value       = local.trusted_table_location
}

output "glue_database" {
  description = "Glue Data Catalog database name."
  value       = aws_glue_catalog_database.lake.name
}

output "trusted_table" {
  description = "Trusted table name."
  value       = aws_glue_catalog_table.trusted.name
}

output "trusted_table_grain" {
  description = "Declared grain of the trusted table."
  value       = aws_glue_catalog_table.trusted.parameters["grain"]
}

output "athena_workgroup" {
  description = "Athena WorkGroup name. All graded queries must run inside it."
  value       = aws_athena_workgroup.this.name
}

output "bytes_scanned_cutoff_per_query" {
  description = "Per-query scan cap enforced by the WorkGroup, in bytes."
  value       = var.bytes_scanned_cutoff_per_query
}

output "business_question_named_query_id" {
  description = "Athena named-query ID for the graded business question."
  value       = aws_athena_named_query.business_question.id
}

output "grain_check_named_query_id" {
  description = "Athena named-query ID for the grain assertion."
  value       = aws_athena_named_query.grain_check.id
}

output "business_question_sql" {
  description = "SQL of the graded business question, for documentation and evidence capture."
  value       = local.business_question_sql
}
