output "layer_buckets" {
  description = "Lake layer buckets (raw, trusted, refined): name and ARN. Consumed by the governance module."
  value = {
    for layer in local.layers : layer => {
      id  = aws_s3_bucket.this[layer].id
      arn = aws_s3_bucket.this[layer].arn
    }
  }
}

output "athena_results_bucket" {
  description = "Bucket receiving Athena query results (one prefix per WorkGroup)."
  value = {
    id  = aws_s3_bucket.this["athena_results"].id
    arn = aws_s3_bucket.this["athena_results"].arn
  }
}

output "layer_databases" {
  description = "Glue database name of each layer."
  value       = { for layer, db in aws_glue_catalog_database.layer : layer => db.name }
}

output "tables" {
  description = "Every catalog table: database, name, declared grain and S3 location."
  value = {
    for key, t in aws_glue_catalog_table.this : key => {
      database = t.database_name
      name     = t.name
      grain    = t.parameters["grain"]
      location = local.table_locations[key]
    }
  }
}

output "kev_catalog_archive_uri" {
  description = "S3 URI under the raw bucket where the KEV source document is archived byte-for-byte (not a table)."
  value       = "s3://${local.bucket_names.raw}/kev_catalog/"
}

output "pipeline_workgroup" {
  description = "Athena WorkGroup the pipeline and the cost comparison run in."
  value       = aws_athena_workgroup.pipeline.name
}

output "pipeline_bytes_scanned_cutoff" {
  description = "Per-query scan cap enforced by the pipeline WorkGroup, in bytes."
  value       = var.pipeline_bytes_scanned_cutoff
}

output "cost_target_bytes_per_query" {
  description = "Declared cost target for the business question, in bytes scanned per execution."
  value       = var.cost_target_bytes_per_query
}

output "named_query_ids" {
  description = "Athena named-query IDs, keyed by query name (business-question, grain-check, ...)."
  value       = { for key, q in aws_athena_named_query.analytics : key => q.id }
}

output "business_question_sql" {
  description = "Rendered SQL of the business question, republished by the governance module in persona WorkGroups."
  value       = aws_athena_named_query.analytics["business-question"].query
}
