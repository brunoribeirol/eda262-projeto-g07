-- EDA262 g07 | Part 2 business question -- refined layer (the graded, cost-targeted query)
--
-- Which vendors concentrate the actively exploited vulnerabilities (CISA KEV) of the last
-- 12 months, and how likely each vendor's portfolio of exploited vulnerabilities is to be
-- exploited (FIRST EPSS) over a window of daily snapshots.
--
-- Scope: kev_cves_last_12m counts CVEs ADDED to KEV in the 12 months up to the last day
-- (recent activity); the EPSS columns, ransomware_linked and cves_epss_ge_10pct cover ALL of
-- the vendor's KEV CVEs already listed that day (current exposure). Both windows are anchored
-- on the data (the snapshot days asked for), never on the day the query happens to run.
--
-- Small samples: epss_scored_cves is the n behind every EPSS average. A vendor whose n drops
-- below ${min_epss_sample} on any day of the window gets NULL averages instead of a noisy number.
-- Ranking: by kev_cves_last_12m only, with ties kept -- every vendor tied at the cut is listed,
-- so no vendor is dropped by an EPSS average taken over a handful of CVEs.
--
-- Execution parameters, in order (Athena prompts for them in the console). This file uses
-- the question-mark placeholder ONLY for parameters, never in comments:
--   1. first day of the EPSS window, e.g. '2026-09-21'
--   2. last day of the EPSS window,  e.g. '2026-10-20'
--
-- Cost target: bytes scanned per day of the window (variable cost_target_bytes_per_window_day,
-- tagged on the pipeline WorkGroup). The query reads only the partitions of the window.
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
),
per_vendor AS (
    SELECT
        vendor_project,
        sum(kev_cves_last_12m)  FILTER (WHERE snapshot_date = last_day)  AS kev_cves_last_12m,
        sum(epss_scored_cves)   FILTER (WHERE snapshot_date = last_day)  AS epss_scored_cves,
        sum(ransomware_linked)  FILTER (WHERE snapshot_date = last_day)  AS ransomware_linked,
        sum(cves_epss_ge_10pct) FILTER (WHERE snapshot_date = last_day)  AS cves_epss_ge_10pct,
        sum(epss_sum)           FILTER (WHERE snapshot_date = last_day)  AS epss_sum_last,
        sum(epss_scored_cves)   FILTER (WHERE snapshot_date = first_day) AS epss_scored_first,
        sum(epss_sum)           FILTER (WHERE snapshot_date = first_day) AS epss_sum_first,
        sum(epss_scored_cves)                                            AS epss_scored_window,
        sum(epss_sum)                                                    AS epss_sum_window,
        min(epss_scored_cves)                                            AS epss_scored_min,
        count(*)                                                         AS days_in_window
    FROM bounded
    GROUP BY vendor_project
),
ranked AS (
    SELECT
        *,
        rank() OVER (ORDER BY kev_cves_last_12m DESC) AS vendor_rank,
        epss_scored_min >= ${min_epss_sample}         AS sample_ok
    FROM per_vendor
    WHERE kev_cves_last_12m > 0
)
SELECT
    vendor_rank,
    vendor_project,
    kev_cves_last_12m,
    epss_scored_cves,
    ransomware_linked,
    cves_epss_ge_10pct,
    CASE WHEN sample_ok THEN round(epss_sum_last / epss_scored_cves, 4) END AS epss_avg_latest,
    CASE WHEN sample_ok THEN round(epss_sum_window / epss_scored_window, 4) END AS epss_avg_window,
    CASE WHEN sample_ok
         THEN round(epss_sum_last / epss_scored_cves - epss_sum_first / epss_scored_first, 4)
    END AS epss_avg_change,
    days_in_window
FROM ranked
WHERE vendor_rank <= 15
ORDER BY vendor_rank, epss_scored_cves DESC, vendor_project
