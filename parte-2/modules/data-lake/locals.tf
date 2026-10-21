locals {
  layers = ["raw", "trusted", "refined"]

  # Every S3 bucket in the lake, declared once. The rubric mandates `eda262-g07-lake-<layer>`
  # for layer buckets; the Athena results bucket is operational, not a lake layer.
  buckets = {
    raw = {
      name_part       = "lake-raw"
      expiration_days = null # source payloads are kept for the life of the stack
    }
    trusted = {
      name_part       = "lake-trusted"
      expiration_days = null
    }
    refined = {
      name_part       = "lake-refined"
      expiration_days = null
    }
    athena_results = {
      name_part       = "athena-results"
      expiration_days = var.athena_results_retention_days
    }
  }

  bucket_names = {
    for key, cfg in local.buckets : key => "${var.name_prefix}-${cfg.name_part}${var.name_suffix}"
  }

  # One Glue database per layer, so Lake Formation grants map 1:1 to layers.
  # Glue rejects hyphens, hence underscores: eda262_g07_raw, eda262_g07_trusted, ...
  database_names = {
    for layer in local.layers :
    layer => "${replace(var.name_prefix, "-", "_")}_${layer}${replace(var.name_suffix, "-", "_")}"
  }

  # ---------------------------------------------------------------------------
  # Storage formats. Raw keeps each source's own format (the bytes are never
  # rewritten); trusted and refined are Parquet + ZSTD.
  #
  # ZSTD measured on one EPSS day (2026-10-20, 391,915 rows, DuckDB 1.5.6):
  # 2,704,197 B vs SNAPPY 5,203,860 B (1.92x) vs GZIP 3,206,239 B (1.19x).
  # See DECISOES.md, Part 2, "Formato".
  # ---------------------------------------------------------------------------
  formats = {
    csv = {
      input_format     = "org.apache.hadoop.mapred.TextInputFormat"
      output_format    = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
      serde            = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      serde_parameters = { "field.delim" = ",", "serialization.format" = "," }
      table_parameters = { classification = "csv" }
    }
    json = {
      input_format  = "org.apache.hadoop.mapred.TextInputFormat"
      output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
      serde         = "org.openx.data.jsonserde.JsonSerDe"
      serde_parameters = {
        # Part 1 tolerated malformed lines. In Part 2 raw feeds an INSERT, and a silently
        # dropped line would become a silently missing CVE in trusted -- fail loudly instead.
        "ignore.malformed.json" = "false"
        "case.insensitive"      = "true"
      }
      table_parameters = { classification = "json" }
    }
    parquet = {
      input_format     = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
      output_format    = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
      serde            = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      serde_parameters = { "serialization.format" = "1" }
      # Athena's INSERT INTO honours this table property when writing Parquet.
      table_parameters = { classification = "parquet", "parquet.compression" = "ZSTD" }
    }
  }

  # ---------------------------------------------------------------------------
  # Every table in the lake, declared as data. Schemas are explicit -- never
  # inferred by a Glue Crawler (course guide, carried over from Part 1).
  #
  # Partition keys are `string` in ISO-8601 (yyyy-MM-dd): Glue stores partition values as
  # strings anyway, and ISO order is chronological order, so range predicates prune.
  #
  # Raw tables use partition projection: Athena derives the partition list from the table
  # properties, so loading a day is just an S3 upload -- no MSCK REPAIR, no Glue API call.
  # Trusted/refined partitions are registered by Athena's own INSERT INTO.
  # ---------------------------------------------------------------------------
  tables = {
    raw_epss_scores = {
      layer       = "raw"
      name        = "epss_scores"
      prefix      = "epss_scores"
      format      = "csv"
      description = "FIRST EPSS daily scores exactly as published (gzip CSV). Every line of the file is a row: the '#model_version' metadata line and the header are kept, and parsed by the trusted INSERT."
      grain       = "one row per line of the published file"
      source      = "first-epss"
      partition_keys = [
        { name = "snapshot_date", type = "string", comment = "EPSS publication date (yyyy-MM-dd), taken from the file name." },
      ]
      projection = { key = "snapshot_date", range = "2021-04-14,NOW" } # first day EPSS v1 was published
      columns = [
        { name = "cve", type = "string", comment = "CVE identifier as published. On the metadata line it holds '#model_version:<version>'." },
        { name = "epss", type = "string", comment = "Probability of exploitation in the next 30 days, as text. On the metadata line it holds 'score_date:<timestamp>'." },
        { name = "percentile", type = "string", comment = "Percentile of the score among all scored CVEs that day, as text." },
      ]
    }

    raw_kev_records = {
      layer       = "raw"
      name        = "kev_records"
      prefix      = "kev_records"
      format      = "json"
      description = "CISA KEV entries, one JSON object per line, values untouched. Re-framed from the source document only because the JSON SerDe reads one object per line; the original document is archived byte-for-byte under kev_catalog/."
      grain       = "one row per KEV entry per catalog snapshot"
      source      = "cisa-kev"
      partition_keys = [
        { name = "catalog_date", type = "string", comment = "Release date (yyyy-MM-dd) of the KEV catalog snapshot, from its dateReleased field." },
      ]
      projection = { key = "catalog_date", range = "2024-01-01,NOW" }
      # Column names are the source keys lowercased (Hive lowercases on read); renaming to
      # snake_case is the trusted layer's job, so raw stays a faithful mirror of the feed.
      columns = [
        { name = "cveid", type = "string", comment = "Source key cveID." },
        { name = "vendorproject", type = "string", comment = "Source key vendorProject, untrimmed (measured: 19 of 1,748 rows carry stray whitespace)." },
        { name = "product", type = "string", comment = "Source key product, untrimmed." },
        { name = "vulnerabilityname", type = "string", comment = "Source key vulnerabilityName." },
        { name = "dateadded", type = "string", comment = "Source key dateAdded, ISO-8601 text." },
        { name = "shortdescription", type = "string", comment = "Source key shortDescription." },
        { name = "requiredaction", type = "string", comment = "Source key requiredAction." },
        { name = "duedate", type = "string", comment = "Source key dueDate, ISO-8601 text." },
        { name = "knownransomwarecampaignuse", type = "string", comment = "Source key knownRansomwareCampaignUse: 'Known' or 'Unknown'." },
        { name = "notes", type = "string", comment = "Source key notes." },
        { name = "cwes", type = "array<string>", comment = "Source key cwes." },
        { name = "forensictriage", type = "string", comment = "Source key forensicTriage: 'Yes' or 'No'." },
      ]
    }

    trusted_epss_scores = {
      layer       = "trusted"
      name        = "epss_scores"
      prefix      = "epss_scores"
      format      = "parquet"
      description = "EPSS scores, validated and typed. Fact table of the lake."
      grain       = "one row per (cve_id, snapshot_date)"
      source      = "first-epss"
      partition_keys = [
        { name = "snapshot_date", type = "string", comment = "EPSS publication date (yyyy-MM-dd). One partition per day: ~384k rows, ~2.7 MB of Parquet." },
      ]
      projection = null
      columns = [
        { name = "cve_id", type = "string", comment = "Natural key (with snapshot_date). Validated against ^CVE-[0-9]{4}-[0-9]{4,}$." },
        { name = "epss", type = "double", comment = "Probability of exploitation in the next 30 days, in [0, 1]." },
        { name = "percentile", type = "double", comment = "Percentile of the score among all CVEs scored that day, in [0, 1]." },
        { name = "model_version", type = "string", comment = "Lineage: EPSS model that produced the score, parsed from the file's metadata line. Scores from different models are not comparable." },
        { name = "score_date", type = "date", comment = "Score date declared inside the file. The INSERT keeps a row only if it equals snapshot_date." },
        { name = "ingested_at", type = "timestamp", comment = "Lineage: UTC time of the pipeline run that wrote the partition." },
      ]
    }

    trusted_kev_vulnerabilities = {
      layer       = "trusted"
      name        = "kev_vulnerabilities"
      prefix      = "kev_vulnerabilities"
      format      = "parquet"
      description = "CISA KEV catalog, cleaned and typed. Dimension of the lake, kept as dated snapshots."
      grain       = "one row per (cve_id, catalog_date)"
      source      = "cisa-kev"
      partition_keys = [
        { name = "catalog_date", type = "string", comment = "Release date (yyyy-MM-dd) of the KEV snapshot. Re-ingesting the same catalog overwrites only this partition." },
      ]
      projection = null
      columns = [
        { name = "cve_id", type = "string", comment = "Natural key (with catalog_date)." },
        { name = "vendor_project", type = "string", comment = "Vendor or project, whitespace-trimmed." },
        { name = "product", type = "string", comment = "Affected product, whitespace-trimmed." },
        { name = "vulnerability_name", type = "string", comment = "Vulnerability title assigned by CISA." },
        { name = "date_added", type = "date", comment = "Date the CVE entered KEV. Native DATE, as promised in Part 1 DECISOES.md section 5." },
        { name = "due_date", type = "date", comment = "Remediation deadline for US federal agencies." },
        { name = "short_description", type = "string", comment = "CISA summary of the vulnerability." },
        { name = "required_action", type = "string", comment = "Remediation action mandated by CISA." },
        { name = "notes", type = "string", comment = "Reference URLs and free-text notes from CISA." },
        { name = "is_known_ransomware_use", type = "boolean", comment = "Normalized from 'Known'/'Unknown'." },
        { name = "requires_forensic_triage", type = "boolean", comment = "Normalized from 'Yes'/'No'." },
        { name = "cwes", type = "array<string>", comment = "CWE identifiers associated with the CVE." },
        { name = "cwe_count", type = "bigint", comment = "Cardinality of cwes, precomputed." },
        { name = "catalog_version", type = "string", comment = "Lineage: catalogVersion of the source document." },
        { name = "ingested_at", type = "timestamp", comment = "Lineage: UTC time of the pipeline run that wrote the partition." },
      ]
    }

    refined_vendor_exposure_daily = {
      layer       = "refined"
      name        = "vendor_exposure_daily"
      prefix      = "vendor_exposure_daily"
      format      = "parquet"
      description = "Business-ready aggregate: per vendor and day, how many actively exploited CVEs (KEV) it has and how likely they are to be exploited (EPSS). Answers the Part 2 business question."
      grain       = "one row per (vendor_project, snapshot_date)"
      source      = "cisa-kev+first-epss"
      partition_keys = [
        { name = "snapshot_date", type = "string", comment = "EPSS day the scores belong to (yyyy-MM-dd)." },
      ]
      projection = null
      columns = [
        { name = "vendor_project", type = "string", comment = "Natural key (with snapshot_date)." },
        { name = "kev_cves", type = "bigint", comment = "KEV CVEs of the vendor already listed on snapshot_date (point-in-time: date_added <= snapshot_date)." },
        { name = "kev_cves_last_12m", type = "bigint", comment = "Of those, added to KEV in the 12 months up to snapshot_date." },
        { name = "ransomware_linked", type = "bigint", comment = "Of those, with known ransomware campaign use." },
        { name = "epss_scored_cves", type = "bigint", comment = "Of those, with an EPSS score on snapshot_date." },
        { name = "epss_sum", type = "double", comment = "Sum of EPSS scores, kept so multi-day averages are exact (sum/count), not an average of averages." },
        { name = "epss_avg", type = "double", comment = "Average EPSS of the vendor's KEV CVEs on snapshot_date." },
        { name = "epss_max", type = "double", comment = "Highest EPSS among the vendor's KEV CVEs on snapshot_date." },
        { name = "cves_epss_ge_10pct", type = "bigint", comment = "KEV CVEs with EPSS >= 0.10 on snapshot_date." },
        { name = "kev_catalog_date", type = "string", comment = "Lineage: KEV snapshot (catalog_date) used to build the row." },
        { name = "epss_model_version", type = "string", comment = "Lineage: EPSS model version of the day's scores." },
        { name = "built_at", type = "timestamp", comment = "Lineage: UTC time of the pipeline run that wrote the partition." },
      ]
    }
  }

  table_locations = {
    for key, t in local.tables : key => "s3://${local.bucket_names[t.layer]}/${t.prefix}/"
  }

  # Partition projection properties, only for tables that declare a projection. Filtering
  # first (instead of a `projection == null ? {} : {...}` conditional) means no expression
  # ever reads an attribute of null.
  projected_tables = { for key, t in local.tables : key => t.projection if t.projection != null }

  projection_parameters = {
    for key, p in local.projected_tables : key => {
      "projection.enabled"                = "true"
      "projection.${p.key}.type"          = "date"
      "projection.${p.key}.format"        = "yyyy-MM-dd"
      "projection.${p.key}.range"         = p.range
      "projection.${p.key}.interval"      = "1"
      "projection.${p.key}.interval.unit" = "DAYS"
      "storage.location.template"         = format("%s%s=$${%s}/", local.table_locations[key], p.key, p.key)
    }
  }

  athena_output_location = "s3://${local.bucket_names.athena_results}/pipeline/"
}
