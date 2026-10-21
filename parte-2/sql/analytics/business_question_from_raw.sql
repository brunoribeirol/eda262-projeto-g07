-- EDA262 g07 | Part 2 business question -- answered from the RAW layer (comparison)
--
-- Same question and same output as business_question.sql, computed straight from the files
-- as published (gzip CSV + JSON lines), applying the trusted layer's cleaning inline. This is
-- what every execution would cost without the lake's layers; it exists only to measure that.
--
-- Text formats cannot skip columns, so this reads every byte of every day in the window.
-- Row-level validation matches the trusted load; the file-header check (score_date = day)
-- is left to ingestion, where it gates every file before upload.
--
-- Execution parameters, in order (question-mark placeholders are used ONLY for parameters):
--   1. first day of the window   2. last day of the window   (calendar of days)
--   3. first day of the window   4. last day of the window   (EPSS partition filter)
--   5. KEV catalog_date to use as the dimension, e.g. '2026-10-16'
WITH days AS (
    SELECT date_format(d.calendar_day, '%Y-%m-%d') AS snapshot_date, d.calendar_day
    FROM UNNEST(sequence(date(?), date(?), INTERVAL '1' DAY)) AS d (calendar_day)
),
epss AS (
    SELECT
        trim(cve)                      AS cve_id,
        try_cast(trim(epss) AS double) AS epss,
        snapshot_date
    FROM "${raw_db}"."epss_scores"
    WHERE snapshot_date BETWEEN ? AND ?
      AND regexp_like(trim(cve), '^CVE-[0-9]{4}-[0-9]{4,}$')
),
kev AS (
    SELECT
        trim(cveid)                                                 AS cve_id,
        trim(vendorproject)                                         AS vendor_project,
        try(date(trim(dateadded)))                                  AS date_added,
        coalesce(trim(knownransomwarecampaignuse) = 'Known', false) AS is_known_ransomware_use
    FROM "${raw_db}"."kev_records"
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
