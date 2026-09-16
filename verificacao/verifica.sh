#!/usr/bin/env bash
#
# Acceptance script -- EDA262 Part 1 (AV1), group g07.
#
# Prints PASSA or FALHA per criterion and exits 0 only if every criterion passes.
# Criterion labels and the PASSA/FALHA verdicts are intentionally kept in Portuguese:
# they are the evaluator-facing contract defined by the course guide. Everything
# else in this file is English, like the rest of the codebase.
#
# Usage:
#   verificacao/verifica.sh                  # repository + AWS resources
#   verificacao/verifica.sh --repo-only      # static criteria only, no AWS
#   verificacao/verifica.sh --profile NAME   # specific AWS profile
#
# Requires: bash, grep, jq. AWS criteria additionally require an authenticated AWS CLI.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PREFIX="${EDA262_PREFIX:-eda262-g07}"
GLUE_DB="${EDA262_GLUE_DB:-eda262_g07_kev}"
TABLE="${EDA262_TABLE:-kev_vulnerabilities}"
REPO_ONLY=0
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-only) REPO_ONLY=1; shift ;;
    --profile)      PROFILE="${2:?--profile requires a value}"; shift 2 ;;
    -h|--help)      sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; GRAY=$'\033[90m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; GRAY=''; BOLD=''; RESET=''
fi

TOTAL=0; PASSED=0; FAILED=0

# criterion "<label>" <command...>
# Runs the command silently and prints the PASSA/FALHA verdict.
criterion() {
  local label="$1"; shift
  TOTAL=$(( TOTAL + 1 ))
  if "$@" >/dev/null 2>&1; then
    printf '%sPASSA%s  %s\n' "${GREEN}" "${RESET}" "${label}"
    PASSED=$(( PASSED + 1 ))
  else
    printf '%sFALHA%s  %s\n' "${RED}" "${RESET}" "${label}"
    FAILED=$(( FAILED + 1 ))
  fi
}

section() { printf '\n%s%s%s\n' "${BOLD}" "$1" "${RESET}"; }

# --- helpers used by the criteria --------------------------------------------

aws_cli() {
  if [[ -n "${PROFILE}" ]]; then aws --profile "${PROFILE}" "$@"; else aws "$@"; fi
}

# No Glue Crawler resource may exist in the Terraform (course guide requirement).
no_crawler_in_code() {
  ! grep -rIlE '^\s*resource\s+"aws_glue_crawler"' parte-1/ 2>/dev/null | grep -q .
}

# The schema must be declared in IaC: look for explicitly declared table columns.
schema_declared_in_iac() {
  grep -rqE 'dynamic\s+"columns"|^\s*columns\s*\{' parte-1/modules/ 2>/dev/null \
    && grep -rq 'trusted_columns' parte-1/modules/ 2>/dev/null
}

remote_backend_declared() {
  grep -rq 'backend "s3"' parte-1/*.tf 2>/dev/null \
    && grep -rq 'aws_dynamodb_table' parte-1/bootstrap/*.tf 2>/dev/null
}

packaged_as_module() {
  [[ -d parte-1/modules/data-lake ]] && grep -rq 'source\s*=\s*"\./modules/data-lake"' parte-1/*.tf 2>/dev/null
}

workspace_in_use() {
  grep -rq 'terraform\.workspace' parte-1/*.tf 2>/dev/null
}

mandatory_tags_declared() {
  grep -rq 'turma\s*=\s*"eda262"' parte-1/ 2>/dev/null \
    && grep -rq 'grupo\s*=\s*"g07"' parte-1/ 2>/dev/null \
    && grep -rq 'projeto\s*=\s*"engenharia-de-dados"' parte-1/ 2>/dev/null
}

decisions_have_numbers() {
  # The guide requires measured numbers; prose alone does not score.
  [[ -f DECISOES.md ]] && grep -qE '[0-9]' DECISOES.md \
    && grep -qiE 'grain|granularidade' DECISOES.md \
    && grep -qiE 'custo' DECISOES.md
}

cost_measured() {
  local arquivo="docs/evidence/query-cost.json"
  [[ -f "${arquivo}" ]] || return 1
  local custo bytes
  custo="$(jq -r '.cost_usd // empty' "${arquivo}")"
  bytes="$(jq -r '.data_scanned_bytes // empty' "${arquivo}")"
  [[ -n "${custo}" && -n "${bytes}" ]]
}

grain_proven() {
  local arquivo="docs/evidence/query-cost.json"
  [[ -f "${arquivo}" ]] || return 1
  [[ "$(jq -r '.grain_check.duplicate_rows' "${arquivo}")" == "0" ]]
}

bucket_exists()   { aws_cli s3api head-bucket --bucket "$1"; }
glue_db_exists()  { aws_cli glue get-database --name "${GLUE_DB}"; }
workgroup_exists(){ aws_cli athena get-work-group --work-group "${PREFIX}-wg"; }

table_declares_grain() {
  local saida
  saida="$(aws_cli glue get-table --database-name "${GLUE_DB}" --name "${TABLE}" --output json)" || return 1
  jq -e '.Table.Parameters.grain == "one row per cve_id"' <<< "${saida}" >/dev/null
}

table_not_crawler_built() {
  # A Crawler-built table carries the UPDATED_BY_CRAWLER parameter.
  local saida
  saida="$(aws_cli glue get-table --database-name "${GLUE_DB}" --name "${TABLE}" --output json)" || return 1
  ! jq -e '.Table.Parameters.UPDATED_BY_CRAWLER // empty' <<< "${saida}" >/dev/null
}

no_crawler_in_account() {
  local saida
  saida="$(aws_cli glue list-crawlers --output json)" || return 1
  ! jq -e --arg p "${PREFIX}" '.CrawlerNames[]? | select(startswith($p))' <<< "${saida}" >/dev/null
}

data_loaded() {
  aws_cli s3api head-object \
    --bucket "${PREFIX}-lake-trusted" \
    --key "${TABLE}/kev_vulnerabilities.json"
}

tags_applied_in_aws() {
  local saida
  saida="$(aws_cli s3api get-bucket-tagging --bucket "${PREFIX}-lake-raw" --output json)" || return 1
  jq -e '
    (.TagSet | map({(.Key): .Value}) | add) as $t
    | $t.turma == "eda262" and $t.grupo == "g07" and $t.projeto == "engenharia-de-dados"
  ' <<< "${saida}" >/dev/null
}

# --- criteria -----------------------------------------------------------------

printf '%sVerificacao EDA262 -- Parte 1 (AV1) -- grupo g07%s\n' "${BOLD}" "${RESET}"
printf '%srepositorio: %s%s\n' "${GRAY}" "${REPO_ROOT}" "${RESET}"

section "1. Estrutura do repositorio"
criterion "Terraform da Parte 1 em parte-1/ na raiz do repositorio" test -d parte-1
criterion "DECISOES.md na raiz do repositorio"                     test -f DECISOES.md
criterion "README.md com instrucoes de deploy/destroy"             test -f README.md
criterion "Script de aceitacao em verificacao/verifica.sh"         test -x verificacao/verifica.sh
criterion "Apresentacao apresentacao-parte-1-g07.pdf gerada"       test -f apresentacao-parte-1-g07.pdf

section "2. Infraestrutura como codigo"
criterion "Terraform empacotado como modulo"                       packaged_as_module
criterion "Backend remoto declarado (S3 + DynamoDB)"               remote_backend_declared
criterion "Workspace do Terraform em uso"                          workspace_in_use
criterion "Schema declarado em IaC (colunas explicitas)"           schema_declared_in_iac
criterion "Nenhum recurso aws_glue_crawler no codigo"              no_crawler_in_code
criterion "Tags obrigatorias declaradas (turma/grupo/projeto)"     mandatory_tags_declared

section "3. Decisoes e evidencias"
criterion "DECISOES.md cobre granularidade e custo com numeros"    decisions_have_numbers
criterion "Custo por query medido e registrado"                    cost_measured
criterion "Granularidade comprovada (0 cve_id duplicado)"          grain_proven
criterion "Resultado da consulta de negocio salvo"                 test -f docs/evidence/business-question-result.csv

if [[ "${REPO_ONLY}" -eq 1 ]]; then
  printf '\n%smodo --repo-only: criterios de AWS nao verificados%s\n' "${GRAY}" "${RESET}"
else
  section "4. Recursos provisionados na AWS"
  if ! aws_cli sts get-caller-identity >/dev/null 2>&1; then
    printf '%sFALHA%s  Credenciais AWS validas (necessarias para os criterios 4.x)\n' "${RED}" "${RESET}"
    printf '%s       use --repo-only para verificar apenas o repositorio%s\n' "${GRAY}" "${RESET}"
    TOTAL=$(( TOTAL + 1 )); FAILED=$(( FAILED + 1 ))
  else
    criterion "Bucket da camada raw (${PREFIX}-lake-raw)"          bucket_exists "${PREFIX}-lake-raw"
    criterion "Bucket da camada trusted (${PREFIX}-lake-trusted)"  bucket_exists "${PREFIX}-lake-trusted"
    criterion "Bucket de resultados do Athena"                      bucket_exists "${PREFIX}-athena-results"
    criterion "Banco no Glue Data Catalog (${GLUE_DB})"             glue_db_exists
    criterion "Tabela trusted com granularidade declarada"          table_declares_grain
    criterion "Tabela nao foi criada por Crawler"                   table_not_crawler_built
    criterion "Nenhum Glue Crawler provisionado na conta"           no_crawler_in_account
    criterion "Athena WorkGroup (${PREFIX}-wg)"                    workgroup_exists
    criterion "Dados carregados na camada trusted"                  data_loaded
    criterion "Tags obrigatorias aplicadas nos recursos"            tags_applied_in_aws
  fi
fi

# --- summary --------------------------------------------------------------------
printf '\n%s%s%s\n' "${BOLD}" "$(printf '%.0s-' {1..60})" "${RESET}"
printf 'Resultado: %s%d PASSA%s / %s%d FALHA%s  (total: %d criterios)\n' \
  "${GREEN}" "${PASSED}" "${RESET}" "${RED}" "${FAILED}" "${RESET}" "${TOTAL}"

if [[ "${FAILED}" -eq 0 ]]; then
  printf '%sTodos os criterios foram atendidos.%s\n' "${GREEN}" "${RESET}"
  exit 0
fi

printf '%s%d criterio(s) nao atendido(s).%s\n' "${RED}" "${FAILED}" "${RESET}"
exit 1
