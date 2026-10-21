-- EDA262 g07 | Partition pruning probe on trusted.epss_scores
--
-- Run twice by scripts/part-2/run_query.sh -- once for a single day, once for the whole
-- loaded window -- to measure how much partitioning by snapshot_date saves. The query
-- touches one column (epss), so the bytes scanned isolate the effect of partitioning from
-- the effect of the columnar format.
--
-- Execution parameters, in order (question-mark placeholders are used ONLY for parameters):
--   1. first day   2. last day
SELECT
    count(*)                      AS rows,
    count(DISTINCT snapshot_date) AS days,
    round(avg(epss), 6)           AS avg_epss
FROM "${trusted_db}"."epss_scores"
WHERE snapshot_date BETWEEN ? AND ?
