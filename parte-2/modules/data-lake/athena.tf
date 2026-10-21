# ---------------------------------------------------------------------------
# Athena: the pipeline WorkGroup and the analytical queries, published as named
# queries. Persona WorkGroups (one per access profile) live in the governance
# module, next to the Lake Formation grants they must stay aligned with.
# ---------------------------------------------------------------------------

locals {
  analytics_sql_dir = "${path.module}/../../sql/analytics"

  sql_template_vars = {
    raw_db     = local.database_names.raw
    trusted_db = local.database_names.trusted
    refined_db = local.database_names.refined
  }

  # The SQL lives in parte-2/sql/analytics/*.sql -- one file per query, rendered here
  # with the database names only. Window dates are Athena execution parameters, so the
  # exact text below is what scripts/part-2/run_query.sh fetches and executes.
  analytics_queries = {
    business-question = {
      file        = "business_question.sql"
      layer       = "refined"
      description = "Part 2 business question, from the refined layer. Params: first day, last day of the EPSS window."
    }
    business-question-from-trusted = {
      file        = "business_question_from_trusted.sql"
      layer       = "trusted"
      description = "Same question recomputed from trusted Parquet (cost comparison only). Params: first, last, first, last day, KEV catalog_date."
    }
    business-question-from-raw = {
      file        = "business_question_from_raw.sql"
      layer       = "raw"
      description = "Same question computed from the raw files (cost comparison only). Params: first, last, first, last day, KEV catalog_date."
    }
    epss-scan-profile = {
      file        = "epss_scan_profile.sql"
      layer       = "trusted"
      description = "Partition pruning probe: one EPSS column over a date range. Params: first day, last day."
    }
    grain-check = {
      file        = "grain_check.sql"
      layer       = "trusted"
      description = "Proves the declared grain of every trusted/refined table: duplicate_rows must be 0."
    }
  }
}

resource "aws_athena_workgroup" "pipeline" {
  name        = "${var.name_prefix}-wg${var.name_suffix}"
  description = "EDA262 g07 Part 2 -- pipeline WorkGroup: raw -> trusted -> refined loads and the cost comparison."
  state       = "ENABLED"

  # Deletes the named queries of this WorkGroup on destroy ("no orphaned resources").
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.pipeline_bytes_scanned_cutoff

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = local.athena_output_location

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

resource "aws_athena_named_query" "analytics" {
  for_each = local.analytics_queries

  name        = "${var.name_prefix}-${each.key}${var.name_suffix}"
  description = each.value.description
  workgroup   = aws_athena_workgroup.pipeline.id
  database    = aws_glue_catalog_database.layer[each.value.layer].name
  query       = templatefile("${local.analytics_sql_dir}/${each.value.file}", local.sql_template_vars)
}
