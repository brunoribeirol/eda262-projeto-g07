# ---------------------------------------------------------------------------
# Glue Data Catalog: one database, one trusted table.
# The schema is declared explicitly below (from local.trusted_columns) instead of
# being inferred by a Glue Crawler -- required by the course guide, and the reason
# no aws_glue_crawler resource exists anywhere in this stack.
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "lake" {
  name        = var.glue_database_name
  description = "CISA KEV data lake catalog for EDA262 group g07 (Part 1)."
}

resource "aws_glue_catalog_table" "trusted" {
  name          = var.trusted_table_name
  database_name = aws_glue_catalog_database.lake.name
  description   = "Trusted CISA KEV vulnerabilities. Grain: one row per CVE."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL        = "TRUE"
    classification  = "json"
    "grain"         = "one row per cve_id"
    "source.system" = "cisa-kev"
    "source.url"    = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
  }

  storage_descriptor {
    location      = local.trusted_table_location
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "kev-json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        # A single malformed line must not fail the whole query.
        "ignore.malformed.json" = "true"
        # Source keys are camelCase, Hive lowercases column names on read.
        "case.insensitive" = "true"
      }
    }

    dynamic "columns" {
      for_each = local.trusted_columns

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }
}
