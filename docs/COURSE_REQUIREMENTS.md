# Course Requirements — EDA262 (CESAR School, 2026.2)

Source of truth: `docs/project/guia_do_projeto.pdf` ("Guia do Projeto da Disciplina", v1.1, prof. Carlos Diego
Cavalcanti Pereira, cdcp@cesar.school). This file is a structured summary for quick reference — the PDF is
authoritative if anything here is ambiguous or out of date.

## Assessment shape

- 100% of the grade is one incremental group project, graded in two parts with the same rubric each time:
  `(AV1 + AV2) / 2`. Each part is worth 10 points.
- **AV1 (Part 1) due: Aula 16, 2026-09-30.**
- **AV2 (Part 2) due: Aula 30, 2026-11-30.**
- **Scenario validation deadline with the professor: Aula 13, 2026-09-21** (business domain + one clear
  analytical question over batch-processable, high-volume events, with plausible dirty data raw→trusted).
- Group is up to 6 people; one representative submits everything (repo link + presentation PDF) via Google
  Classroom, and fills the group spreadsheet. This repo is group **g07**.
- Late submissions start at grade 8.0 (institutional rule).

## Part 1 (AV1) — required scope

Provision, 100% in Terraform, a data lake that answers the group's business question and records the cost of
that query.

- S3 bucket + Glue Data Catalog + Athena workgroup, provisioned from scratch.
- Terraform packaged as a module, with a remote backend (S3 + DynamoDB) and a workspace.
- Schema declared in IaC — **not** inferred via Glue Crawler.
- One trusted table modeled, with the grain explicitly declared.
- The business question answered via Athena, with **cost per query measured**.
- Clean `terraform destroy` — no orphaned resources left behind.
- **Explicitly out of scope for AV1** (not taught yet, not graded if present anyway): Parquet, partitioning,
  multiple layers, idempotency.

## Part 2 (AV2) — extends Part 1, whole-course scope

- Trusted + refined layers in **partitioned Parquet**, with a declared and met cost-per-query target.
- Idempotent ingestion, with backfill of at least one partition.
- All three layers (raw/trusted/refined), with per-layer access permissions via **Lake Formation**.
- `DECISOES.md` finalized: grain, keys, partition, format, cost — each decision backed by a measured number.
- Optional bonus (not part of the 10 points): near-real-time ingestion via Kinesis Data Firehose.

## Mandatory naming and repo layout

- Git repo: `eda262-projeto-gNN` → this repo is `eda262-projeto-g07`.
- Delivery branch: always `main`. Delivery tags: `av1-entrega`, `av2-entrega`.
- AWS resource prefix: `eda262-g07-<resource>`. Layer buckets: `eda262-g07-lake-<layer>`.
- Scenario slug: lowercase-hyphen (e.g. `logistica-urbana`).
- **Terraform for each part lives at repo root in `parte-1/` and `parte-2/` — not nested under any
  `academic/` subfolder.** The evaluator's `verifica.sh` expects this exact layout.
- `DECISOES.md` at repo root.
- Acceptance script: `verificacao/verifica.sh` — must print `PASSA`/`FALHA` per criterion; run it before
  submitting.
- Presentation file: `apresentacao-parte-N-g07.pdf`.
- Mandatory AWS tags on every resource: `turma=eda262`, `grupo=g07`, `projeto=engenharia-de-dados`.

## Deliverables (both parts)

- Git repo with the Terraform that stands up the infra from zero, in a clean AWS account.
- `DECISOES.md` — every engineering decision justified with a measured number (grain, keys, partition,
  format, cost). A justification without a number does not score.
- `verificacao/verifica.sh` — runs in the evaluator's account, prints `PASSA`/`FALHA` per criterion.
- `README.md` — deploy/destroy steps, region, backend config, account setup.
- Presentation PDF (see below).
- Evidence: `verifica.sh` output + the Athena query result with measured cost.
- Account must be clean (infra bootstraps from scratch in the evaluator's account); a `destroy` that leaves
  orphaned resources fails that deliverable item.

## Presentation (15% of grade)

5 minutes to present (hard cutoff) + 2 minutes of Q&A, where the professor can pick a random group decision
and ask a specific member to defend it individually (checks that everyone participated in the engineering
decisions). Must cover: scenario + business question, the provisioned architecture, a live demo (apply from
scratch or recorded evidence, the Athena query + measured cost, and destroy), and the engineering decisions
with numbers.

Slide design rules: Arial font, one title per slide, ~5 bullets max, orange used sparingly as accent only,
square bullets, no 3D/shadows/generic stock imagery, monochrome charts with the main series in orange.

## Grading weights

- 60% artifact (infra deploys clean + `verifica.sh` all `PASSA` + destroy has no orphans).
- 25% `DECISOES.md` (measured numbers, not prose justification).
- 15% presentation + individual defense.

## How this interacts with the VulnPulse blueprint

This rubric is the non-negotiable floor for this repo's graded work. Professional polish (clean Terraform
modules, CI, docs, tests) is layered **on top of** this scope, never used to justify going **beyond** it.
The VulnPulse blueprint's heavier stack (Kafka, Flink, Iceberg, Spark, Kubernetes, OpenMetadata) has no entry
criterion here and must not be used for the graded artifact — it lives in a separate repository
(`vulnpulse`), not this one. See `.agents/steering/product.md` for the non-goals this implies.

Before implementing any AV1/AV2 work, re-check this file's current-phase requirements against whatever
ciclo/aula content has actually been covered in class — a requirement not yet taught is out of scope and must
not be added prematurely (e.g. don't add Parquet/partitioning before AV2 is unlocked). Confirm the scenario
was actually validated with the professor (see `docs/work/professor-pitch.md`) before treating it as final.
