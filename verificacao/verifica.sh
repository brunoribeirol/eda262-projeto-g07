#!/usr/bin/env bash
#
# Script de aceitacao -- EDA262 Parte 1 (AV1), grupo g07.
#
# Imprime PASSA ou FALHA para cada criterio do guia do projeto e termina com
# codigo 0 somente se todos os criterios passarem.
#
# Uso:
#   verificacao/verifica.sh                      # repositorio + recursos na AWS
#   verificacao/verifica.sh --somente-repo       # apenas criterios estaticos, sem AWS
#   verificacao/verifica.sh --profile NOME       # perfil AWS especifico
#
# Requisitos: bash, grep, jq. A verificacao na AWS exige ainda o AWS CLI autenticado.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PREFIXO="${EDA262_PREFIXO:-eda262-g07}"
GLUE_DB="${EDA262_GLUE_DB:-eda262_g07_kev}"
TABELA="${EDA262_TABELA:-kev_vulnerabilities}"
SOMENTE_REPO=0
PERFIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --somente-repo) SOMENTE_REPO=1; shift ;;
    --profile)      PERFIL="${2:?--profile exige um valor}"; shift 2 ;;
    -h|--help)      sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  VERDE=$'\033[32m'; VERMELHO=$'\033[31m'; CINZA=$'\033[90m'; NEGRITO=$'\033[1m'; FIM=$'\033[0m'
else
  VERDE=''; VERMELHO=''; CINZA=''; NEGRITO=''; FIM=''
fi

TOTAL=0; APROVADOS=0; REPROVADOS=0

# criterio "<descricao>" <comando...>
# Executa o comando silenciosamente e imprime PASSA/FALHA.
criterio() {
  local descricao="$1"; shift
  TOTAL=$(( TOTAL + 1 ))
  if "$@" >/dev/null 2>&1; then
    printf '%sPASSA%s  %s\n' "${VERDE}" "${FIM}" "${descricao}"
    APROVADOS=$(( APROVADOS + 1 ))
  else
    printf '%sFALHA%s  %s\n' "${VERMELHO}" "${FIM}" "${descricao}"
    REPROVADOS=$(( REPROVADOS + 1 ))
  fi
}

secao() { printf '\n%s%s%s\n' "${NEGRITO}" "$1" "${FIM}"; }

# --- helpers usados pelos criterios --------------------------------------------

aws_cli() {
  if [[ -n "${PERFIL}" ]]; then aws --profile "${PERFIL}" "$@"; else aws "$@"; fi
}

# Nenhum recurso de Glue Crawler pode existir no Terraform (exigencia do guia).
sem_crawler() {
  ! grep -rIlE '^\s*resource\s+"aws_glue_crawler"' parte-1/ 2>/dev/null | grep -q .
}

# O schema precisa estar declarado em IaC: procuramos colunas declaradas na tabela.
schema_declarado_em_iac() {
  grep -rqE 'dynamic\s+"columns"|^\s*columns\s*\{' parte-1/modules/ 2>/dev/null \
    && grep -rq 'trusted_columns' parte-1/modules/ 2>/dev/null
}

backend_remoto_declarado() {
  grep -rq 'backend "s3"' parte-1/*.tf 2>/dev/null \
    && grep -rq 'aws_dynamodb_table' parte-1/bootstrap/*.tf 2>/dev/null
}

modulo_terraform() {
  [[ -d parte-1/modules/data-lake ]] && grep -rq 'source\s*=\s*"\./modules/data-lake"' parte-1/*.tf 2>/dev/null
}

workspace_em_uso() {
  grep -rq 'terraform\.workspace' parte-1/*.tf 2>/dev/null
}

tags_obrigatorias() {
  grep -rq 'turma\s*=\s*"eda262"' parte-1/ 2>/dev/null \
    && grep -rq 'grupo\s*=\s*"g07"' parte-1/ 2>/dev/null \
    && grep -rq 'projeto\s*=\s*"engenharia-de-dados"' parte-1/ 2>/dev/null
}

decisoes_com_numeros() {
  # O guia exige numeros medidos; prosa sozinha nao pontua.
  [[ -f DECISOES.md ]] && grep -qE '[0-9]' DECISOES.md \
    && grep -qiE 'grain|granularidade' DECISOES.md \
    && grep -qiE 'custo' DECISOES.md
}

custo_medido() {
  local arquivo="docs/evidence/query-cost.json"
  [[ -f "${arquivo}" ]] || return 1
  local custo bytes
  custo="$(jq -r '.cost_usd // empty' "${arquivo}")"
  bytes="$(jq -r '.data_scanned_bytes // empty' "${arquivo}")"
  [[ -n "${custo}" && -n "${bytes}" ]]
}

grain_comprovada() {
  local arquivo="docs/evidence/query-cost.json"
  [[ -f "${arquivo}" ]] || return 1
  [[ "$(jq -r '.grain_check.duplicate_rows' "${arquivo}")" == "0" ]]
}

bucket_existe()   { aws_cli s3api head-bucket --bucket "$1"; }
glue_db_existe()  { aws_cli glue get-database --name "${GLUE_DB}"; }
workgroup_existe(){ aws_cli athena get-work-group --work-group "${PREFIXO}-wg"; }

tabela_existe_com_grain() {
  local saida
  saida="$(aws_cli glue get-table --database-name "${GLUE_DB}" --name "${TABELA}" --output json)" || return 1
  jq -e '.Table.Parameters.grain == "one row per cve_id"' <<< "${saida}" >/dev/null
}

tabela_sem_crawler_na_aws() {
  # Uma tabela criada por Crawler carrega o parametro UPDATED_BY_CRAWLER.
  local saida
  saida="$(aws_cli glue get-table --database-name "${GLUE_DB}" --name "${TABELA}" --output json)" || return 1
  ! jq -e '.Table.Parameters.UPDATED_BY_CRAWLER // empty' <<< "${saida}" >/dev/null
}

nenhum_crawler_na_conta() {
  local saida
  saida="$(aws_cli glue list-crawlers --output json)" || return 1
  ! jq -e --arg p "${PREFIXO}" '.CrawlerNames[]? | select(startswith($p))' <<< "${saida}" >/dev/null
}

dados_carregados() {
  aws_cli s3api head-object \
    --bucket "${PREFIXO}-lake-trusted" \
    --key "${TABELA}/kev_vulnerabilities.json"
}

tags_aplicadas_na_aws() {
  local saida
  saida="$(aws_cli s3api get-bucket-tagging --bucket "${PREFIXO}-lake-raw" --output json)" || return 1
  jq -e '
    (.TagSet | map({(.Key): .Value}) | add) as $t
    | $t.turma == "eda262" and $t.grupo == "g07" and $t.projeto == "engenharia-de-dados"
  ' <<< "${saida}" >/dev/null
}

# --- criterios -----------------------------------------------------------------

printf '%sVerificacao EDA262 -- Parte 1 (AV1) -- grupo g07%s\n' "${NEGRITO}" "${FIM}"
printf '%srepositorio: %s%s\n' "${CINZA}" "${REPO_ROOT}" "${FIM}"

secao "1. Estrutura do repositorio"
criterio "Terraform da Parte 1 em parte-1/ na raiz do repositorio" test -d parte-1
criterio "DECISOES.md na raiz do repositorio"                     test -f DECISOES.md
criterio "README.md com instrucoes de deploy/destroy"             test -f README.md
criterio "Script de aceitacao em verificacao/verifica.sh"         test -x verificacao/verifica.sh

secao "2. Infraestrutura como codigo"
criterio "Terraform empacotado como modulo"                       modulo_terraform
criterio "Backend remoto declarado (S3 + DynamoDB)"               backend_remoto_declarado
criterio "Workspace do Terraform em uso"                          workspace_em_uso
criterio "Schema declarado em IaC (colunas explicitas)"           schema_declarado_em_iac
criterio "Nenhum recurso aws_glue_crawler no codigo"              sem_crawler
criterio "Tags obrigatorias declaradas (turma/grupo/projeto)"     tags_obrigatorias

secao "3. Decisoes e evidencias"
criterio "DECISOES.md cobre granularidade e custo com numeros"    decisoes_com_numeros
criterio "Custo por query medido e registrado"                    custo_medido
criterio "Granularidade comprovada (0 cve_id duplicado)"          grain_comprovada
criterio "Resultado da consulta de negocio salvo"                 test -f docs/evidence/business-question-result.csv

if [[ "${SOMENTE_REPO}" -eq 1 ]]; then
  printf '\n%smodo --somente-repo: criterios de AWS nao verificados%s\n' "${CINZA}" "${FIM}"
else
  secao "4. Recursos provisionados na AWS"
  if ! aws_cli sts get-caller-identity >/dev/null 2>&1; then
    printf '%sFALHA%s  Credenciais AWS validas (necessarias para os criterios 4.x)\n' "${VERMELHO}" "${FIM}"
    printf '%s       use --somente-repo para verificar apenas o repositorio%s\n' "${CINZA}" "${FIM}"
    TOTAL=$(( TOTAL + 1 )); REPROVADOS=$(( REPROVADOS + 1 ))
  else
    criterio "Bucket da camada raw (${PREFIXO}-lake-raw)"          bucket_existe "${PREFIXO}-lake-raw"
    criterio "Bucket da camada trusted (${PREFIXO}-lake-trusted)"  bucket_existe "${PREFIXO}-lake-trusted"
    criterio "Bucket de resultados do Athena"                      bucket_existe "${PREFIXO}-athena-results"
    criterio "Banco no Glue Data Catalog (${GLUE_DB})"             glue_db_existe
    criterio "Tabela trusted com granularidade declarada"          tabela_existe_com_grain
    criterio "Tabela nao foi criada por Crawler"                   tabela_sem_crawler_na_aws
    criterio "Nenhum Glue Crawler provisionado na conta"           nenhum_crawler_na_conta
    criterio "Athena WorkGroup (${PREFIXO}-wg)"                    workgroup_existe
    criterio "Dados carregados na camada trusted"                  dados_carregados
    criterio "Tags obrigatorias aplicadas nos recursos"            tags_aplicadas_na_aws
  fi
fi

# --- resumo --------------------------------------------------------------------
printf '\n%s%s%s\n' "${NEGRITO}" "$(printf '%.0s-' {1..60})" "${FIM}"
printf 'Resultado: %s%d PASSA%s / %s%d FALHA%s  (total: %d criterios)\n' \
  "${VERDE}" "${APROVADOS}" "${FIM}" "${VERMELHO}" "${REPROVADOS}" "${FIM}" "${TOTAL}"

if [[ "${REPROVADOS}" -eq 0 ]]; then
  printf '%sTodos os criterios foram atendidos.%s\n' "${VERDE}" "${FIM}"
  exit 0
fi

printf '%s%d criterio(s) nao atendido(s).%s\n' "${VERMELHO}" "${REPROVADOS}" "${FIM}"
exit 1
