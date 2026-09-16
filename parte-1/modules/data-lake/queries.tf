# ---------------------------------------------------------------------------
# SQL for the graded queries, kept in one place and published as Athena named
# queries (see athena.tf) and as module outputs. scripts/run_query.sh executes
# them by named-query ID, so the SQL that runs is provably the SQL in version
# control -- there is no second copy to drift.
#
# Note: no trim()/coalesce() defensive cleaning happens here on purpose. Cleaning
# is the trusted layer's job (done at ingestion); re-doing it at query time would
# hide whether the layer actually works.
# ---------------------------------------------------------------------------

locals {
  qualified_table = "\"${var.glue_database_name}\".\"${var.trusted_table_name}\""

  business_question_sql = <<-SQL
    -- EDA262 g07 | Part 1 business question
    -- Which vendors concentrate the most actively exploited vulnerabilities (KEV)
    -- in the last 12 months, and how much of that exposure is ransomware-linked?
    WITH window_kev AS (
        SELECT
            vendor_project,
            product,
            is_known_ransomware_use,
            date(date_added) AS date_added
        FROM ${local.qualified_table}
        WHERE date(date_added) >= date_add('month', -12, current_date)
    )
    SELECT
        vendor_project,
        count(*)                                                       AS kev_count,
        count(DISTINCT product)                                        AS affected_products,
        count_if(is_known_ransomware_use)                              AS ransomware_linked,
        round(100.0 * count(*) / (SELECT count(*) FROM window_kev), 2) AS pct_of_window,
        max(date_added)                                                AS most_recent_kev
    FROM window_kev
    GROUP BY vendor_project
    ORDER BY kev_count DESC, vendor_project
    LIMIT 15
  SQL

  grain_check_sql = <<-SQL
    -- EDA262 g07 | Grain assertion for ${var.trusted_table_name}
    -- The declared grain is "one row per CVE". duplicate_rows must be 0.
    SELECT
        count(*)                          AS total_rows,
        count(DISTINCT cve_id)            AS distinct_cve_id,
        count(*) - count(DISTINCT cve_id) AS duplicate_rows
    FROM ${local.qualified_table}
  SQL
}
