-- EDA262 g07 | ETL trusted -> refined: vendor exposure per day
--
-- Rendered by scripts/part-2/lib.sh (render_sql) with:
--   ${trusted_db} ${refined_db}  Glue databases of each layer
--   ${date_from} ${date_to}      snapshot_date range to (re)build, yyyy-MM-dd
--   ${kev_catalog_date}          KEV snapshot (trusted partition) used as the dimension
--   ${built_at}                  UTC run timestamp, 'yyyy-MM-dd HH:mm:ss'
--
-- Idempotency: append-only; the pipeline deletes the target partition prefixes first.
--
-- Point-in-time rule: on day D a CVE counts for its vendor only if CISA had already listed
-- it on D (date_added <= D). The KEV dimension is a single, newer snapshot, so without this
-- rule a backfilled day would count CVEs CISA had not listed yet -- measured: 31 of 1,748
-- KEV CVEs were added inside the 30-day window ending 2026-10-20.
--
-- Days come from the requested range; days with no EPSS file at all are dropped at the end,
-- so a missing day never appears as a day where every vendor scored zero.
INSERT INTO "${refined_db}"."vendor_exposure_daily"
WITH epss AS (
    SELECT cve_id, epss, model_version, snapshot_date
    FROM "${trusted_db}"."epss_scores"
    WHERE snapshot_date BETWEEN '${date_from}' AND '${date_to}'
),
kev AS (
    SELECT cve_id, vendor_project, date_added, is_known_ransomware_use
    FROM "${trusted_db}"."kev_vulnerabilities"
    WHERE catalog_date = '${kev_catalog_date}'
),
listed AS (
    SELECT date_format(d.calendar_day, '%Y-%m-%d') AS snapshot_date, k.*
    FROM UNNEST(sequence(date '${date_from}', date '${date_to}', INTERVAL '1' DAY)) AS d (calendar_day)
    CROSS JOIN kev k
    WHERE k.date_added <= d.calendar_day
),
daily AS (
    SELECT
        l.vendor_project,
        l.snapshot_date,
        count(*)                                                               AS kev_cves,
        count_if(l.date_added > date_add('month', -12, date(l.snapshot_date))) AS kev_cves_last_12m,
        count_if(l.is_known_ransomware_use)                                    AS ransomware_linked,
        count(e.epss)                                                          AS epss_scored_cves,
        sum(e.epss)                                                            AS epss_sum,
        avg(e.epss)                                                            AS epss_avg,
        max(e.epss)                                                            AS epss_max,
        count_if(e.epss >= 0.1)                                                AS cves_epss_ge_10pct,
        max(e.model_version)                                                   AS epss_model_version
    FROM listed l
    LEFT JOIN epss e
           ON e.cve_id = l.cve_id
          AND e.snapshot_date = l.snapshot_date
    GROUP BY l.vendor_project, l.snapshot_date
),
with_day_totals AS (
    SELECT
        *,
        sum(epss_scored_cves) OVER (PARTITION BY snapshot_date)   AS day_scored_cves,
        max(epss_model_version) OVER (PARTITION BY snapshot_date) AS day_model_version
    FROM daily
)
SELECT
    vendor_project,
    kev_cves,
    kev_cves_last_12m,
    ransomware_linked,
    epss_scored_cves,
    epss_sum,
    epss_avg,
    epss_max,
    cves_epss_ge_10pct,
    '${kev_catalog_date}'            AS kev_catalog_date,
    day_model_version                AS epss_model_version,
    CAST('${built_at}' AS timestamp) AS built_at,
    snapshot_date
FROM with_day_totals
WHERE day_scored_cves > 0
