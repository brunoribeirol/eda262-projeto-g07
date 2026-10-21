# EDA262 — Course project, group g07

*Português: [README.pt-BR.md](README.pt-BR.md)*

An AWS data lake, provisioned 100% in Terraform, over two public security feeds:
**CISA KEV** (vulnerabilities known to be exploited) and **FIRST EPSS** (the daily probability
that each CVE will be exploited).

**Business question (Part 2):** which vendors concentrate the actively exploited
vulnerabilities of the last 12 months, how likely are those vulnerabilities to be exploited over
a 30-day window — and what does answering that cost in Athena?

**Decisions with numbers:** [`DECISIONS.md`](DECISIONS.md) (English) /
[`DECISOES.md`](DECISOES.md) (Portuguese, the graded copy) · **Evidence:** `docs/evidence/part-2/`

> **Status.** Part 1 (AV1) was submitted and presented on 2026-10-05 — signed tag
> [`av1-entrega`](https://github.com/brunoribeirol/eda262-projeto-g07/tree/av1-entrega).
> Part 2 (AV2, due 2026-11-30) is implemented in `parte-2/` and `scripts/part-2/`. First AWS run on
> 2026-10-20: cost target met (162,943 B scanned, USD 0.00004768), identical answers on the three
> layers, idempotency and the 9-cell access matrix proven. The lake stays up for daily incremental
> loads until the presentation; only the final teardown remains to be measured.

> **A note on language.** Code, identifiers, comments and documentation are in English.
> Five names stay in Portuguese because the course guide defines them as the evaluator-facing
> contract, and the grader's own script expects them verbatim: `parte-1/`, `parte-2/`,
> `verificacao/verifica.sh`, `DECISOES.md`, and the `PASSA`/`FALHA` verdicts.

---

## Part 2 architecture

```
  CISA KEV (JSON, ~weekly)          FIRST EPSS (gzip CSV, daily, ~384k CVEs)
          │                                   │
          │ ingest_kev.sh                     │ ingest_epss.sh   (backfill or incremental)
          ▼                                   ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ RAW      eda262-g07-lake-raw       bytes exactly as published │  Glue: eda262_g07_raw
  │          kev_records/  epss_scores/  (partition projection)   │
  └───────────────────────────┬──────────────────────────────────┘
                              │ Athena INSERT INTO, partition overwrite
                              ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ TRUSTED  eda262-g07-lake-trusted   validated, typed           │  Glue: eda262_g07_trusted
  │          kev_vulnerabilities  (cve_id, catalog_date)          │
  │          epss_scores          (cve_id, snapshot_date)         │  Parquet + ZSTD
  └───────────────────────────┬──────────────────────────────────┘
                              │ build_refined.sh (point-in-time join)
                              ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ REFINED  eda262-g07-lake-refined   business-ready aggregate   │  Glue: eda262_g07_refined
  │          vendor_exposure_daily (vendor_project, snapshot_date)│  Parquet + ZSTD
  └───────────────────────────┬──────────────────────────────────┘
                              ▼
     Athena: pipeline WorkGroup + one WorkGroup per persona (results isolated)

  Lake Formation decides who reads which layer:
     data-engineer → raw, trusted, refined   data-analyst → trusted, refined   business-user → refined
```

| Component | Resource |
|---|---|
| Layers | `eda262-g07-lake-raw`, `-lake-trusted`, `-lake-refined` |
| Catalog | `eda262_g07_raw`, `eda262_g07_trusted`, `eda262_g07_refined` (5 tables, schema in IaC, no Crawler) |
| Athena | `eda262-g07-wg` (pipeline) + `eda262-g07-wg-<persona>` × 3; results in `eda262-g07-athena-results` |
| Access | Lake Formation: 3 registered buckets, 3 persona roles, grants per layer |
| Terraform state | `eda262-g07-tfstate-<account-id>` + `eda262-g07-tflock` (key `eda262-g07/parte-2/...`) |

Every resource carries `turma=eda262`, `grupo=g07`, `projeto=engenharia-de-dados` through the
provider's `default_tags`.

---

## Prerequisites

| Tool | Minimum | Purpose |
|---|---|---|
| Terraform | 1.5 | provisioning |
| AWS CLI | 2.x | authentication and operation |
| `jq`, `curl`, `gzip`, `awk` | any | downloads, gates, evidence |
| `duckdb` | 1.x | *optional* — only `profile_sources.sh`, the offline measurements |

- **Region:** `us-east-1` by default (the Athena price in `DECISOES.md` is that region's).
- **Credentials:** an IAM user or role allowed to create S3, Glue, Athena, IAM, Lake Formation and
  DynamoDB resources. **Not the root user** — Lake Formation cannot use root as an administrator.
- **Shell:** the scripts run on the stock macOS `bash` 3.2 and on Linux.

```bash
aws configure                 # or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
aws sts get-caller-identity   # must return your account
```

Every script uses the default AWS credential chain; add `--profile <name>` to any of them to use a
named profile.

> **Lake Formation is account-wide.** Deploying replaces the account's Lake Formation settings: the
> deployer becomes the only data lake administrator, and new databases/tables stop inheriting the
> `IAMAllowedPrincipals` grant. `deploy.sh` saves the previous settings first and `destroy.sh` puts
> them back. Use a dedicated or clean account, as the course guide requires.

---

## Deploy and run Part 2

### One command

```bash
scripts/part-2/run_all.sh
```

It provisions, loads the lake (a 30-day backfill on the first run, incremental after that),
answers the question with its measured cost, proves idempotency and the access matrix, and runs
the acceptance script — writing every piece of evidence to `docs/evidence/part-2/`. It confirms
before creating anything. Add `--destroy-after` to tear everything down at the end.

### Or step by step

```bash
# 1. Remote backend (state bucket + lock table) -> parte-2/backend.hcl. Once per account;
#    reuses the Part 1 backend if it already exists.
scripts/part-2/bootstrap.sh --region us-east-1

# 2. Provision the lake in the 'av2' delivery workspace.
scripts/part-2/deploy.sh --region us-east-1

# 3. First load: KEV snapshot + the last 30 EPSS days (backfill) + refined.
scripts/part-2/run_pipeline.sh --days 30

# 4. Business question, its measured cost, and the same question on trusted/raw for comparison.
scripts/part-2/run_query.sh

# 5. Proofs: re-loading a day changes nothing; each persona reads only its layers.
scripts/part-2/check_idempotency.sh
scripts/part-2/check_access.sh
```

To review before applying: `scripts/part-2/deploy.sh --plan-only`.

### Keeping the lake up to date (incremental loads)

EPSS publishes a new file every day. Every later run only loads what is new:

```bash
scripts/part-2/run_pipeline.sh                       # incremental: from each layer's high-water mark
scripts/part-2/ingest_epss.sh --incremental --dry-run  # just show which days would be loaded
scripts/part-2/ingest_epss.sh --from 2026-10-01 --to 2026-10-03   # repair or backfill a range
```

Each layer's high-water mark is its newest partition. A run that dies half-way is fixed by running
again: every write overwrites its own partition, so nothing is ever duplicated. Each load appends a
line to `docs/evidence/part-2/load-history.jsonl`.

### What each step produces

| Step | Evidence in `docs/evidence/part-2/` |
|---|---|
| `ingest_kev.sh` | `kev-ingest.json` |
| `ingest_epss.sh` | `epss-ingest.json`, `load-history.jsonl` |
| `build_refined.sh` | `refined-build.json`, `load-history.jsonl` |
| `run_query.sh` | `business-question-result.csv`, `query-cost.json`, `cost-comparison.json`, `grain-check-result.csv` |
| `check_idempotency.sh` | `idempotency-check.json` |
| `check_access.sh` | `access-matrix.json` |
| `run_all.sh` | `verifica-output.txt` |

---

## Verification

```bash
verificacao/verifica.sh                 # Part 2: repository + AWS resources
verificacao/verifica.sh --repo-only     # static criteria only, no AWS
verificacao/verifica.sh --parte 1       # the Part 1 (AV1) criteria, as graded
```

Prints `PASSA`/`FALHA` per criterion and exits `0` only if all of them pass. Part 2 adds three
layers, Parquet and partitions, the cost target, backfill, idempotency, and the Lake Formation
grants checked persona by persona.

---

## Teardown

```bash
scripts/part-2/destroy.sh                     # remove the lake and restore Lake Formation settings
scripts/part-2/destroy.sh --include-backend   # also remove the backend (irreversible)
```

After `terraform destroy`, the script checks AWS for each of the **18** resources (buckets,
databases, WorkGroups, IAM roles, Lake Formation registrations) and **fails** if any still exists.

---

## Repository layout

```
parte-2/                    Part 2 Terraform (name mandated by the course guide)
  bootstrap/                remote backend (local state -- breaks the chicken-and-egg)
  main.tf                   Lake Formation account settings + the two modules
  variables.tf              includes `personas`: the per-layer access policy, as data
  modules/data-lake/        S3 layers, Glue databases/tables (schemas in locals.tf), Athena
  modules/governance/       Lake Formation registration and grants, persona roles and WorkGroups
  sql/etl/                  raw -> trusted -> refined INSERTs and post-load gates
  sql/analytics/            business question (3 layers), grain check, pruning probe
scripts/part-2/
  bootstrap.sh deploy.sh destroy.sh run_all.sh     lifecycle
  ingest_kev.sh ingest_epss.sh build_refined.sh    pipeline steps (each idempotent)
  run_pipeline.sh                                  backfill or incremental, end to end
  run_query.sh                                     business question + measured cost
  check_idempotency.sh check_access.sh             proofs
  profile_sources.sh                               offline source measurements (DuckDB)
verificacao/                verifica.sh (entry point) + part-1.sh / part-2.sh criteria
DECISOES.md / DECISIONS.md  engineering decisions with measured numbers (PT graded / EN)
docs/evidence/part-2/       evidence produced by a real run
parte-1/, scripts/*.sh      Part 1 (AV1), as delivered -- see below
```

---

## Part 1 (AV1) — delivered

Minimal lake over the CISA KEV catalog: raw + trusted (NDJSON), one Glue table declared in IaC,
Athena WorkGroup with a 100 MB cap, measured cost **USD 0.00004768** per query. Decisions 1–10 in
[`DECISIONS.md`](DECISIONS.md); evidence in `docs/evidence/`.

Part 1 and Part 2 use the same mandated bucket names, so only one of them can be deployed in an
account at a time. To reproduce Part 1 exactly as graded, check out the tag `av1-entrega`, or on
`main`:

```bash
scripts/run_all.sh                      # bootstrap, deploy, ingest, query, verify (Part 1)
scripts/destroy.sh                      # teardown, verified
verificacao/verifica.sh --parte 1
```

---

## Known limitations

- The teardown figure of decision 24 (`PENDENTE` in `DECISOES.md`) is measured on the final destroy.
- One Lake Formation configuration per account: do not deploy two workspaces of `parte-2/` in the
  same account.
- Refined days built incrementally use the KEV snapshot current at build time (recorded per row in
  `kev_catalog_date`). Rebuilding a range with a single snapshot is an explicit full refresh:
  `scripts/part-2/build_refined.sh --from <day> --to <day>`.
