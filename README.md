# EDA262 — Course project, group g07 (Part 1 / AV1)

*Português: [README.pt-BR.md](README.pt-BR.md)*

Minimal AWS data lake, provisioned 100% in Terraform, over the public **CISA KEV**
(Known Exploited Vulnerabilities) catalog.

**Business question:** which vendors concentrate the most actively exploited vulnerabilities
over the last 12 months — and what does that query cost in Athena?

**Answer and measured cost:** `docs/evidence/` · **Decisions with numbers:**
[`DECISIONS.md`](DECISIONS.md) (English) / [`DECISOES.md`](DECISOES.md) (Portuguese, the graded copy)

> **A note on language.** Code, identifiers, comments and documentation are in English.
> Five names stay in Portuguese because the course guide defines them as the evaluator-facing
> contract, and the grader's own script expects them verbatim: `parte-1/`, `parte-2/`,
> `verificacao/verifica.sh`, `DECISOES.md`, and the `PASSA`/`FALHA` verdicts.

---

## Architecture

```
  CISA KEV (public feed, no authentication)
        │
        │  scripts/ingest.sh
        ▼
  ┌─────────────────────────┐
  │  eda262-g07-lake-raw    │   source document, byte-for-byte (1,722,859 B)
  └───────────┬─────────────┘
              │  raw → trusted: NDJSON, cleaned and typed
              │  5 data-quality gates (grain is validated before publishing)
              ▼
  ┌─────────────────────────┐
  │ eda262-g07-lake-trusted │   1,710 rows, one per CVE (1,497,926 B)
  └───────────┬─────────────┘
              │  schema declared in IaC — no Glue Crawler
              ▼
  ┌─────────────────────────┐
  │   Glue Data Catalog     │   eda262_g07_kev.kev_vulnerabilities (15 columns)
  └───────────┬─────────────┘
              ▼
  ┌─────────────────────────┐
  │  Athena WorkGroup       │   eda262-g07-wg · 100 MB per-query scan cap
  └───────────┬─────────────┘   measured cost: USD 0.00004768 per query
              ▼
     eda262-g07-athena-results   results expire after 7 days
```

| Component | Resource |
|---|---|
| Raw layer | `eda262-g07-lake-raw` |
| Trusted layer | `eda262-g07-lake-trusted` |
| Athena results | `eda262-g07-athena-results` |
| Catalog | `eda262_g07_kev` · table `kev_vulnerabilities` |
| WorkGroup | `eda262-g07-wg` |
| Terraform state | `eda262-g07-tfstate-<account-id>` + `eda262-g07-tflock` |

Every resource carries the mandatory tags `turma=eda262`, `grupo=g07`,
`projeto=engenharia-de-dados` through the provider's `default_tags` — a new resource cannot
forget them.

---

## Prerequisites

| Tool | Minimum | Purpose |
|---|---|---|
| Terraform | 1.5 | provisioning |
| AWS CLI | 2.x | authentication and operation |
| `jq` | 1.6 | raw → trusted transformation |
| `curl` | any | feed download |

An AWS account allowed to create S3, Glue, Athena and DynamoDB resources.
**Default region: `us-east-1`** (the Athena price quoted in `DECISIONS.md` is that region's).

```bash
aws configure --profile de
aws sts get-caller-identity --profile de
```

---

## Deploy from scratch

### One command

```bash
scripts/run_all.sh --profile de
```

Provisions, ingests, measures the cost, renders the decks and runs the verification — producing
every piece of evidence the rubric asks for. It confirms before creating any AWS resource.
Add `--destroy-after` to tear everything down at the end.

### Or step by step

Four commands, in order. Each one validates the previous step before proceeding.

```bash
# 1. Create the remote backend (state bucket + lock table) and generate parte-1/backend.hcl.
#    Run once per AWS account.
scripts/bootstrap.sh --profile de --region us-east-1

# 2. Provision the data lake in the 'av1' delivery workspace.
scripts/deploy.sh --profile de --region us-east-1

# 3. Ingest the KEV catalog: raw → trusted, through the quality gates.
scripts/ingest.sh --profile de

# 4. Run the business question and measure the real cost in Athena.
scripts/run_query.sh --profile de
```

To review before applying: `scripts/deploy.sh --profile de --plan-only`.

### What each step produces

| Step | Output |
|---|---|
| `bootstrap.sh` | `parte-1/backend.hcl` (gitignored — it embeds the account ID) |
| `deploy.sh` | buckets, catalog, table and WorkGroup |
| `ingest.sh` | `docs/evidence/ingest-metrics.json` |
| `run_query.sh` | `docs/evidence/business-question-result.csv`, `query-cost.json`, `grain-check-result.csv` |

---

## Verification

```bash
verificacao/verifica.sh --profile de     # repository + AWS resources
verificacao/verifica.sh --repo-only      # static criteria only, no AWS
```

Prints `PASSA`/`FALHA` per criterion and exits `0` only if all of them pass.

---

## Teardown

```bash
scripts/destroy.sh --profile de                     # remove the data lake
scripts/destroy.sh --profile de --include-backend   # also remove the backend (irreversible)
```

The script does not trust Terraform's exit code: after `destroy` it queries AWS for each of the
5 resources and **fails** if any still exists. A teardown that leaves orphans fails the rubric,
so it is verified rather than assumed.

---

## Repository layout

```
parte-1/                  Part 1 Terraform (name mandated by the course guide)
  bootstrap/              remote backend (local state — breaks the chicken-and-egg)
  modules/data-lake/      the module: S3 + Glue + Athena
    locals.tf             trusted table schema, declared as data
    queries.tf            business-question SQL, versioned in IaC
  main.tf                 calls the module; blocks the 'default' workspace
scripts/
  kev_to_trusted.jq       raw → trusted transformation (testable standalone)
  bootstrap.sh            creates the backend
  deploy.sh               provisions
  ingest.sh               ingests, behind 5 quality gates
  run_query.sh            queries and measures cost
  destroy.sh              destroys and verifies nothing was orphaned
  build_pdf.sh            renders the slide decks to PDF
  run_all.sh              runs the whole pipeline end to end
verificacao/verifica.sh   acceptance script (PASSA/FALHA — name mandated)
DECISIONS.md              engineering decisions, measured (English)
DECISOES.md               same decisions in Portuguese — the graded copy
docs/
  presentation/           slide deck (EN + PT)
  evidence/               output produced by a real run
```

---

## Design decisions in one line each

Full detail with numbers in [`DECISIONS.md`](DECISIONS.md).

- **Grain:** one row per CVE — 1,710 rows, 1,710 distinct `cve_id`, **0** duplicates.
- **No Glue Crawler:** 15 columns declared in IaC; avoids ~USD 0.073 per crawl and type drift
  between runs.
- **Cost per query:** **USD 0.00004768** — the query scans 3.0 MB and fits 3.5x inside
  Athena's 10 MB minimum billing unit.
- **No Parquet in this phase:** billing is already at the floor, so converting would save
  **USD 0.00**. It belongs to Part 2, once volume clears the minimum.
- **Workspace `av1`:** produces the mandated names; other workspaces get a suffix, so globally
  unique bucket names never collide.

---

## Known limitations (Part 1 scope)

Out of scope by decision, not by omission — these arrive in Part 2:

- No Parquet, no partitioning, no refined layer.
- Ingestion is **not idempotent**: re-running `ingest.sh` overwrites the trusted object.
- No Lake Formation: access control is plain S3/IAM.
- `date_added` and `due_date` are ISO-8601 `string`, not `date` — see `DECISIONS.md` §5.
