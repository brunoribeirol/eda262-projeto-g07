# Engineering decisions — EDA262 Part 1 (AV1), group g07

*Português: [DECISOES.md](DECISOES.md) — that is the copy the course grades.*

Every decision below is justified by a measured number, not by prose. The *how to measure*
snippets reproduce each number on any machine.

**Source:** public CISA KEV (Known Exploited Vulnerabilities) catalog.
**Reference snapshot:** `catalogVersion` **2026.09.16**, holding **1,713** records.
**Business question:** which vendors concentrate the most actively exploited vulnerabilities
over the last 12 months, and what does that query cost in Athena?

> Figures marked **measured at source** were taken directly from the feed and reproduce offline.
> Figures marked **measured on AWS** are written to `docs/evidence/query-cost.json` by
> `scripts/run_query.sh` during deployment and must be checked after `apply`.

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
| Engine execution time | **555 ms** (753 ms total) |
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

Reference execution: `03e82f7a-6abf-4205-92a4-0cddb5874d46` (`docs/evidence/query-cost.json`).

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
