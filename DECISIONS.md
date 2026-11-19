# Engineering decisions — EDA262, group g07

*Português: [DECISOES.md](DECISOES.md) — that is the copy the course grades.*

Every decision below is justified by a measured number, not by prose. The *how to measure*
snippets reproduce each number on any machine.

- [Part 1 (AV1)](#part-1-av1) — minimal data lake over CISA KEV, decisions 1 to 10.
- [Part 2 (AV2)](#part-2-av2) — three layers, partitioned Parquet, idempotent and incremental
  loads, Lake Formation, decisions 11 to 26.

# Part 1 (AV1)

**Source:** public CISA KEV (Known Exploited Vulnerabilities) catalog.
**Reference snapshot:** `catalogVersion` **2026.09.16**, holding **1,713** records.
**Business question:** which vendors concentrate the most actively exploited vulnerabilities
over the last 12 months, and what does that query cost in Athena?

> Figures marked **measured at source** were taken directly from the feed and reproduce offline.
> Figures marked **measured on AWS** are written to `docs/evidence/query-cost.json` by
> `scripts/run_query.sh` during deployment and must be checked after `apply`.

> **Post-AV1 erratum (grading feedback):** the figures in this part come from the 2026-09-17 run
> (catalog `2026.09.16`, 1,713 records), the only one whose evidence is versioned in
> `docs/evidence/`. Decision 6 used to quote another run over the same snapshot (execution id and
> engine time differing from `query-cost.json`); it now quotes the versioned one. The delivered
> deck (tag `av1-entrega`) showed a 2026-10-04 re-run (catalog `2026.10.04`, 1,734 records) whose
> evidence was not versioned; it stays as delivered. In Part 2 every evidence file and every
> quoted figure comes from a single run, and `verifica.sh` checks it.

---

## 1. Grain of the trusted table

**Decision:** one row per CVE in the KEV catalog. The grain is declared in the Glue Data Catalog
itself, as the table parameter `grain = "one row per cve_id"`.

| Evidence | Value |
|---|---|
| Records in the feed | **1,713** |
| Distinct `cveID` | **1,713** |
| Duplicate rows | **0** |

How to measure (source):

```bash
jq -r '"total=\(.vulnerabilities|length) distinct=\([.vulnerabilities[].cveID]|unique|length)"' \
  known_exploited_vulnerabilities.json
```

How to measure (AWS): the `eda262-g07-grain-check` named query, provisioned by Terraform, runs
`count(*) - count(DISTINCT cve_id)` against the table and must return **0**. Output lands in
`docs/evidence/grain-check-result.csv`.

**Why this grain and not another:** the alternative was *one row per (CVE, product)* pair. It was
rejected with a number: the feed ships `product` as free text, and **214 of 1,713 records (12.5%)**
contain separators that may indicate multiple products — **193** with `" and "` and **49** with a
comma.

| Pattern in `product` | Records |
|---|---|
| Contains `" and "` | **193** |
| Contains a comma | **49** |
| Union (` and `, `,`, `/`) | **214 (12.5%)** |

The separator is ambiguous, and that settles it: in `"NetScaler ADC and NetScaler Gateway"` those
are two products, but in `"Community Edition and Enterprise Edition"` they are two editions of one
product. Splitting on the separator would inflate a vendor's product count through a parsing
artifact — in precisely the indicator the business question measures. No deterministic rule
separates the two cases without inference, so per-CVE is the only grain the data supports.

How to measure:

```bash
jq -r '[.vulnerabilities[]|select(.product|test(" and |,|/"))]|length' \
  known_exploited_vulnerabilities.json   # -> 214
```

---

## 2. Natural key

**Decision:** `cve_id` is the natural, unique key. No surrogate key.

| Evidence | Value |
|---|---|
| `cve_id` uniqueness | **100%** (1,713/1,713) |
| Empty or null `cve_id` | **0** |
| Format | `CVE-YYYY-NNNNN`, MITRE standard |

**Why no surrogate key:** the natural key is already stable, global, unique and human-readable.
A surrogate would add 1,713 values while removing no ambiguity — cost without measurable return.
The pipeline validates uniqueness at two independent barriers: in `ingest.sh` before publishing,
and via the grain named query after publishing.

---

## 3. Raw → trusted transformation

**Decision:** the raw layer keeps the source document byte-for-byte; the trusted layer holds
line-delimited JSON (NDJSON), cleaned and typed.

| Evidence | Value |
|---|---|
| Raw | **1,727,984 bytes** (1 JSON object, nested array) |
| Trusted | **1,502,572 bytes** (1,713 lines) |
| Size delta | **−13.0%** |
| Average bytes per row | **877** |

**Why NDJSON rather than the original JSON:** Athena's `JsonSerDe` reads **one object per line**.
The CISA document is a single object containing an array of 1,713 items — pointing the table at it
would return **1 row**, not 1,713. The conversion is required for the table to be queryable at all;
it is not a stylistic preference.

**Why raw and trusted are separate:** the raw layer preserves proof of origin. Any result can be
rebuilt from it if a cleaning rule changes — impossible if cleaning were applied destructively to
the only stored copy.

---

## 4. Cleaning applied in the trusted layer

**Decision:** normalize whitespace and convert boolean-shaped strings into real booleans.

| Problem measured at source | Before | After |
|---|---|---|
| Stray whitespace in `vendorProject` / `product` | **18 rows (1.05%)** | **0** |
| `knownRansomwareCampaignUse` as text | `Known` 360 / `Unknown` 1,353 | boolean |
| `forensicTriage` as text | `Yes` 55 / `No` 1,658 | boolean |
| `cwes` without a precomputed count | array (0–4 items; **175** empty) | `cwe_count` int |

**Direct impact on the business question:** the value `"SimpleHelp "` (trailing space) appears in
**4 records**. Without `TRIM`, any future occurrence of a clean `"SimpleHelp"` would produce **two
distinct groups** under `GROUP BY vendor_project` — so the cleaning is not cosmetic: it is the
difference between a correct ranking and a silently wrong one.

**Why boolean and not string:** it enables `count_if(is_known_ransomware_use)` instead of comparing
magic strings, and removes the chance that a new feed value (say `"Likely"`) is counted as positive
by accident.

How to measure:

```bash
scripts/ingest.sh --keep-local   # the 5 quality gates print each number
```

---

## 5. Types declared in Glue

**Decision:** rich types where the format supports them (`boolean`, `int`, `array<string>`); dates
as ISO-8601 `string`.

| Evidence | Value |
|---|---|
| Explicitly declared columns | **15** |
| `date_added` outside ISO-8601 | **0 of 1,713** |
| Glue Crawlers used | **0** |

**Why dates stay `string`:** the backing file is text — in NDJSON every value is text. Forcing
`date` on the `JsonSerDe` turns any parse failure into a silent `NULL`, which would corrupt exactly
the 12-month filter the business question depends on. The query applies `date(date_added)`
explicitly, and the ingestion gate guarantees **0** malformed dates before publishing. Native date
typing arrives in Part 2 alongside Parquet, where the type is carried by the format itself.

**Why no Glue Crawler:** beyond being a course requirement, a Crawler costs **USD 0.44 per DPU-hour
with a 10-minute minimum per run** (≈ **USD 0.073** per crawl — AWS list price, *not* measured by
us). Against a stable 15-column schema it would spend that amount each run to rediscover a
structure we already know, while introducing type drift between runs. A schema declared in IaC
costs **USD 0.00** and is reviewable in code review.

---

## 6. Cost per Athena query

**Decision:** query the trusted layer directly, with no columnar conversion, accepting a full scan —
because the volume makes the optimization irrelevant at this stage.

| Evidence | Value |
|---|---|
| Trusted table size | **1,502,572 bytes** (~1.43 MB) |
| **Volume scanned by the query** (measured on AWS) | **3,005,144 bytes** |
| Athena minimum billed | **10,485,760 bytes** (10 MB) |
| Volume actually billed | **10,485,760 bytes** |
| Engine execution time | **790 ms** (998 ms total) |
| Price (us-east-1) | **USD 5.00 per TB** |
| **Cost per query** | **USD 0.00004768** |
| Queries per USD 1.00 | **≈ 20,973** |

**A finding from measuring:** the scanned volume is **exactly 2.00× the table size**
(3,005,144 = 2 × 1,502,572). The cause is the scalar subquery
`(SELECT count(*) FROM window_kev)` used to compute the concentration percentage: Athena does not
materialize the CTE, so it **reads the data twice** — once for the per-vendor aggregation, once for
the total.

This is exactly the kind of thing only measurement reveals. A projection from the file size would
have understated the scan by half. We did not rewrite the query, because the cost does not change
(still under the floor), but the behaviour is on record: at Part 2 volumes that double read starts
carrying a price and the query will need restructuring.

Reference execution: `f09cce66-077e-43cf-bbd4-587bd8af0bb7` (`docs/evidence/query-cost.json`).

Formula: `cost = max(scanned_bytes, 10,485,760) ÷ 1,099,511,627,776 × 5.00`

**The decisive number:** even scanning twice the file, the query reads 3,005,144 bytes and fits
**3.5 times** inside the 10 MB minimum billing unit. Any scan optimization — Parquet, partitioning, compression — would cut bytes read but
**would not cut a single cent**, because billing is already at the floor. Converting to Parquet at
this stage would cost engineering effort for a measured saving of **USD 0.00**. That is why Parquet
and partitioning belong to Part 2, once volume clears the billing minimum — not because they are
"too advanced".

Measured on AWS: `docs/evidence/query-cost.json`, field `cost_usd`, written by
`scripts/run_query.sh` from the `DataScannedInBytes` that Athena itself reports.

---

## 7. Cost guardrail on the WorkGroup

**Decision:** the Athena WorkGroup enforces `bytes_scanned_cutoff_per_query = 104,857,600` (100 MB)
and `enforce_workgroup_configuration = true`.

| Evidence | Value |
|---|---|
| Per-query cap | **100 MB** |
| Headroom over the current dataset | **≈ 70×** (1.43 MB → 100 MB) |
| Worst-case cost per query under the cap | **USD 0.000477** |
| An accidental 1 TB query | **cancelled by Athena** |

**Why 100 MB:** loose enough for the dataset to grow an order of magnitude without a false
positive, tight enough that a badly written `SELECT` or an accidental `JOIN` is cancelled before it
bills. `enforce_workgroup_configuration` stops a client from opting out of the cap or writing
results outside the controlled bucket.

---

## 8. Remote backend: S3 + DynamoDB

**Decision:** remote state in S3 with versioning, locking in a `PAY_PER_REQUEST` DynamoDB table.

| Evidence | Value |
|---|---|
| State bucket versioning | **enabled** (the only recovery path) |
| DynamoDB billing mode | **on-demand** |
| Writes per `apply` | **~2** (lock and unlock) |
| Estimated monthly locking cost | **< USD 0.01** |

**Alternative considered and rejected:** Terraform ≥ 1.10 offers native locking in S3 itself via
`use_lockfile = true`, dropping DynamoDB — today that is HashiCorp's recommendation for new
projects. It was not adopted here because **the course guide explicitly requires S3 + DynamoDB**,
and the grading criterion outweighs the modernization. The decision is recorded so it can be
defended during the presentation.

**Why `PAY_PER_REQUEST`:** provisioned capacity would bill for idle hours. The usage pattern is a
handful of writes per day, concentrated in seconds — on-demand is the only option whose cost tracks
that profile.

---

## 9. Terraform workspace

**Decision:** the `av1` workspace produces exactly the names the guide mandates; any other
workspace gets its name appended as a suffix.

| Evidence | Value |
|---|---|
| Names in workspace `av1` | `eda262-g07-lake-raw`, `eda262-g07-lake-trusted`, `eda262-g07-wg` |
| Names in workspace `dev` | `eda262-g07-lake-raw-dev`, ... |
| Possible name collisions | **0** |

**Why this matters, with a number:** S3 bucket names are unique **globally**, not per account.
Without the suffix, a parallel test by the group would take down or block the graded environment.
With it, test environments coexist safely, and an `apply` in the `default` workspace is **blocked**
by a `precondition` — it fails at `plan`, before creating any resource.

---

## 10. Teardown without orphaned resources

**Decision:** `force_destroy = true` on the buckets and the WorkGroup, with an active post-destroy
check.

| Evidence | Value |
|---|---|
| Resources checked after `destroy` | **5** (3 buckets, 1 Glue database, 1 WorkGroup) |
| Orphans tolerated | **0** |
| Athena results expired by lifecycle | **7 days** |

**Why verify instead of trust:** `terraform destroy` returns success even when a resource was
removed from state without being removed from the account. `scripts/destroy.sh` queries AWS for
each of the 5 resources after the destroy and **exits non-zero** if any still answers. The rubric's
criterion is verified, not assumed.

**Recorded caveat:** `force_destroy` deletes objects and versions without confirmation. It is
acceptable here because 100% of the data is re-ingestible from a public feed in one command. In an
environment with non-reproducible data, this decision would be the opposite of correct.

---

## Summary of numbers

| # | Decision | Decisive number |
|---|---|---|
| 1 | Grain: one row per CVE | 1,713 rows / 1,713 `cve_id` / **0** duplicates |
| 2 | Natural key `cve_id` | **100%** unique, **0** empty |
| 3 | Trusted as NDJSON | 1 object → **1,713** queryable rows |
| 4 | Whitespace cleaning | **18 → 0** dirty rows (1.05%) |
| 5 | Schema in IaC, no Crawler | **15** columns, **0** Crawlers, **USD 0.073** avoided per crawl |
| 6 | Cost per query | **USD 0.00004768** (10 MB floor) |
| 7 | WorkGroup guardrail | **100 MB**, ~70× the dataset |
| 8 | Backend S3 + DynamoDB | **< USD 0.01/month** |
| 9 | Workspace `av1` | **0** name collisions |
| 10 | Verified teardown | **5** resources checked, **0** orphans |

---

# Part 2 (AV2)

**Sources:** CISA KEV (dimension: the catalog of exploited CVEs) + FIRST EPSS (fact: one daily
snapshot with every CVE's probability of exploitation).
**Business question:** which vendors concentrate the actively exploited vulnerabilities (KEV) of
the last 12 months, how likely is each vendor's portfolio of exploited vulnerabilities to be
exploited (EPSS) over a 30-day window — and what does answering that cost in Athena?
**Scope of each measure:** the ranking counts exploited CVEs *added* in the last 12 months (recent
activity); the mean EPSS covers *all* of the vendor's exploited CVEs already listed that day
(current exposure), because an old exploited CVE stays a risk while unpatched systems exist.
**Reference window:** EPSS 2026-10-01 to 2026-10-30 (30 days); KEV `catalogVersion` 2026.10.30
(1,766 entries). AWS and local measurements share the window and the catalog: figures *measured
locally* come from the files the reference run wrote to raw. KEV changes during the week; every
load records the version it used (`kev_catalog_date`).

> **How to measure (source):** `scripts/part-2/profile_sources.sh --days 30 --to 2026-10-30
> --kev-file <catalog archived in raw>` — local DuckDB, no AWS account. Without `--kev-file` it
> downloads CISA's current catalog.
> **How to measure (AWS):** `scripts/part-2/run_all.sh` writes everything to `docs/evidence/part-2/`.
> **One run only:** every figure *measured on AWS* in this file, in the decks and in
> `docs/evidence/part-2/` comes from **one single execution** of `run_all.sh`, which deletes the
> previous run's evidence, stamps every file with its own `run_id`, and records the commit, region
> and window in `run-manifest.json`. `scripts/part-2/check_evidence_sync.sh` (a `verifica.sh`
> criterion) fails the delivery if any evidence file belongs to another run, or if this file and
> the decks do not quote that run's numbers.
> **The order is fixed:** `destroy.sh` (empty lake, so the apply starts from scratch) →
> `run_all.sh --to <day>` → this file and the decks quote the run until `check_evidence_sync.sh`
> passes → `verify_run.sh` (final acceptance, lake still up) → `destroy.sh` (closes the run and
> writes `destroy-check.json`).
> **Reference AWS run:** `run_id` **20261102T051658Z**, commit `02a03e3`, no uncommitted code
> changes (`run-manifest.json`). us-east-1, window 2026-10-01 to 2026-10-30 (30 partitions), KEV
> `catalog_date` 2026-10-30 (1,766 entries). Business question on refined in execution
> `754fe773-ddd2-459e-b6e7-8ee5ba8194a7`: 164,258 B scanned, 1,023 ms of engine time.
> Figures marked *measured on AWS* come from the
> `DataScannedInBytes` Athena itself reports. Figures marked *calculated* derive from measured
> bytes and Athena's billing rule (USD 5.00/TB, 10 MB minimum per query). A figure not measured yet
> carries an upper-case "pending" marker, and `verifica.sh` fails while any remains.

## 11. Volume source: EPSS as the fact, KEV as the dimension

| Evidence | Value |
|---|---|
| Whole KEV in Part 1 trusted | **1,502,572 B** — 7x below the 10 MB floor |
| Saving possible from Parquet/partitioning on KEV alone | **USD 0.00** (billing already at the floor) |
| EPSS per day (30-day average) | **389,499** rows, **2,733,786 B** gzip |
| EPSS, 30-day window | **11,684,958** rows, **82,013,574 B** gzip |
| Median EPSS on 2026-10-30: KEV CVEs vs all CVEs | **0.5359** vs **0.00626** (86x) |
| CVEs with EPSS >= 0.10 on 2026-10-30: KEV vs all | **75.3%** vs **4.4%** |

Part 2 grades cost reduction, and only volume above the billing floor makes it measurable. EPSS
adds information too: among exploited CVEs, it separates those still likely to be exploited. NVD
(393,026 CVEs) has no daily snapshot — and the daily snapshot is what gives a natural partition,
backfill and incremental loads.

## 12. Three layers: raw, trusted, refined

| Layer | Content | Size in S3 (30 days, measured on AWS) |
|---|---|---|
| raw | EPSS `.csv.gz` + original KEV (archive) + KEV as JSON lines | **85,268,552 B** in 32 objects |
| trusted | `epss_scores` + `kev_vulnerabilities`, Parquet ZSTD | **93,432,257 B** in 31 objects |
| refined | `vendor_exposure_daily`, vendor x day | **360,988 B** in 30 objects, 8,647 rows |

Raw keeps replay possible: if a cleaning rule changes, trusted is re-derived without
re-downloading. Refined is **259x** smaller than trusted and answers the question without redoing
an 11.7-million-row join on every execution. Trusted ended up larger than raw — decision 16 explains
why. The KEV document is archived byte-for-byte and also re-framed as JSON lines (1,826,755 B ->
1,428,223 B for catalog 2026.10.30), because the JSON SerDe reads one object per line. A `jq` gate
publishes only if the two are **identical value for value**.

## 13. Grain of every table

| Table | Grain declared in Glue | Measured on AWS (rows / distinct keys / duplicates) |
|---|---|---|
| `trusted.epss_scores` | one row per `(cve_id, snapshot_date)` | **11,684,958** / **11,684,958** / **0** |
| `trusted.kev_vulnerabilities` | one row per `(cve_id, catalog_date)` | **1,766** / **1,766** / **0** |
| `refined.vendor_exposure_daily` | one row per `(vendor_project, snapshot_date)` | **8,647** / **8,647** / **0** (~288 vendors/day) |

Measured by the `eda262-g07-grain-check` named query (`grain-check-result.csv`); the three counts
match exactly what DuckDB measured locally on the same files. Refined is per vendor because the
question is about vendors; per CVE it would hold 1,766 x 30 = **52,980** rows (6x more) to regroup
on every query. It stores `epss_sum` and `epss_scored_cves`, so a multi-day average is sum/count,
not an average of averages.

## 14. Keys

Composite natural keys, no surrogate, with the partition key inside the key: **0** duplicates in
11,684,958 rows; **0** malformed `cve_id`; **291** distinct vendors both case-sensitive and
case-insensitive (no spelling split in `GROUP BY`). Because the date is part of the key,
re-loading a day replaces exactly that day's rows — which is what makes decision 19 possible.

## 15. Partitioning

EPSS (trusted and refined) by `snapshot_date`, one day per partition; KEV by `catalog_date`, one
snapshot per partition; partition keys as ISO-8601 strings (lexical order = chronological order).

| Evidence (`epss` column, measured on AWS) | Value |
|---|---|
| 1-day query | **789,155 B** scanned |
| Same query over 30 days | **23,094,812 B** scanned |
| Saving on a 1-day query from partitioning | **29.3x** |
| One daily partition in S3 (all columns) | **~3.1 MB** (3,142,166 B on 2026-10-30) |

Rejected: **no partition** (a 1-day question reads the whole history; at 1 year, projected from
the 789,155 B/day measured, ~288 MB -> USD 0.00131 per query vs the USD 0.0000477 floor, 27x);
**monthly** (a 1-day question reads the whole month, up to 29.3x); **KEV by year of `date_added`**
(6 partitions of 186-555 rows in a **183,292 B** table — tiny files and no saving below the floor).
Raw tables use **partition projection**: loading a day is an S3 upload, with **0** `MSCK REPAIR`
and **0** partition-registration calls; trusted/refined partitions are registered by Athena's own
`INSERT INTO`.

## 16. Format: Parquet + ZSTD

`parquet.compression = ZSTD` on the table is honored by `INSERT INTO`: all 6 columns of the file
Athena wrote are ZSTD.

| One day (2026-10-30, 398,142 rows) | Bytes |
|---|---|
| CSV gzip (as published, raw) | **2,792,728** |
| **Parquet ZSTD written by Athena** (measured in S3) | **3,142,166** (+12.5%) |
| Parquet ZSTD written by DuckDB (local reference) | 2,738,644 |
| Parquet Snappy (DuckDB, local) | 5,317,635 |
| Columns the question reads in Athena's file (`cve_id` + `epss`) | **1,962,716** (62.5%) |

The finding, in two parts:

1. **Parquet did not shrink the file — it is 12.5% larger than the gzip CSV.** Athena's writer
   (`parquet-mr-trino`) stores `cve_id` without a dictionary (`PLAIN` encoding): **1,148,374 B**,
   2.3x DuckDB's 490,626 B. This only surfaced because we measured the file Athena wrote instead of
   trusting the local estimate.
2. **Parquet still lowers the cost, because cost is what is read, not what is stored.** The
   question reads 2 of 6 columns. Measured on AWS: **57,851,669 B** from trusted vs **83,441,797 B**
   from raw over the same window — **1.44x less**. CSV forces reading 100% of every row.

Parquet also brings **real types** (`double`, `date` — the promise of Part 1 decision 5) and
per-block statistics. Among codecs, ZSTD is 1.94x smaller than Snappy; Snappy's speed edge is
irrelevant on 3 MB files.

## 17. Cost target per query — in bytes, declared and met

**Declared target:** the business question reads **at most 16,384 B per day of its window**:
**491,520 B** over a 30-day window. Declared in Terraform (`cost_target_bytes_per_window_day`) and
tagged on the pipeline WorkGroup. `run_query.sh` fails if it is missed, and `verifica.sh` reads the
tag from the account and measures the query again in Athena.

**Why bytes, not dollars:** every query under 10 MB pays the same floor, USD 0.00004768. Refined
(164,258 B) and a single trusted day (789,155 B, decision 15) cost exactly the same although the
second reads 4.8x more. A dollar target would pass any layout under 10 MB; a byte target tells
the good layout from the bad one.

**Why per day of window:** the window is a parameter of the question. A fixed byte target would
mean nothing for a 1-day or a 1-year window; per day, it holds for any window. A query that stops
pruning partitions reads the whole history and misses the target as soon as the history grows
past 3x the window.

| Same question, 30-day window (measured on AWS) | Bytes scanned | Per day of window | Vs target | Engine time | Cost per execution |
|---|---|---|---|---|---|
| from raw (CSV + JSON) | **83,441,797** | 2,781,393 | **170x** over | 4,363 ms | USD 0.00037945 |
| from trusted (Parquet) | **57,851,669** | 1,928,389 | **118x** over | 3,421 ms | USD 0.00026308 |
| **from refined** | **164,258** | **5,475** | **3.0x** under | **1,023 ms** | USD 0.00004768 (floor) |

- **How the target was set:** 16 KiB per day, about 3x what refined reads per day (5,475 B in this
  run). The headroom absorbs growth in the number of vendors (291 in the catalog), while any read
  of the fact table still fails by two orders of magnitude: trusted is 118x over.
- **Raw vs refined:** **508x** fewer bytes but only **8.0x** in cost, because the 10 MB floor caps
  the saving. It is the effect Part 1 measured, and the reason the target is not in dollars.
- **The layer does not change the answer:** `run_query.sh` compared the three results and they
  were **identical**, byte for byte (`results_identical_across_layers = true`).
- **Estimate vs measurement:** DuckDB predicted 37,047 B for refined; Athena read 164,258 B (4.4x).
  Athena writes one file per daily partition (30 files of ~12 KB), each with its own footer and
  column headers.

## 18. Transformations as SQL in Athena (not Glue ETL, not local)

| Option | Cost of a 30-day load |
|---|---|
| **Athena INSERT** (chosen) | **82,013,574 B** scanned -> **USD 0.00037295** (measured on AWS) |
| Glue ETL (Spark), minimum run | 2 DPU x 1 min x USD 0.44/DPU-h = **USD 0.0147** (list price, not measured): **39x** |
| Local conversion (DuckDB/pyarrow) | USD 0 compute, but a dependency on the evaluator's machine and an 82 MB upload |

Every transformation is a versioned `INSERT INTO ... SELECT` in `parte-2/sql/etl/`. Each EPSS
file's metadata is spread to its rows with a window function rather than a self-join: Athena does
not materialize CTEs, and Part 1 measured exactly **2.00x** scan on a CTE read twice. On AWS, the
backfill `INSERT` scanned **82,013,574 B — exactly the byte total of the 30 gzip files**; a
self-join would have read 164.0 MB.

## 19. Idempotent ingestion: partition overwrite

Every write clears the partition's S3 prefix, then runs `INSERT INTO`; raw object keys are
deterministic.

| Evidence | Value |
|---|---|
| Re-load of 2026-10-30 through every layer: trusted rows before -> after | **398,142 -> 398,142** (measured on AWS) |
| Same re-load on refined | **291 -> 291** |
| What an append-only `INSERT` would produce | **796,284** and **582** rows (2x) |

`scripts/part-2/check_idempotency.sh` re-loads the newest day with the same commands a scheduled
run uses and writes `idempotency-check.json`. Rejected: `MERGE` on Iceberg — another table format,
outside the course scope; for append-only daily snapshots, partition overwrite gives the same
guarantee on Hive tables. A run that dies mid-way leaves an empty or partial partition, and
re-running converges.

## 20. Incremental loads and backfill

Each layer keeps its own **high-water mark** (its newest partition). The first load backfills 30
days; later loads take only what EPSS published after the mark. A gap behind the mark is reported
with the command that repairs it.

| Evidence | Value |
|---|---|
| 30-day backfill in one `INSERT` (measured on AWS) | **82,013,574 B** -> **USD 0.00037295** |
| Same 30 days as 30 daily `INSERT`s | 30 x 10 MB floor -> **USD 0.00143** *calculated* (**3.8x** more) |
| 1-day trusted `INSERT` (measured on AWS) | **2,792,728 B** -> under the floor -> USD 0.00004768 |
| 1-day refined `INSERT` (measured on AWS) | **1,977,629 B** -> under the floor -> USD 0.00004768 |
| One full incremental day (6 statements, all at the floor) | **USD 0.000286** *calculated* from the measurements above |
| Max batch per `INSERT` | 30 partitions (Athena allows 100) |

```bash
scripts/part-2/run_pipeline.sh --days 30   # first load (backfill)
scripts/part-2/run_pipeline.sh             # every later load (incremental)
scripts/part-2/run_all.sh --yes --days 30 --to YYYY-MM-DD   # reference run: declared window
```

One mark per layer means a run that died between trusted and refined is caught up by the next
run without re-processing trusted.

**Late data: a 0-day lateness window, backfill on demand.** In EPSS the event time is the
`score_date` declared inside the file. Raw keeps each file under the day in its name, and trusted
accepts a row only when the two dates match.

| Evidence | Value |
|---|---|
| Rows whose `score_date` differs from the file's day, over the 30 days (measured on AWS: source rows - trusted rows) | **0** of 11,684,958 |
| Partitions rewritten to recover a day that arrived late | **1** per layer (`ingest_epss.sh --from D --to D`, then `build_refined.sh --date D`) |

EPSS publishes one whole file per day, and no row arrives after its day, so the largest measured
lateness is 0 and so is the window. A day published late arrives whole and shows up as a gap behind
the mark; the incremental load warns and prints the backfill command, which rewrites only that
partition. An N-day window would rewrite N + 1 partitions on every run to cover a lateness the
source does not have.

Every load appends a line to
`docs/evidence/part-2/load-history.jsonl`, so the lake's growth up to the presentation is on
record.

## 21. Point-in-time correctness

On day D a CVE counts for its vendor only if CISA had already listed it on D (`date_added <= D`):
**35** of 1,766 KEV CVEs were listed after the window started (2026-10-01, measured locally). The
KEV dimension is a newer snapshot than the backfilled days; without the rule, the first day of the
window would count those 35 and the history would show exposure that did not exist yet.

## 22. Per-layer access: Lake Formation

| Persona | raw | trusted | refined |
|---|---|---|---|
| `data-engineer` | ✓ | ✓ | ✓ |
| `data-analyst` | — | ✓ | ✓ |
| `business-user` | — | — | ✓ |

| Evidence | Value |
|---|---|
| Persona x layer combinations tested live (measured on AWS) | **9 of 9** match the matrix: 6 granted, 3 denied by Lake Formation |
| `IAMAllowedPrincipals` default on new databases/tables | **removed** (0 entries) |
| S3 permissions of personas on lake buckets | **0** actions |
| IAM policy differences between personas | **0**, besides their own WorkGroup and prefix |

Identical IAM means a denied query can only have been denied by Lake Formation — the test proves
the mechanism. Without removing `IAMAllowedPrincipals`, any principal with IAM access would read
everything. Buckets are registered with a dedicated role, not the service-linked role (which
survives `destroy` as an orphan). Each persona has its own WorkGroup and results prefix (**4**
WorkGroups), as AWS recommends: Lake Formation does not govern query results or query history.
Lake Formation settings are account-wide: `deploy.sh` saves the originals and `destroy.sh`
restores them.

## 23. Cost guardrails on the WorkGroups

| WorkGroup | Per-query cap | Largest legitimate query | Headroom | Max cost |
|---|---|---|---|---|
| pipeline (`eda262-g07-wg`) | **200 MB** | question on raw, 30 days: 83.4 MB (measured) | 2.5x | USD 0.00095 |
| personas (3) | **100 MB** | question on trusted, 30 days: 57.9 MB (measured) | 1.8x | USD 0.00048 |

The persona headroom dropped from 2.8x (estimated) to 1.8x (measured) because of Athena's writer
encoding (decision 16). It covers the 30-day window; a 60-day analysis on trusted would be
cancelled — on purpose: long analyses belong on refined, which reads kilobytes.

## 24. Destroy with no orphans

The reference run starts from a destroyed lake and ends with a teardown checked in AWS.
`deploy.sh` records what the apply created (`apply-check.json`); `destroy.sh` checks **18**
resources in AWS after `terraform destroy` (4 buckets, 3 Glue databases, 4 WorkGroups, 4 IAM roles,
3 Lake Formation registrations), restores the Lake Formation settings and writes
`destroy-check.json`. Both files carry the run's `run_id`.

- Apply from scratch: **74 resources** created, with **0** in the state before the apply
  (`apply-check.json`).
- Acceptance before the teardown (`verify_run.sh`, lake still up): **44 of 44** criteria
  (`verifica-output.txt`).
- Teardown of the same run: `Destroy complete! Resources: 74 destroyed` — the same 74 the apply
  created (`destroy-check.json`).
- Orphans: **0**, and the account's Lake Formation settings restored.

**Why this order:** sections 4 and 5 of `verifica.sh` measure with the lake up, so the acceptance
comes before the teardown and the teardown's figure enters this file last. `verifica.sh
--repo-only`, the delivery check with the lake already gone, requires the same run's
`destroy-check.json`, with no orphans.

## 25. Analysis: minimum sample size and ties in the ranking

**Decision:** every EPSS average is printed next to its sample size (`epss_scored_cves`) and is
reported only when the vendor has at least **10** EPSS-scored CVEs on every day of the window
(`min_epss_sample_size`); below that the average is left empty. The ranking cuts by position
(`rank() <= 15`), keeping every tie, instead of `LIMIT 15`.

| Change of a vendor's average EPSS over 30 days (2026-10-01 to 2026-10-30) | n = 1–4 | n = 5–9 | n = 10–29 | n >= 30 |
|---|---|---|---|---|
| Vendors | 230 | 26 | 17 | 10 |
| Largest change | 0.69 | 0.57 | **0.09** | **0.04** |
| p90 of the change (approximate) | 0.02 | 0.15 | 0.04 | 0.04 |

Measured on AWS: `run_query.sh` runs `sql/analytics/epss_sample_stability.sql` on refined and
writes `epss-sample-stability.csv`. DuckDB, on the same run's files, gives the same four groups and
the same largest changes, and it is what names the vendors below.

**Why:**

- **n >= 10:** from 10 CVEs up, no vendor's average moved more than 0.09 in 30 days (Citrix, with
  27). Below 10 it moved up to 0.69 and 0.57: Widget Factory has 1 CVE, re-scored from 0.16 to
  0.85; Plex's average fell from 0.73 to 0.16 because its portfolio grew from 1 to 5 CVEs inside
  the window. Such an average describes one CVE, not the vendor. Part 1 showed a ratio like
  "3 of 7" without this care.
- **Why the tail, not the p90:** the p90 for n of 1 to 4 (0.02) is lower than for 10 to 29 (0.04),
  because most small vendors hold CVEs with a low, stable EPSS. The risk is the worst case: with
  n < 10 a vendor's average can move 0.69 in a month, 7.6x the worst case with n >= 10.
- **The tie `LIMIT 15` hid:** three vendors tie at rank 10 and eight at rank 13, with 4 new CVEs
  each. Ranks 1 to 10 fill 12 rows, so `LIMIT 15` would keep 3 of the 8 and drop 5, picked by the
  tie-breaker rather than by the data. Cutting by position lists all 20, and the 7 with n < 10
  appear without an average.
- **Exposure still drives the ranking:** the order is by exploited CVEs added in 12 months only, a
  count. The EPSS average is context, never a cut-off criterion.

## 26. Windows anchored on the data, not on `current_date`

**Decision:** no query uses `current_date`. The 12 months count from each `snapshot_date`
(decision 21); the EPSS window is an execution parameter; `run_query.sh` and `verifica.sh` take the
lake's newest partition as the last day, and the reference run pins that day with
`run_all.sh --to`.

| Evidence (KEV 2026.10.30 from the reference run, measured locally) | Value |
|---|---|
| CVEs added to KEV in the 12 months up to 2026-10-30, the window's last day | **313** |
| The same count with `current_date` on 2026-11-10 | **310**, on the same catalog |
| The same count with `current_date` on 2026-11-30, the original delivery date | **302**: 11 CVEs leave the window with no change in the data |

**Why:** with `current_date`, the same query over the same data answers differently depending on
the day it runs, and no run can be reproduced. The Part 1 query used
`date_add('month', -12, current_date)`. Anchored on the data, the answer changes only when the data
does.

## Summary (Part 2)

| # | Decision | Decisive number |
|---|---|---|
| 11 | EPSS as the fact | **82.0 MB** in 30 days vs 1.5 MB for all of KEV |
| 12 | Three layers | refined **259x** smaller than trusted in S3 |
| 13 | Grain | **0** duplicates in 11,684,958 rows (measured on AWS) |
| 14 | Composite natural keys | **291 = 291** vendors, no spelling split |
| 15 | Daily partition | **29.3x** fewer bytes for a 1-day query (measured on AWS) |
| 16 | Parquet + ZSTD | file 12.5% larger than CSV, yet the question reads **1.44x** less |
| 17 | Cost target in bytes | <= 16,384 B per day (491,520 B over 30 days); refined read **164,258 B** (3.0x under), trusted 118x over |
| 18 | SQL in Athena | **39x** cheaper than Glue ETL; backfill read raw once, not twice |
| 19 | Partition overwrite | re-load **398,142 -> 398,142** (append would double) |
| 20 | Incremental + backfill | one batch **3.8x** cheaper than daily loads |
| 21 | Point-in-time | **35** CVEs misplaced without the rule |
| 22 | Lake Formation | **9 of 9** combinations match, **0** S3 actions on personas |
| 23 | Guardrails | **200 MB** / **100 MB** (measured headroom 2.5x / 1.8x) |
| 24 | Destroy | **74** resources created from scratch and **74** destroyed, **0** orphans in 18 checked in AWS |
| 25 | Minimum sample | average only with n >= **10**: largest change 0.09 in 30 days, vs 0.69 with n < 10 |
| 26 | Window anchored on data | with `current_date`, the count would fall from 313 to **302** by delivery, with no new data |
