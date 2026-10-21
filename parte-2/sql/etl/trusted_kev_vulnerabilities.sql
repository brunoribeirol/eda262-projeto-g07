-- EDA262 g07 | ETL raw -> trusted: CISA KEV catalog snapshot
--
-- Rendered by scripts/part-2/lib.sh (render_sql) with:
--   ${raw_db} ${trusted_db}   Glue databases of each layer
--   ${catalog_date}           KEV snapshot partition to (re)load, yyyy-MM-dd
--   ${catalog_version}        catalogVersion of the source document, e.g. 2026.10.16
--   ${ingested_at}            UTC run timestamp, 'yyyy-MM-dd HH:mm:ss'
--
-- Idempotency: append-only statement; the pipeline deletes the target partition prefix
-- first (partition overwrite), exactly like the EPSS load.
--
-- Cleaning carried over from Part 1 (where it lived in jq) and now expressed in SQL, so
-- every transformation of the lake is reviewable in one language:
--   * whitespace trimmed on text fields (measured: 19 of 1,748 vendor/product values)
--   * 'Known'/'Unknown' and 'Yes'/'No' become real booleans
--   * dates become native DATE (Part 1 had to keep them as string: NDJSON has no types)
--   * cwe_count precomputed; grain (cve_id, catalog_date) guaranteed
INSERT INTO "${trusted_db}"."kev_vulnerabilities"
WITH typed AS (
    SELECT
        trim(cveid)                                            AS cve_id,
        trim(vendorproject)                                    AS vendor_project,
        trim(product)                                          AS product,
        trim(vulnerabilityname)                                AS vulnerability_name,
        try(date(trim(dateadded)))                             AS date_added,
        try(date(trim(duedate)))                               AS due_date,
        trim(shortdescription)                                 AS short_description,
        trim(requiredaction)                                   AS required_action,
        trim(notes)                                            AS notes,
        coalesce(trim(knownransomwarecampaignuse) = 'Known', false) AS is_known_ransomware_use,
        coalesce(trim(forensictriage) = 'Yes', false)          AS requires_forensic_triage,
        transform(coalesce(cwes, CAST(ARRAY[] AS array(varchar))), c -> trim(c)) AS cwes,
        CAST(cardinality(coalesce(cwes, CAST(ARRAY[] AS array(varchar)))) AS bigint) AS cwe_count,
        catalog_date
    FROM "${raw_db}"."kev_records"
    WHERE catalog_date = '${catalog_date}'
),
validated AS (
    SELECT
        *,
        row_number() OVER (PARTITION BY cve_id ORDER BY date_added) AS occurrence
    FROM typed
    WHERE regexp_like(cve_id, '^CVE-[0-9]{4}-[0-9]{4,}$')
      AND date_added IS NOT NULL
)
SELECT
    cve_id,
    vendor_project,
    product,
    vulnerability_name,
    date_added,
    due_date,
    short_description,
    required_action,
    notes,
    is_known_ransomware_use,
    requires_forensic_triage,
    cwes,
    cwe_count,
    '${catalog_version}'                AS catalog_version,
    CAST('${ingested_at}' AS timestamp) AS ingested_at,
    catalog_date
FROM validated
WHERE occurrence = 1
