-- EDA262 g07 | Post-load gate for trusted.kev_vulnerabilities
--
-- Rendered by scripts/part-2/lib.sh with ${trusted_db} ${catalog_date}.
-- The pipeline compares `rows` with the line count of the NDJSON it uploaded to raw.
SELECT
    count(*)                                                                  AS rows,
    count(DISTINCT cve_id)                                                    AS distinct_cve_id,
    count_if(vendor_project <> trim(vendor_project) OR product <> trim(product)) AS untrimmed_rows,
    count_if(date_added IS NULL)                                              AS null_date_added
FROM "${trusted_db}"."kev_vulnerabilities"
WHERE catalog_date = '${catalog_date}'
