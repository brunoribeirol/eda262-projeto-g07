-- EDA262 g07 | ETL raw -> trusted: EPSS daily scores
--
-- Rendered by scripts/part-2/lib.sh (render_sql) with:
--   ${raw_db} ${trusted_db}   Glue databases of each layer
--   ${date_from} ${date_to}   snapshot_date range to (re)load, yyyy-MM-dd, validated by the script
--   ${ingested_at}            UTC run timestamp, 'yyyy-MM-dd HH:mm:ss'
--
-- Idempotency: this statement only APPENDS. The pipeline deletes the target partitions'
-- S3 prefixes immediately before running it (partition overwrite), so re-running a date
-- range replaces its rows instead of duplicating them. See DECISOES.md, Part 2.
--
-- What raw -> trusted does here:
--   * parses lineage from each file's first line: '#model_version:<v>,score_date:<ts>'
--   * drops that metadata line and the 'cve,epss,percentile' header
--   * types epss/percentile as DOUBLE and validates the CVE id and the [0, 1] ranges
--   * keeps a row only if the score date declared inside the file equals its partition,
--     so a mislabeled file can never land under the wrong day
--   * guarantees the grain (cve_id, snapshot_date) even if the feed ever repeats a CVE
--
-- Single scan by design: the per-file metadata is spread to every row with a window
-- function instead of a self-join. Athena does not materialize CTEs, so referencing the
-- source twice would read the raw files twice (Part 1 measured exactly 2.00x on a CTE).
INSERT INTO "${trusted_db}"."epss_scores"
WITH source AS (
    SELECT
        "$path" AS source_file,
        cve,
        epss,
        percentile,
        snapshot_date
    FROM "${raw_db}"."epss_scores"
    WHERE snapshot_date BETWEEN '${date_from}' AND '${date_to}'
),
annotated AS (
    SELECT
        *,
        -- regexp_extract() is NULL on every line but the metadata one, and max() ignores NULLs.
        max(regexp_extract(cve, '^#model_version:(.+)$', 1))
            OVER (PARTITION BY source_file) AS model_version,
        max(try(date(regexp_extract(epss, '^score_date:([0-9]{4}-[0-9]{2}-[0-9]{2})', 1))))
            OVER (PARTITION BY source_file) AS score_date
    FROM source
),
typed AS (
    SELECT
        trim(cve)                            AS cve_id,
        try_cast(trim(epss) AS double)       AS epss,
        try_cast(trim(percentile) AS double) AS percentile,
        model_version,
        score_date,
        snapshot_date
    FROM annotated
    WHERE cve NOT LIKE '#%'
      AND cve <> 'cve'
),
validated AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY snapshot_date, cve_id
            ORDER BY epss DESC, percentile DESC
        ) AS occurrence
    FROM typed
    WHERE regexp_like(cve_id, '^CVE-[0-9]{4}-[0-9]{4,}$')
      AND epss BETWEEN 0 AND 1
      AND percentile BETWEEN 0 AND 1
      AND score_date = date(snapshot_date)
)
SELECT
    cve_id,
    epss,
    percentile,
    model_version,
    score_date,
    CAST('${ingested_at}' AS timestamp) AS ingested_at,
    snapshot_date
FROM validated
WHERE occurrence = 1
