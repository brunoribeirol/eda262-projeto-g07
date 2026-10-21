-- EDA262 g07 | Part 2 business question -- refined layer (the graded, cost-targeted query)
--
-- Which vendors concentrate the actively exploited vulnerabilities (CISA KEV) of the last
-- 12 months, and how likely each vendor's portfolio of exploited vulnerabilities is to be
-- exploited (FIRST EPSS) over a window of daily snapshots.
--
-- Scope: kev_cves_last_12m counts CVEs ADDED to KEV in the 12 months up to the last day
-- (recent activity); the EPSS columns, ransomware_linked and cves_epss_ge_10pct cover ALL of
-- the vendor's KEV CVEs already listed that day (current exposure).
--
-- Execution parameters, in order (Athena prompts for them in the console). This file uses
-- the question-mark placeholder ONLY for parameters, never in comments:
--   1. first day of the EPSS window, e.g. '2026-09-21'
--   2. last day of the EPSS window,  e.g. '2026-10-20'
--
-- Cost target: <= 10 MB scanned (one Athena billing unit). The refined table holds ~1.5 KB
-- per day, so even a year-long window stays three orders of magnitude below the target.
-- business_question_from_trusted.sql and business_question_from_raw.sql answer the same
-- question from the lower layers; the pipeline checks the three results are identical.
WITH daily AS (
    SELECT
        vendor_project,
        snapshot_date,
        kev_cves_last_12m,
        ransomware_linked,
        epss_scored_cves,
        epss_sum,
        cves_epss_ge_10pct
    FROM "${refined_db}"."vendor_exposure_daily"
    WHERE snapshot_date BETWEEN ? AND ?
),
bounded AS (
    SELECT
        *,
        max(snapshot_date) OVER () AS last_day,
        min(snapshot_date) OVER () AS first_day
    FROM daily
)
SELECT
    vendor_project,
    sum(kev_cves_last_12m)  FILTER (WHERE snapshot_date = last_day) AS kev_cves_last_12m,
    sum(ransomware_linked)  FILTER (WHERE snapshot_date = last_day) AS ransomware_linked,
    sum(cves_epss_ge_10pct) FILTER (WHERE snapshot_date = last_day) AS cves_epss_ge_10pct,
    round(
        sum(epss_sum) FILTER (WHERE snapshot_date = last_day)
        / nullif(sum(epss_scored_cves) FILTER (WHERE snapshot_date = last_day), 0),
        4) AS epss_avg_latest,
    round(sum(epss_sum) / nullif(sum(epss_scored_cves), 0), 4) AS epss_avg_window,
    round(
        sum(epss_sum) FILTER (WHERE snapshot_date = last_day)
        / nullif(sum(epss_scored_cves) FILTER (WHERE snapshot_date = last_day), 0)
      - sum(epss_sum) FILTER (WHERE snapshot_date = first_day)
        / nullif(sum(epss_scored_cves) FILTER (WHERE snapshot_date = first_day), 0),
        4) AS epss_avg_change,
    count(*) AS days_in_window
FROM bounded
GROUP BY vendor_project
HAVING sum(kev_cves_last_12m) FILTER (WHERE snapshot_date = last_day) > 0
ORDER BY kev_cves_last_12m DESC, epss_avg_latest DESC, vendor_project
LIMIT 15
