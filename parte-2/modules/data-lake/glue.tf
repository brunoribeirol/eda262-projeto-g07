# ---------------------------------------------------------------------------
# Glue Data Catalog: one database per layer, every table declared from
# local.tables. No aws_glue_crawler exists anywhere in this stack -- the schema
# is code, reviewed like code (course guide requirement, kept from Part 1).
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "layer" {
  for_each = local.database_names

  name        = each.value
  description = "EDA262 g07 Part 2 -- ${each.key} layer. Read access is granted per layer by Lake Formation."

  # create_table_default_permission is intentionally not set: new tables inherit
  # the cleared account default, i.e. no IAMAllowedPrincipals grant (see ../../main.tf).
}

resource "aws_glue_catalog_table" "this" {
  for_each = local.tables

  name          = each.value.name
  database_name = aws_glue_catalog_database.layer[each.value.layer].name
  description   = each.value.description
  table_type    = "EXTERNAL_TABLE"

  parameters = merge(
    local.formats[each.value.format].table_parameters,
    lookup(local.projection_parameters, each.key, {}),
    {
      EXTERNAL        = "TRUE"
      "grain"         = each.value.grain
      "layer"         = each.value.layer
      "source.system" = each.value.source
    },
  )

  dynamic "partition_keys" {
    for_each = each.value.partition_keys

    content {
      name    = partition_keys.value.name
      type    = partition_keys.value.type
      comment = partition_keys.value.comment
    }
  }

  storage_descriptor {
    location      = local.table_locations[each.key]
    input_format  = local.formats[each.value.format].input_format
    output_format = local.formats[each.value.format].output_format

    ser_de_info {
      name                  = "${each.value.name}-${each.value.format}"
      serialization_library = local.formats[each.value.format].serde
      parameters            = local.formats[each.value.format].serde_parameters
    }

    dynamic "columns" {
      for_each = each.value.columns

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }
}
