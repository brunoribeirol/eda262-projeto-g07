-- EDA262 g07 | Local profiling of the EPSS + KEV sources (DuckDB)
--
-- Rendered and run by scripts/part-2/profile_sources.sh. Produces, offline and for free,
-- the source-side numbers DECISOES.md quotes as "medido na fonte": volume per day, data
-- quality, Parquet size per codec, bytes per column, and the size of the refined aggregate.
-- AWS-side numbers (bytes scanned by Athena) come from run_query.sh instead.
--
-- Placeholders: ${epss_glob} ${kev_file} ${out_dir} ${first_day} ${latest_day}
.timer off

CREATE OR REPLACE TABLE epss_raw AS
SELECT
    regexp_extract(filename, 'epss_scores-([0-9-]{10})', 1) AS snapshot_date,
    cve, epss, percentile
FROM read_csv('${epss_glob}', skip = 1, header = true, filename = true, all_varchar = true)
WHERE regexp_extract(filename, 'epss_scores-([0-9-]{10})', 1) BETWEEN '${first_day}' AND '${latest_day}';

CREATE OR REPLACE TABLE epss AS
SELECT cve AS cve_id, CAST(epss AS DOUBLE) AS epss, CAST(percentile AS DOUBLE) AS percentile,
       CAST(snapshot_date AS DATE) AS score_date, snapshot_date
FROM epss_raw;

.print '== EPSS volume'
SELECT count(DISTINCT snapshot_date) AS days, count(*) AS rows_total,
       round(count(*) / count(DISTINCT snapshot_date)) AS avg_rows_per_day
FROM epss_raw;

.print '== EPSS data quality (raw rows that trusted would reject or deduplicate)'
SELECT count(*) - count(DISTINCT (snapshot_date, cve))                                     AS duplicate_keys,
       count_if(NOT regexp_full_match(cve, 'CVE-[0-9]{4}-[0-9]{4,}'))                       AS bad_cve_ids,
       count_if(TRY_CAST(epss AS DOUBLE) IS NULL OR TRY_CAST(epss AS DOUBLE) NOT BETWEEN 0 AND 1) AS bad_epss,
       count_if(TRY_CAST(percentile AS DOUBLE) IS NULL
                OR TRY_CAST(percentile AS DOUBLE) NOT BETWEEN 0 AND 1)                      AS bad_percentile
FROM epss_raw;

.print '== One trusted partition (${latest_day}) as Parquet, per codec'
COPY (SELECT * EXCLUDE (snapshot_date) FROM epss WHERE snapshot_date = '${latest_day}')
  TO '${out_dir}/day_zstd.parquet' (FORMAT parquet, COMPRESSION zstd);
COPY (SELECT * EXCLUDE (snapshot_date) FROM epss WHERE snapshot_date = '${latest_day}')
  TO '${out_dir}/day_snappy.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY (SELECT * EXCLUDE (snapshot_date) FROM epss WHERE snapshot_date = '${latest_day}')
  TO '${out_dir}/day_gzip.parquet' (FORMAT parquet, COMPRESSION gzip);
SELECT regexp_extract(file_name, 'day_([a-z]+)', 1) AS codec, sum(total_compressed_size) AS column_chunk_bytes
FROM parquet_metadata('${out_dir}/day_*.parquet')
GROUP BY 1 ORDER BY 2;

.print '== Bytes per column, ZSTD (what Athena reads when a query projects a subset)'
SELECT path_in_schema AS column_name, sum(total_compressed_size) AS bytes
FROM parquet_metadata('${out_dir}/day_zstd.parquet')
GROUP BY 1 ORDER BY 2 DESC;

.print '== KEV catalog'
CREATE OR REPLACE TABLE kev AS
SELECT unnest(vulnerabilities, recursive := true)
FROM read_json('${kev_file}', maximum_object_size = 64000000);

SELECT count(*) AS rows, count(DISTINCT cveID) AS distinct_cve,
       count_if(vendorProject <> trim(vendorProject) OR product <> trim(product)) AS untrimmed_vendor_or_product,
       count(DISTINCT trim(vendorProject)) AS vendors,
       count(DISTINCT lower(trim(vendorProject))) AS vendors_case_insensitive
FROM kev;

.print '== KEV CVEs vs the whole EPSS population on ${latest_day}'
WITH e AS (SELECT * FROM epss WHERE snapshot_date = '${latest_day}')
SELECT 'kev' AS population, count(*) AS cves, round(median(e.epss), 4) AS median_epss,
       round(100.0 * count_if(e.epss >= 0.1) / count(*), 2) AS pct_epss_ge_10pct
FROM kev JOIN e ON e.cve_id = kev.cveID
UNION ALL
SELECT 'all', count(*), round(median(epss), 5), round(100.0 * count_if(epss >= 0.1) / count(*), 2)
FROM e;

.print '== Point-in-time: KEV CVEs listed after the first day of the EPSS window'
SELECT count_if(CAST(dateAdded AS DATE) > (SELECT min(score_date) FROM epss)) AS listed_inside_window
FROM kev;

.print '== Refined aggregate (vendor x day) for the whole window'
CREATE OR REPLACE TABLE refined AS
SELECT e.snapshot_date, trim(k.vendorProject) AS vendor_project,
       count(*) AS kev_cves, sum(e.epss) AS epss_sum, max(e.epss) AS epss_max
FROM epss e JOIN kev k ON k.cveID = e.cve_id
WHERE CAST(k.dateAdded AS DATE) <= e.score_date
GROUP BY ALL;
COPY (SELECT * EXCLUDE (snapshot_date) FROM refined) TO '${out_dir}/refined_zstd.parquet' (FORMAT parquet, COMPRESSION zstd);
SELECT (SELECT count(*) FROM refined) AS rows,
       (SELECT count(DISTINCT snapshot_date) FROM refined) AS days,
       (SELECT sum(total_compressed_size) FROM parquet_metadata('${out_dir}/refined_zstd.parquet')) AS parquet_bytes;
