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
- `parte-1/` — Part 1 (AV1) Terraform: S3 + Glue Data Catalog + Athena WorkGroup (not yet created).
- `parte-2/` — Part 2 (AV2) Terraform, added later: partitioned Parquet, Lake Formation, idempotent ingestion.
- `verificacao/verifica.sh` — acceptance script the evaluator runs (not yet created).
- `DECISOES.md` — engineering decisions with measured numbers, at repo root (not yet created).

Mandatory layout per the course guide: Terraform lives at repo root in `parte-1/`/`parte-2/`, **not** nested
under any `academic/` subfolder.

## Constraints
- Compatibility: AWS resources named `eda262-g07-<resource>`, tagged `turma=eda262`, `grupo=g07`,
  `projeto=engenharia-de-dados`, per the course guide's mandatory naming convention.
- Security: no Crawler, no auth-heavy data source (CISA KEV is public, unauthenticated).
- Data: CISA KEV feed only for Part 1; NVD/EPSS explicitly out of scope for now.
- Operations: solo/group-run, not production — T0 tier (see `.agents/state/tier.md`).

## Sources of truth
- Code: this repository (Terraform, once written).
- API/schema: CISA KEV JSON feed (public, unauthenticated); trusted table schema declared in Glue, not crawled.
- Product requirements: `docs/COURSE_REQUIREMENTS.md` (structured rubric summary), `docs/project/guia_do_projeto.pdf`
  (original official PDF), `.agents/steering/product.md`.
