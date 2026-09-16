# EDA262 — Projeto da disciplina, grupo g07 (Parte 1 / AV1)

Data lake mínimo na AWS, provisionado 100% em Terraform, sobre o catálogo público
**CISA KEV** (*Known Exploited Vulnerabilities*).

**Pergunta de negócio:** quais fabricantes concentram o maior número de vulnerabilidades
ativamente exploradas nos últimos 12 meses — e quanto custa essa consulta no Athena?

**Resposta e custo medido:** `docs/evidence/` · **Decisões com números:** [`DECISOES.md`](DECISOES.md)

---

## Arquitetura

```
  CISA KEV (feed público, sem autenticação)
        │
        │  scripts/ingest.sh
        ▼
  ┌─────────────────────────┐
  │  eda262-g07-lake-raw    │   documento original, byte a byte (1.722.859 B)
  └───────────┬─────────────┘
              │  raw → trusted: NDJSON, limpo e tipado
              │  5 barreiras de qualidade (a grain é validada antes de publicar)
              ▼
  ┌─────────────────────────┐
  │ eda262-g07-lake-trusted │   1.710 linhas, 1 por CVE (1.497.926 B)
  └───────────┬─────────────┘
              │  schema declarado em IaC — sem Glue Crawler
              ▼
  ┌─────────────────────────┐
  │   Glue Data Catalog     │   eda262_g07_kev.kev_vulnerabilities (15 colunas)
  └───────────┬─────────────┘
              │
              ▼
  ┌─────────────────────────┐
  │  Athena WorkGroup       │   eda262-g07-wg · limite de 100 MB por consulta
  │  eda262-g07-wg          │   custo medido: USD 0,00004768 por consulta
  └───────────┬─────────────┘
              ▼
     eda262-g07-athena-results   resultados expiram em 7 dias
```

| Componente | Recurso |
|---|---|
| Camada raw | `eda262-g07-lake-raw` |
| Camada trusted | `eda262-g07-lake-trusted` |
| Resultados do Athena | `eda262-g07-athena-results` |
| Catálogo | `eda262_g07_kev` · tabela `kev_vulnerabilities` |
| WorkGroup | `eda262-g07-wg` |
| Estado do Terraform | `eda262-g07-tfstate-<account-id>` + `eda262-g07-tflock` |

Todos os recursos recebem as tags obrigatórias `turma=eda262`, `grupo=g07`,
`projeto=engenharia-de-dados` via `default_tags` do provider — um recurso novo não tem como
esquecê-las.

---

## Pré-requisitos

| Ferramenta | Versão mínima | Para quê |
|---|---|---|
| Terraform | 1.5 | provisionamento |
| AWS CLI | 2.x | autenticação e operação |
| `jq` | 1.6 | transformação raw → trusted |
| `curl` | qualquer | download do feed |

Conta AWS com permissão para criar recursos de S3, Glue, Athena e DynamoDB.
**Região padrão: `us-east-1`** (o preço do Athena em `DECISOES.md` é o dessa região).

```bash
aws configure --profile de     # ou use suas credenciais padrão
aws sts get-caller-identity --profile de
```

---

## Deploy do zero

Quatro comandos, em ordem. Cada um valida o anterior antes de prosseguir.

```bash
# 1. Cria o backend remoto (bucket de estado + tabela de lock) e gera parte-1/backend.hcl.
#    Roda uma única vez por conta AWS.
scripts/bootstrap.sh --profile de --region us-east-1

# 2. Provisiona o data lake no workspace de entrega 'av1'.
scripts/deploy.sh --profile de --region us-east-1

# 3. Ingere o catálogo KEV: raw → trusted, com as barreiras de qualidade.
scripts/ingest.sh --profile de

# 4. Executa a consulta de negócio e mede o custo real no Athena.
scripts/run_query.sh --profile de
```

Para revisar antes de aplicar: `scripts/deploy.sh --profile de --plan-only`.

### O que cada passo produz

| Passo | Saída |
|---|---|
| `bootstrap.sh` | `parte-1/backend.hcl` (não versionado — contém o ID da conta) |
| `deploy.sh` | buckets, catálogo, tabela e WorkGroup |
| `ingest.sh` | `docs/evidence/ingest-metrics.json` |
| `run_query.sh` | `docs/evidence/business-question-result.csv`, `query-cost.json`, `grain-check-result.csv` |

---

## Verificação

```bash
verificacao/verifica.sh --profile de       # repositório + recursos na AWS
verificacao/verifica.sh --somente-repo     # apenas critérios estáticos, sem AWS
```

Imprime `PASSA`/`FALHA` por critério e retorna `0` somente se todos passarem.

---

## Destruição

```bash
scripts/destroy.sh --profile de                     # remove o data lake
scripts/destroy.sh --profile de --include-backend   # remove também o backend (irreversível)
```

O script não confia no código de saída do Terraform: depois do `destroy` ele consulta a AWS por
cada um dos 5 recursos e **falha** se qualquer um ainda existir. Um `destroy` que deixa órfãos
reprova no critério do guia, então ele é verificado e não presumido.

---

## Estrutura do repositório

```
parte-1/
  bootstrap/            backend remoto (estado local — resolve o ovo e a galinha)
  modules/data-lake/    o módulo: S3 + Glue + Athena
    locals.tf           schema da tabela trusted, declarado como dado
    queries.tf          SQL da pergunta de negócio, versionado em IaC
  main.tf               chama o módulo; bloqueia o workspace 'default'
scripts/
  kev_to_trusted.jq     transformação raw → trusted (testável isoladamente)
  bootstrap.sh          cria o backend
  deploy.sh             provisiona
  ingest.sh             ingere, com 5 barreiras de qualidade
  run_query.sh          consulta e mede o custo
  destroy.sh            destrói e confere que não sobrou nada
verificacao/verifica.sh script de aceitação (PASSA/FALHA)
DECISOES.md             decisões com números medidos
docs/evidence/          evidências geradas pela execução
```

---

## Decisões de projeto em uma linha

O detalhamento com números está em [`DECISOES.md`](DECISOES.md).

- **Granularidade:** uma linha por CVE — 1.710 linhas, 1.710 `cve_id` distintos, **0** duplicatas.
- **Sem Glue Crawler:** schema de 15 colunas declarado em IaC; evita ~USD 0,073 por execução e
  variação de tipo entre *crawls*.
- **Custo por consulta:** **USD 0,00004768** — o dataset (1,43 MB) cabe 7× dentro do mínimo
  cobrável de 10 MB do Athena.
- **Sem Parquet nesta fase:** a cobrança já está no piso; converter economizaria **USD 0,00**.
  Entra na Parte 2, quando o volume passar do mínimo.
- **Workspace `av1`:** produz os nomes exigidos pelo guia; outros workspaces recebem sufixo, para
  que nomes de bucket (globais) nunca colidam.

---

## Limitações conhecidas (escopo da Parte 1)

Fora de escopo por decisão, não por esquecimento — entram na Parte 2:

- Sem Parquet, sem particionamento, sem camada refined.
- Ingestão **não idempotente**: re-executar `ingest.sh` sobrescreve o objeto da camada trusted.
- Sem Lake Formation: o controle de acesso é o do S3/IAM.
- `date_added` e `due_date` são `string` em ISO-8601, não `date` — ver `DECISOES.md` §5.
