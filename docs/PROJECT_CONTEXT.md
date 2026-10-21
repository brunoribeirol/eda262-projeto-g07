# Project Context

## Status
- **Part 1 (AV1):** submitted and presented on 2026-10-05; the delivered state is the signed tag
  `av1-entrega`.
- **Part 2 (AV2, due 2026-11-30):** implemented and first run on AWS on 2026-10-20 (`verifica.sh`
  37/39 on that run; the deck PDF is now committed, leaving only the final teardown, decision 24).
  Open as draft PR #1 (`feat/part-2-data-lake` → `main`). The lake stays up for daily incremental
  loads until the final cycle (destroy → apply from zero → destroy) right before delivery.

## Purpose
EDA262 (CESAR School) group project for group g07: an AWS data lake over public vulnerability data,
answering one business question in Athena with a measured query cost. Serves the course deliverable;
not a production system. See `docs/COURSE_REQUIREMENTS.md` for the official rubric (deadlines,
mandatory naming, deliverables, grading weights).

**Part 2 business question:** which vendors concentrate the actively exploited vulnerabilities of the
last 12 months, how likely is each vendor's portfolio of exploited vulnerabilities to be exploited
over a 30-day window — and what does answering that cost in Athena?

## Architecture (Part 2)
CISA KEV (dimension, weekly) + FIRST EPSS (fact, daily ~384k CVEs) → **raw** (bytes as published,
partition projection) → **trusted** (validated, typed Parquet ZSTD, daily partitions) → **refined**
(vendor × day aggregate). Transformations are SQL `INSERT INTO` in Athena, idempotent by partition
overwrite; loads are incremental from each layer's high-water mark. Lake Formation grants read
access per layer to three personas (data-engineer, data-analyst, business-user), each with an
isolated Athena WorkGroup. Everything is Terraform with an S3 + DynamoDB backend and workspace `av2`.

Part 1 (still on `main`, unchanged): raw KEV JSON → trusted NDJSON → one Glue table → Athena.

## Main modules
- `parte-2/` — Part 2 Terraform: `modules/data-lake` (buckets, Glue databases and tables declared as
  data, pipeline WorkGroup, named queries), `modules/governance` (Lake Formation registration, persona
  roles, grants, persona WorkGroups), Lake Formation account settings in `main.tf`, `bootstrap/`.
- `parte-2/sql/` — `etl/` (raw → trusted → refined INSERTs and post-load gates) and `analytics/`
  (business question on each layer, grain check, pruning probe).
- `scripts/part-2/` — lifecycle (bootstrap, deploy, destroy, run_all), pipeline (ingest_kev,
  ingest_epss, build_refined, run_pipeline), proofs (run_query, check_idempotency, check_access) and
  `profile_sources.sh` (offline DuckDB measurements). Shared helpers in `scripts/part-2/lib.sh`.
- `parte-1/`, `scripts/*.sh` — Part 1 as delivered.
- `verificacao/verifica.sh` — acceptance script (`--parte 1|2`, default 2) over `verificacao/part-1.sh`
  (25 criteria) and `verificacao/part-2.sh` (39 criteria); prints PASSA/FALHA.
- `DECISOES.md` — engineering decisions with measured numbers (1–10 Part 1, 11–24 Part 2), at repo
  root; `DECISIONS.md` mirrors it in English. The Portuguese file is the graded copy.
- `docs/presentation/` — decks for both parts (PT graded + EN, byte-identical stylesheet per part);
  `scripts/build_pdf.sh` renders them.
- `docs/evidence/` (Part 1) and `docs/evidence/part-2/` (Part 2) — output of real runs, including
  `load-history.jsonl`, one line per load.

Mandatory layout per the course guide: Terraform lives at repo root in `parte-1/`/`parte-2/`, **not**
nested under any `academic/` subfolder.

## Constraints
- Naming and tags: AWS resources named `eda262-g07-<resource>`, tagged `turma=eda262`, `grupo=g07`,
  `projeto=engenharia-de-dados`. Part 1 and Part 2 share the mandated bucket names, so only one can be
  deployed per account at a time.
- Lake Formation settings are account-wide: `deploy.sh` saves them, `destroy.sh` restores them.
  Deploy with an IAM user or role, never root.
- Scripts run on the stock macOS bash 3.2 and on Linux (no associative arrays, no empty-array
  expansion under `set -u`).
- Public repository: never commit the AWS account ID (`backend.hcl`, LF admin ARN) or course material.
- Operations: group-run, not production — T0 tier.

## Sources of truth
- Code: this repository. Both Terraform stacks pass `terraform validate` against aws provider 6.64.0.
- Data: CISA KEV JSON feed and FIRST EPSS daily CSV (public, unauthenticated).
- Requirements: `docs/COURSE_REQUIREMENTS.md` (structured summary), `docs/project/guia_do_projeto.pdf`
  (original official PDF).
