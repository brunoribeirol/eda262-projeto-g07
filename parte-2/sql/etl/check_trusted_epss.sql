-- EDA262 g07 | Post-load gate for trusted.epss_scores
--
-- Rendered by scripts/part-2/lib.sh with ${trusted_db} ${date_from} ${date_to}.
-- The pipeline compares `rows` with the data lines it counted in each downloaded file and
-- fails the run if a day lost rows or if the grain (cve_id, snapshot_date) is violated.
SELECT
    snapshot_date,
    count(*)                      AS rows,
    count(DISTINCT cve_id)        AS distinct_cve_id,
    count(DISTINCT model_version) AS model_versions
FROM "${trusted_db}"."epss_scores"
WHERE snapshot_date BETWEEN '${date_from}' AND '${date_to}'
GROUP BY snapshot_date
ORDER BY snapshot_date
