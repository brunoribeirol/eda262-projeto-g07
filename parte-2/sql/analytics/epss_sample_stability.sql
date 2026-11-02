-- EDA262 g07 | How much a vendor's average EPSS moves over the window, by sample size
--
-- Backs min_epss_sample_size (DECISOES.md, decision 25). For every vendor scored on both the
-- first and the last day of the window: the absolute change of its average EPSS between those
-- two days, grouped by how many scored CVEs the last-day average is taken over. An average
-- over a handful of CVEs jumps whenever one of them is re-scored; the threshold is the sample
-- size from which that jump stops depending on n.
--
-- Fixed buckets, so the evidence stays comparable if the threshold variable ever changes.
--
-- Execution parameters, in order (question-mark placeholders are used ONLY for parameters):
--   1. first day of the window   2. last day of the window
WITH daily AS (
    SELECT vendor_project, snapshot_date, epss_scored_cves, epss_sum
    FROM "${refined_db}"."vendor_exposure_daily"
    WHERE snapshot_date BETWEEN ? AND ?
),
bounded AS (
    SELECT
        *,
        max(snapshot_date) OVER () AS last_day,
        min(snapshot_date) OVER () AS first_day
    FROM daily
),
per_vendor AS (
    SELECT
        vendor_project,
        sum(epss_scored_cves) FILTER (WHERE snapshot_date = last_day) AS n_last,
        sum(epss_sum) FILTER (WHERE snapshot_date = last_day)
          / nullif(sum(epss_scored_cves) FILTER (WHERE snapshot_date = last_day), 0)  AS avg_last,
        sum(epss_sum) FILTER (WHERE snapshot_date = first_day)
          / nullif(sum(epss_scored_cves) FILTER (WHERE snapshot_date = first_day), 0) AS avg_first
    FROM bounded
    GROUP BY vendor_project
),
measured AS (
    SELECT
        CASE
            WHEN n_last < 5  THEN 1
            WHEN n_last < 10 THEN 2
            WHEN n_last < 30 THEN 3
            ELSE 4
        END                        AS bucket_order,
        abs(avg_last - avg_first)  AS abs_change
    FROM per_vendor
    WHERE avg_last IS NOT NULL
      AND avg_first IS NOT NULL
)
SELECT
    CASE bucket_order WHEN 1 THEN '1-4' WHEN 2 THEN '5-9' WHEN 3 THEN '10-29' ELSE '30+' END AS n_bucket,
    count(*)                                         AS vendors,
    round(approx_percentile(abs_change, 0.5), 4)     AS median_abs_change,
    round(approx_percentile(abs_change, 0.9), 4)     AS p90_abs_change,
    round(max(abs_change), 4)                        AS max_abs_change,
    ${min_epss_sample}                               AS min_epss_sample_size
FROM measured
GROUP BY bucket_order
ORDER BY bucket_order
