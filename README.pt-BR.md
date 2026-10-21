# EDA262 — Projeto da disciplina, grupo g07

*English: [README.md](README.md) — versão principal.*

Data lake na AWS, provisionado 100% em Terraform, sobre dois feeds públicos de segurança:
**CISA KEV** (vulnerabilidades sabidamente exploradas) e **FIRST EPSS** (a probabilidade diária de
cada CVE ser explorada).

**Pergunta de negócio (Parte 2):** quais fabricantes concentram as vulnerabilidades ativamente
exploradas dos últimos 12 meses, qual a probabilidade de exploração do portfólio de
vulnerabilidades exploradas de cada um ao longo de uma janela de 30 dias — e quanto custa
responder isso no Athena?

**Decisões com números:** [`DECISOES.md`](DECISOES.md) (cópia avaliada) /
[`DECISIONS.md`](DECISIONS.md) (inglês) · **Evidências:** `docs/evidence/part-2/`

> **Status.** A Parte 1 (AV1) foi entregue e apresentada em 05/10/2026 — tag assinada
> [`av1-entrega`](https://github.com/brunoribeirol/eda262-projeto-g07/tree/av1-entrega).
> A Parte 2 (AV2, prazo 30/11/2026) está implementada em `parte-2/` e `scripts/part-2/`. Primeira
> execução na AWS em 20/10/2026: meta de custo cumprida (162.943 B varridos, USD 0,00004768),
> respostas idênticas nas três camadas, idempotência e matriz de acesso de 9 células comprovadas.
> O lake fica no ar para as cargas incrementais diárias até a apresentação; falta medir apenas a
> destruição final.

> **Sobre idioma.** Código, identificadores, comentários e documentação estão em inglês.
> Cinco nomes permanecem em português porque o guia da disciplina os define como contrato com o
> avaliador, e o script dele espera exatamente esses nomes: `parte-1/`, `parte-2/`,
> `verificacao/verifica.sh`, `DECISOES.md` e os veredictos `PASSA`/`FALHA`.

---

## Arquitetura da Parte 2

```
  CISA KEV (JSON, ~semanal)          FIRST EPSS (CSV gzip, diário, ~384 mil CVEs)
          │                                   │
          │ ingest_kev.sh                     │ ingest_epss.sh   (backfill ou incremental)
          ▼                                   ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ RAW      eda262-g07-lake-raw       bytes exatamente como      │  Glue: eda262_g07_raw
  │          kev_records/ epss_scores/ publicados (projeção)      │
  └───────────────────────────┬──────────────────────────────────┘
                              │ INSERT INTO no Athena, sobrescrita de partição
                              ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ TRUSTED  eda262-g07-lake-trusted   validado e tipado          │  Glue: eda262_g07_trusted
  │          kev_vulnerabilities  (cve_id, catalog_date)          │
  │          epss_scores          (cve_id, snapshot_date)         │  Parquet + ZSTD
  └───────────────────────────┬──────────────────────────────────┘
                              │ build_refined.sh (join point-in-time)
                              ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ REFINED  eda262-g07-lake-refined   agregado pronto p/ negócio │  Glue: eda262_g07_refined
  │          vendor_exposure_daily (vendor_project, snapshot_date)│  Parquet + ZSTD
  └───────────────────────────┬──────────────────────────────────┘
                              ▼
     Athena: WorkGroup do pipeline + um WorkGroup por perfil (resultados isolados)

  O Lake Formation decide quem lê cada camada:
     data-engineer → raw, trusted, refined   data-analyst → trusted, refined   business-user → refined
```

| Componente | Recurso |
|---|---|
| Camadas | `eda262-g07-lake-raw`, `-lake-trusted`, `-lake-refined` |
| Catálogo | `eda262_g07_raw`, `eda262_g07_trusted`, `eda262_g07_refined` (5 tabelas, schema em IaC, sem Crawler) |
| Athena | `eda262-g07-wg` (pipeline) + `eda262-g07-wg-<perfil>` × 3; resultados em `eda262-g07-athena-results` |
| Acesso | Lake Formation: 3 buckets registrados, 3 papéis de perfil, grants por camada |
| Estado do Terraform | `eda262-g07-tfstate-<account-id>` + `eda262-g07-tflock` (chave `eda262-g07/parte-2/...`) |

Todo recurso carrega `turma=eda262`, `grupo=g07`, `projeto=engenharia-de-dados` pelo
`default_tags` do provider.

---

## Pré-requisitos

| Ferramenta | Mínimo | Uso |
|---|---|---|
| Terraform | 1.5 | provisionamento |
| AWS CLI | 2.x | autenticação e operação |
| `jq`, `curl`, `gzip`, `awk` | qualquer | downloads, barreiras de qualidade, evidências |
| `duckdb` | 1.x | *opcional* — só o `profile_sources.sh`, as medições offline |

- **Região:** `us-east-1` por padrão (o preço do Athena no `DECISOES.md` é dessa região).
- **Credenciais:** um usuário ou papel IAM com permissão para criar recursos de S3, Glue, Athena,
  IAM, Lake Formation e DynamoDB. **Não use o usuário root**: o Lake Formation não aceita root
  como administrador.
- **Shell:** os scripts rodam no `bash` 3.2 padrão do macOS e no Linux.

```bash
aws configure                 # ou exporte AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
aws sts get-caller-identity   # deve retornar a sua conta
```

Os scripts usam a cadeia padrão de credenciais da AWS; acrescente `--profile <nome>` a qualquer
um deles para usar um perfil nomeado.

> **O Lake Formation vale para a conta inteira.** O deploy substitui as configurações do Lake
> Formation da conta: quem faz o deploy vira o único administrador do data lake, e bancos/tabelas
> novos deixam de herdar o grant `IAMAllowedPrincipals`. O `deploy.sh` salva as configurações
> anteriores e o `destroy.sh` as restaura. Use uma conta dedicada ou limpa, como pede o guia.

---

## Deploy e execução da Parte 2

### Um comando

```bash
scripts/part-2/run_all.sh
```

Provisiona, carrega o lake (backfill de 30 dias na primeira vez, incremental depois), responde a
pergunta com o custo medido, prova a idempotência e a matriz de acesso, e roda o script de aceite.
Toda evidência vai para `docs/evidence/part-2/`. Pede confirmação antes de criar qualquer recurso.
Acrescente `--destroy-after` para destruir tudo ao final.

### Ou passo a passo

```bash
# 1. Backend remoto (bucket de estado + tabela de lock) -> parte-2/backend.hcl. Uma vez por conta;
#    reaproveita o backend da Parte 1 se ele ainda existir.
scripts/part-2/bootstrap.sh --region us-east-1

# 2. Provisiona o lake no workspace de entrega 'av2'.
scripts/part-2/deploy.sh --region us-east-1

# 3. Primeira carga: snapshot do KEV + últimos 30 dias de EPSS (backfill) + refined.
scripts/part-2/run_pipeline.sh --days 30

# 4. Pergunta de negócio, custo medido, e a mesma pergunta na trusted/raw para comparação.
scripts/part-2/run_query.sh

# 5. Provas: recarregar um dia não muda nada; cada perfil lê só as suas camadas.
scripts/part-2/check_idempotency.sh
scripts/part-2/check_access.sh
```

Para revisar antes de aplicar: `scripts/part-2/deploy.sh --plan-only`.

### Mantendo o lake atualizado (carga incremental)

O EPSS publica um arquivo novo por dia. Toda execução seguinte carrega só o que é novo:

```bash
scripts/part-2/run_pipeline.sh                         # incremental: a partir da marca d'água de cada camada
scripts/part-2/ingest_epss.sh --incremental --dry-run  # só mostra quais dias seriam carregados
scripts/part-2/ingest_epss.sh --from 2026-10-01 --to 2026-10-03   # reparo ou backfill de um intervalo
```

A marca d'água (*high-water mark*) de cada camada é a sua partição mais nova. Uma execução que
morre no meio é corrigida rodando de novo: toda escrita sobrescreve a própria partição, então nada
é duplicado. Cada carga acrescenta uma linha a `docs/evidence/part-2/load-history.jsonl`.

### O que cada etapa produz

| Etapa | Evidência em `docs/evidence/part-2/` |
|---|---|
| `ingest_kev.sh` | `kev-ingest.json` |
| `ingest_epss.sh` | `epss-ingest.json`, `load-history.jsonl` |
| `build_refined.sh` | `refined-build.json`, `load-history.jsonl` |
| `run_query.sh` | `business-question-result.csv`, `query-cost.json`, `cost-comparison.json`, `grain-check-result.csv` |
| `check_idempotency.sh` | `idempotency-check.json` |
| `check_access.sh` | `access-matrix.json` |
| `run_all.sh` | `verifica-output.txt` |

---

## Verificação

```bash
verificacao/verifica.sh                 # Parte 2: repositório + recursos na AWS
verificacao/verifica.sh --repo-only     # apenas critérios estáticos, sem AWS
verificacao/verifica.sh --parte 1       # os critérios da Parte 1 (AV1), como avaliados
```

Imprime `PASSA`/`FALHA` por critério e só sai com `0` se todos passarem. A Parte 2 acrescenta as
três camadas, Parquet e partições, a meta de custo, o backfill, a idempotência e os grants do Lake
Formation conferidos perfil a perfil.

---

## Destruição

```bash
scripts/part-2/destroy.sh                     # remove o lake e restaura as configurações do Lake Formation
scripts/part-2/destroy.sh --include-backend   # também remove o backend (irreversível)
```

Depois do `terraform destroy`, o script consulta a AWS por cada um dos **18** recursos (buckets,
bancos, WorkGroups, papéis IAM, registros no Lake Formation) e **falha** se algum ainda existir.

---

## Estrutura do repositório

```
parte-2/                    Terraform da Parte 2 (nome exigido pelo guia)
  bootstrap/                backend remoto (estado local -- quebra o ovo-e-galinha)
  main.tf                   configurações do Lake Formation na conta + os dois módulos
  variables.tf              inclui `personas`: a política de acesso por camada, como dado
  modules/data-lake/        camadas S3, bancos/tabelas Glue (schemas em locals.tf), Athena
  modules/governance/       registro e grants no Lake Formation, papéis e WorkGroups dos perfis
  sql/etl/                  INSERTs raw -> trusted -> refined e barreiras pós-carga
  sql/analytics/            pergunta de negócio (3 camadas), checagem de grão, sonda de poda
scripts/part-2/
  bootstrap.sh deploy.sh destroy.sh run_all.sh     ciclo de vida
  ingest_kev.sh ingest_epss.sh build_refined.sh    etapas do pipeline (todas idempotentes)
  run_pipeline.sh                                  backfill ou incremental, de ponta a ponta
  run_query.sh                                     pergunta de negócio + custo medido
  check_idempotency.sh check_access.sh             provas
  profile_sources.sh                               medições offline das fontes (DuckDB)
verificacao/                verifica.sh (entrada) + critérios part-1.sh / part-2.sh
DECISOES.md / DECISIONS.md  decisões de engenharia com números medidos (PT avaliada / EN)
docs/evidence/part-2/       evidências produzidas por uma execução real
docs/presentation/          decks (PT avaliado + EN) das duas partes; scripts/build_pdf.sh gera os PDFs
parte-1/, scripts/*.sh      Parte 1 (AV1), como entregue -- ver abaixo
```

---

## Parte 1 (AV1) — entregue

Lake mínimo sobre o catálogo CISA KEV: raw + trusted (NDJSON), uma tabela Glue declarada em IaC,
WorkGroup do Athena com limite de 100 MB, custo medido de **USD 0,00004768** por consulta.
Decisões 1 a 10 no [`DECISOES.md`](DECISOES.md); evidências em `docs/evidence/`.

As Partes 1 e 2 usam os mesmos nomes obrigatórios de bucket, então só uma delas pode estar
provisionada numa conta por vez. Para reproduzir a Parte 1 exatamente como avaliada, faça checkout
da tag `av1-entrega`, ou, no `main`:

```bash
scripts/run_all.sh                      # bootstrap, deploy, ingestão, consulta, verificação (Parte 1)
scripts/destroy.sh                      # destruição, verificada
verificacao/verifica.sh --parte 1
```

---

## Limitações conhecidas

- O número de destruição da decisão 24 (`PENDENTE` no `DECISOES.md`) é medido na destruição final.
- Uma configuração de Lake Formation por conta: não provisione dois workspaces de `parte-2/` na
  mesma conta.
- Dias da refined construídos de forma incremental usam o snapshot do KEV vigente no momento da
  carga (registrado por linha em `kev_catalog_date`). Reconstruir um intervalo com um único
  snapshot é uma atualização completa explícita:
  `scripts/part-2/build_refined.sh --from <dia> --to <dia>`.
