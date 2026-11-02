-- EDA262 g07 | Part 2 business question -- answered from the TRUSTED layer (comparison)
--
-- Same question and same output as business_question.sql, but recomputing the per-vendor,
-- per-day aggregate from trusted Parquet on every execution instead of reading the refined
-- table. Exists to measure what the refined layer saves. Not used by any consumer.
--
-- Execution parameters, in order. The window appears twice because a parameter can only be
-- bound once; the question-mark placeholder is used ONLY for parameters, never in comments:
--   1. first day of the window   2. last day of the window   (calendar of days)
--   3. first day of the window   4. last day of the window   (EPSS partition filter)
--   5. KEV catalog_date to use as the dimension, e.g. '2026-10-16'
WITH days AS (
    SELECT date_format(d.calendar_day, '%Y-%m-%d') AS snapshot_date, d.calendar_day
    FROM UNNEST(sequence(date(?), date(?), INTERVAL '1' DAY)) AS d (calendar_day)
),
epss AS (
    SELECT cve_id, epss, snapshot_date
    FROM "${trusted_db}"."epss_scores"
    WHERE snapshot_date BETWEEN ? AND ?
),
kev AS (
    SELECT cve_id, vendor_project, date_added, is_known_ransomware_use
    FROM "${trusted_db}"."kev_vulnerabilities"
    WHERE catalog_date = ?
),
listed AS (
    SELECT d.snapshot_date, k.*
    FROM days d
    CROSS JOIN kev k
    WHERE k.date_added <= d.calendar_day
),
per_vendor_day AS (
    SELECT
        l.vendor_project,
        l.snapshot_date,
        count_if(l.date_added > date_add('month', -12, date(l.snapshot_date))) AS kev_cves_last_12m,
        count_if(l.is_known_ransomware_use)                                    AS ransomware_linked,
        count(e.epss)                                                          AS epss_scored_cves,
        sum(e.epss)                                                            AS epss_sum,
        count_if(e.epss >= 0.1)                                                AS cves_epss_ge_10pct
    FROM listed l
    LEFT JOIN epss e
           ON e.cve_id = l.cve_id
          AND e.snapshot_date = l.snapshot_date
    GROUP BY l.vendor_project, l.snapshot_date
),
daily AS (
    SELECT *
    FROM (
        SELECT *, sum(epss_scored_cves) OVER (PARTITION BY snapshot_date) AS day_scored_cves
        FROM per_vendor_day
    )
    WHERE day_scored_cves > 0
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
