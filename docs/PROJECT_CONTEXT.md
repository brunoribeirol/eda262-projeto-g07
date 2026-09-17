# Project Context

## Purpose
EDA262 (CESAR School) group project, Part 1 / AV1: minimal AWS data engineering pipeline over public
vulnerability data (CISA KEV feed), answering one business question in Athena with measured query cost.
Serves the course deliverable for group g07; not a production system. See `.agents/steering/product.md`
for the full goal/non-goal breakdown and `docs/COURSE_REQUIREMENTS.md` for the official rubric (deadlines,
mandatory naming, deliverables, grading weights).

## Architecture
Raw CISA KEV JSON -> S3 (raw layer) -> Glue Data Catalog (schema declared by hand, no Crawler) -> one
trusted table (`kev_vulnerabilities`) -> Athena WorkGroup query answering the business question. All
infrastructure provisioned via Terraform, packaged as a module with a remote backend (S3 + DynamoDB) and a
workspace. No streaming, no partitioning/Parquet, no multi-layer medallion -- those are explicitly deferred
to Part 2.

## Main modules
- `parte-1/` — Part 1 (AV1) Terraform: S3 raw/trusted/results buckets, Glue Data Catalog and an Athena
  WorkGroup, packaged as the `modules/data-lake` module behind an S3 + DynamoDB remote backend
  (`parte-1/bootstrap/`) and a Terraform workspace.
- `parte-2/` — Part 2 (AV2) Terraform, added later: partitioned Parquet, Lake Formation, idempotent ingestion.
- `scripts/` — operational pipeline: `bootstrap.sh`, `deploy.sh`, `ingest.sh`, `run_query.sh`, `destroy.sh`,
  `build_pdf.sh`, and `run_all.sh` which chains them. `kev_to_trusted.jq` holds the raw→trusted
  transformation, isolated so it can be tested without AWS.
- `verificacao/verifica.sh` — acceptance script the evaluator runs; 25 criteria, prints PASSA/FALHA.
- `DECISOES.md` — engineering decisions with measured numbers, at repo root (`DECISIONS.md` mirrors it
  in English; the Portuguese file is the graded copy).
- `docs/presentation/` — slide decks (PT and EN) sharing a byte-identical stylesheet.
- `docs/evidence/` — output of a real run: query cost, business-question result, grain proof.

Mandatory layout per the course guide: Terraform lives at repo root in `parte-1/`/`parte-2/`, **not** nested
under any `academic/` subfolder.

## Constraints
- Compatibility: AWS resources named `eda262-g07-<resource>`, tagged `turma=eda262`, `grupo=g07`,
  `projeto=engenharia-de-dados`, per the course guide's mandatory naming convention.
- Security: no Crawler, no auth-heavy data source (CISA KEV is public, unauthenticated).
- Data: CISA KEV feed only for Part 1. EPSS is the agreed Part 2 fact table (KEV becomes a dimension);
  it is deliberately out of scope here, because KEV sits under Athena's 10 MB billing floor and the
  Part 1 cost argument depends on that.
- Operations: solo/group-run, not production — T0 tier (see `.agents/state/tier.md`).

## Sources of truth
- Code: this repository. The Terraform is written and passes `terraform validate` against aws
  provider 6.64.0.
- API/schema: CISA KEV JSON feed (public, unauthenticated); trusted table schema declared in Glue, not crawled.
- Product requirements: `docs/COURSE_REQUIREMENTS.md` (structured rubric summary), `docs/project/guia_do_projeto.pdf`
  (original official PDF), `.agents/steering/product.md`.
