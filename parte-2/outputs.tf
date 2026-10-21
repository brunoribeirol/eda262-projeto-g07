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

output "lakeformation_admin" {
  description = "Principal registered as the only Lake Formation data lake administrator (the pipeline)."
  value       = local.deployer_arn
}

output "raw_bucket" {
  description = "Raw layer bucket."
  value       = module.data_lake.layer_buckets["raw"].id
}

output "trusted_bucket" {
  description = "Trusted layer bucket."
  value       = module.data_lake.layer_buckets["trusted"].id
}

output "refined_bucket" {
  description = "Refined layer bucket."
  value       = module.data_lake.layer_buckets["refined"].id
}

output "athena_results_bucket" {
  description = "Athena query results bucket."
  value       = module.data_lake.athena_results_bucket.id
}

output "raw_db" {
  description = "Glue database of the raw layer."
  value       = module.data_lake.layer_databases["raw"]
}

output "trusted_db" {
  description = "Glue database of the trusted layer."
  value       = module.data_lake.layer_databases["trusted"]
}

output "refined_db" {
  description = "Glue database of the refined layer."
  value       = module.data_lake.layer_databases["refined"]
}

output "tables" {
  description = "Every catalog table: database, name, declared grain and S3 location."
  value       = module.data_lake.tables
}

output "kev_catalog_archive_uri" {
  description = "Where the KEV source document is archived byte-for-byte."
  value       = module.data_lake.kev_catalog_archive_uri
}

output "pipeline_workgroup" {
  description = "Athena WorkGroup the pipeline and the cost comparison run in."
  value       = module.data_lake.pipeline_workgroup
}

output "cost_target_bytes_per_query" {
  description = "Declared cost target for the business question, in bytes scanned per execution."
  value       = module.data_lake.cost_target_bytes_per_query
}

output "named_query_ids" {
  description = "Athena named-query IDs executed by scripts/part-2/run_query.sh."
  value       = module.data_lake.named_query_ids
}

output "personas" {
  description = "Per persona: IAM role ARN, Athena WorkGroup and readable layers."
  value       = module.governance.personas
}

output "access_matrix" {
  description = "Expected Lake Formation outcome of every (persona, layer) read."
  value       = module.governance.access_matrix
}

output "registered_locations" {
  description = "S3 locations registered with Lake Formation."
  value       = module.governance.registered_locations
}

output "lakeformation_data_access_role_arn" {
  description = "Role Lake Formation assumes to read the registered buckets."
  value       = module.governance.lakeformation_data_access_role_arn
}
