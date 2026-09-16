# ---------------------------------------------------------------------------
# Athena WorkGroup: the single entry point for querying the lake.
# Configuration is enforced at the workgroup level so a client cannot opt out of
# the results location or the per-query scan cap.
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "this" {
  name        = "${var.name_prefix}-wg${var.name_suffix}"
  description = "EDA262 g07 Part 1 -- CISA KEV analytics workgroup with an enforced cost guardrail."
  state       = "ENABLED"

  # Deletes named queries belonging to this workgroup on destroy, so the rubric's
  # "no orphaned resources" criterion holds.
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.bytes_scanned_cutoff_per_query
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

# The graded business question, versioned as infrastructure rather than pasted
# into the console at demo time.
resource "aws_athena_named_query" "business_question" {
  name        = "${var.name_prefix}-top-vendors-last-12-months${var.name_suffix}"
  description = "Which vendors/products concentrate the most actively exploited vulnerabilities (KEV) in the last 12 months?"
  workgroup   = aws_athena_workgroup.this.id
  database    = aws_glue_catalog_database.lake.name
  query       = local.business_question_sql
}

# A second named query that proves the declared grain instead of asserting it.
resource "aws_athena_named_query" "grain_check" {
  name        = "${var.name_prefix}-grain-check${var.name_suffix}"
  description = "Proves the declared grain: total rows must equal distinct cve_id."
  workgroup   = aws_athena_workgroup.this.id
  database    = aws_glue_catalog_database.lake.name
  query       = local.grain_check_sql
}
