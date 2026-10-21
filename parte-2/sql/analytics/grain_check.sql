-- EDA262 g07 | Grain assertion for every modeled table (trusted + refined)
--
-- Each table declares its grain in the Glue catalog (table parameter `grain`). This query
-- proves it instead of asserting it: duplicate_rows must be 0 on every line.
-- One GROUP BY per table, so each table is read exactly once.
SELECT
    'trusted.epss_scores'       AS table_name,
    'cve_id, snapshot_date'     AS grain,
    sum(n)                      AS total_rows,
    count(*)                    AS distinct_keys,
    sum(n) - count(*)           AS duplicate_rows
FROM (
    SELECT count(*) AS n
    FROM "${trusted_db}"."epss_scores"
    GROUP BY cve_id, snapshot_date
)
UNION ALL
SELECT
    'trusted.kev_vulnerabilities',
    'cve_id, catalog_date',
    sum(n),
    count(*),
    sum(n) - count(*)
FROM (
    SELECT count(*) AS n
    FROM "${trusted_db}"."kev_vulnerabilities"
    GROUP BY cve_id, catalog_date
)
UNION ALL
SELECT
    'refined.vendor_exposure_daily',
    'vendor_project, snapshot_date',
    sum(n),
    count(*),
    sum(n) - count(*)
FROM (
    SELECT count(*) AS n
    FROM "${refined_db}"."vendor_exposure_daily"
    GROUP BY vendor_project, snapshot_date
)
ORDER BY table_name
