-- EDA262 g07 | Post-load gate for refined.vendor_exposure_daily
--
-- Rendered by scripts/part-2/lib.sh with ${refined_db} ${date_from} ${date_to}.
-- The grain (vendor_project, snapshot_date) holds when rows = distinct_vendors per day.
SELECT
    snapshot_date,
    count(*)                       AS rows,
    count(DISTINCT vendor_project) AS distinct_vendors,
    sum(kev_cves)                  AS kev_cves,
    sum(epss_scored_cves)          AS epss_scored_cves
FROM "${refined_db}"."vendor_exposure_daily"
WHERE snapshot_date BETWEEN '${date_from}' AND '${date_to}'
GROUP BY snapshot_date
ORDER BY snapshot_date
