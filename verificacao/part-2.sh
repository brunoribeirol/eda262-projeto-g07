#!/usr/bin/env bash
# Acceptance criteria -- EDA262 Part 2 (AV2). Sourced by verificacao/verifica.sh.
#
# Part 2 extends Part 1, so every Part 1 criterion is re-checked against parte-2/, plus the
# Part 2 requirements: three layers, partitioned Parquet with a met cost target, idempotent
# ingestion with backfill, and per-layer access through Lake Formation.

PREFIX="${EDA262_PREFIX:-eda262-g07}"
DB_PREFIX="${PREFIX//-/_}"
RAW_DB="${DB_PREFIX}_raw"
TRUSTED_DB="${DB_PREFIX}_trusted"
REFINED_DB="${DB_PREFIX}_refined"
EVIDENCE="docs/evidence/part-2"

# Expected Lake Formation matrix: persona -> layers it may read (mirrors parte-2/variables.tf).
PERSONAS="data-engineer data-analyst business-user"
expected_layers() {
  case "$1" in
    data-engineer) echo "raw refined trusted" ;;
    data-analyst)  echo "refined trusted" ;;
    business-user) echo "refined" ;;
  esac
}

# --- static: infrastructure as code --------------------------------------------------

p2_packaged_as_modules() {
  grep -rqE 'source\s*=\s*"\./modules/data-lake"' parte-2/*.tf 2>/dev/null \
    && grep -rqE 'source\s*=\s*"\./modules/governance"' parte-2/*.tf 2>/dev/null
}

p2_remote_backend() {
  grep -rq 'backend "s3"' parte-2/*.tf 2>/dev/null \
    && grep -rq 'aws_dynamodb_table' parte-2/bootstrap/*.tf 2>/dev/null
}

p2_workspace_in_use()  { grep -rq 'terraform\.workspace' parte-2/*.tf 2>/dev/null; }

p2_schema_declared() {
  grep -qE 'dynamic\s+"columns"' parte-2/modules/data-lake/glue.tf 2>/dev/null \
    && grep -qE '^\s*columns\s*=\s*\[' parte-2/modules/data-lake/locals.tf 2>/dev/null
}

p2_no_crawler_in_code() { ! grep -rIlE '^\s*resource\s+"aws_glue_crawler"' parte-2/ 2>/dev/null | grep -q .; }

p2_tags_declared() {
  grep -rq 'turma\s*=\s*"eda262"' parte-2/ 2>/dev/null \
    && grep -rq 'grupo\s*=\s*"g07"' parte-2/ 2>/dev/null \
    && grep -rq 'projeto\s*=\s*"engenharia-de-dados"' parte-2/ 2>/dev/null
}

p2_three_layers_declared() {
  local f=parte-2/modules/data-lake/locals.tf
  grep -q '"lake-raw"' "${f}" && grep -q '"lake-trusted"' "${f}" && grep -q '"lake-refined"' "${f}"
}

p2_parquet_declared() {
  grep -rq 'ParquetHiveSerDe' parte-2/modules/ 2>/dev/null \
    && grep -rq '"parquet.compression"' parte-2/modules/ 2>/dev/null
}

p2_partitions_declared() { grep -qE 'dynamic\s+"partition_keys"' parte-2/modules/data-lake/glue.tf 2>/dev/null; }

p2_lake_formation_declared() {
  grep -rq 'resource "aws_lakeformation_data_lake_settings"' parte-2/ 2>/dev/null \
    && grep -rq 'resource "aws_lakeformation_resource"' parte-2/ 2>/dev/null \
    && grep -rq 'resource "aws_lakeformation_permissions"' parte-2/ 2>/dev/null
}

# --- static: decisions and evidence --------------------------------------------------

p2_decisions_cover_topics() {
  [[ -f DECISOES.md ]] || return 1
  local part2
  part2="$(sed -n '/^# .*Parte 2/,$p' DECISOES.md)"
  [[ -n "${part2}" ]] || return 1
  grep -qiE 'granularidade|grão'  <<< "${part2}" \
    && grep -qiE 'chave'          <<< "${part2}" \
    && grep -qiE 'parti'          <<< "${part2}" \
    && grep -qiE 'formato'        <<< "${part2}" \
    && grep -qiE 'custo'          <<< "${part2}" \
    && grep -qE '[0-9]'           <<< "${part2}"
}

# Numbers that still need the AWS run are marked PENDENTE; none may remain at delivery.
p2_decisions_measured() { [[ -f DECISOES.md ]] && ! grep -q 'PENDENTE' DECISOES.md; }

p2_cost_target_met() {
  local f="${EVIDENCE}/query-cost.json"
  [[ -f "${f}" ]] && jq -e '.layer == "refined" and .cost_target.met == true
                            and .data_scanned_bytes <= .cost_target.max_scanned_bytes' "${f}"
}

p2_layers_agree() {
  local f="${EVIDENCE}/cost-comparison.json"
  [[ -f "${f}" ]] && jq -e '.results_identical_across_layers == true' "${f}"
}

p2_grain_proven() {
  local f="${EVIDENCE}/query-cost.json"
  [[ -f "${f}" ]] && jq -e '.grain_check.duplicate_rows == 0' "${f}"
}

p2_backfill_recorded() {
  local f="${EVIDENCE}/load-history.jsonl"
  [[ -f "${f}" ]] && jq -s -e 'any(.[]; .source == "first-epss" and .partitions >= 2)' "${f}"
}

p2_idempotency_proven() {
  local f="${EVIDENCE}/idempotency-check.json"
  [[ -f "${f}" ]] && jq -e '.idempotent == true' "${f}"
}

p2_access_matrix_proven() {
  local f="${EVIDENCE}/access-matrix.json"
  [[ -f "${f}" ]] && jq -e '.all_match == true and .checks >= 9' "${f}"
}

# --- AWS --------------------------------------------------------------------------------

p2_bucket_exists()    { aws_cli s3api head-bucket --bucket "$1"; }
p2_db_exists()        { aws_cli glue get-database --name "$1"; }
p2_workgroup_exists() { aws_cli athena get-work-group --work-group "$1"; }

p2_layer_databases_exist() {
  p2_db_exists "${RAW_DB}" && p2_db_exists "${TRUSTED_DB}" && p2_db_exists "${REFINED_DB}"
}

p2_persona_workgroups_exist() {
  local persona
  for persona in ${PERSONAS}; do
    p2_workgroup_exists "${PREFIX}-wg-${persona}" || return 1
  done
}

# NOTE on counting: never use `--query 'length(...)'` on a paginated AWS CLI call. The CLI
# applies the JMESPath to EACH page, so 30 partitions over two pages print "30" and "0"
# (observed on 2026-10-20). Fetch JSON and let `jq -s` merge every page instead.

# Every table of the three databases declares its grain in the catalog.
p2_tables_declare_grain() {
  local db count=0 n
  for db in "${RAW_DB}" "${TRUSTED_DB}" "${REFINED_DB}"; do
    n="$(aws_cli glue get-tables --database-name "${db}" --output json \
          | jq -s '[.[].TableList[]] | if length > 0 and all(.[]; (.Parameters.grain // "") != "")
                                        then length else -1 end')" || return 1
    [[ "${n}" -gt 0 ]] || return 1
    count=$(( count + n ))
  done
  [[ "${count}" -ge 5 ]]
}

p2_modeled_tables_parquet_and_partitioned() {
  local db
  for db in "${TRUSTED_DB}" "${REFINED_DB}"; do
    aws_cli glue get-tables --database-name "${db}" --output json \
      | jq -e 'all(.TableList[];
                 (.StorageDescriptor.SerdeInfo.SerializationLibrary | test("Parquet"))
                 and ((.PartitionKeys // []) | length) > 0)' >/dev/null || return 1
  done
}

p2_no_crawler_tables() {
  local db
  for db in "${RAW_DB}" "${TRUSTED_DB}" "${REFINED_DB}"; do
    aws_cli glue get-tables --database-name "${db}" --output json \
      | jq -e 'all(.TableList[]; (.Parameters.UPDATED_BY_CRAWLER // "") == "")' >/dev/null || return 1
  done
  ! aws_cli glue list-crawlers --output json | jq -e --arg p "${PREFIX}" '.CrawlerNames[]? | select(startswith($p))' >/dev/null
}

p2_epss_backfilled_in_aws() {
  local n
  n="$(aws_cli glue get-partitions --database-name "${TRUSTED_DB}" --table-name epss_scores --output json \
         | jq -s '[.[].Partitions[]] | length')" || return 1
  [[ "${n}" -ge 2 ]]
}

p2_buckets_registered() {
  local registered layer
  registered="$(aws_cli lakeformation list-resources --query 'ResourceInfoList[].ResourceArn' --output text)" || return 1
  for layer in raw trusted refined; do
    grep -qF "arn:aws:s3:::${PREFIX}-lake-${layer}" <<< "${registered}" || return 1
  done
}

# With IAMAllowedPrincipals as the default, IAM alone would grant access and every
# Lake Formation grant would be decorative.
p2_lake_formation_enforced() {
  aws_cli lakeformation get-data-lake-settings --output json \
    | jq -e '((.DataLakeSettings.CreateTableDefaultPermissions // []) | length) == 0
             and ((.DataLakeSettings.CreateDatabaseDefaultPermissions // []) | length) == 0' >/dev/null
}

# The SELECT grants each persona holds must equal the declared matrix.
#
# ListPermissions refuses a Principal filter without a Resource ("Resource is mandatory if
# Principal is set", observed 2026-10-20), so the question is asked per layer instead:
# who holds SELECT on every table of this layer's database? The answers are then pivoted
# into persona -> layers and compared with the matrix.
p2_grant_holders() {
  local layer
  for layer in raw trusted refined; do
    aws_cli lakeformation list-permissions --output json \
      --resource "{\"Table\": {\"DatabaseName\": \"${DB_PREFIX}_${layer}\", \"TableWildcard\": {}}}" \
      | jq -r -s --arg layer "${layer}" '.[].PrincipalResourcePermissions[]
          | select(.Permissions | index("SELECT"))
          | [$layer, .Principal.DataLakePrincipalIdentifier] | @tsv' || return 1
  done
}

p2_grants_match_matrix() {
  local account holders persona role_arn granted expected
  account="$(aws_cli sts get-caller-identity --query Account --output text)" || return 1
  holders="$(p2_grant_holders)" || return 1
  [[ -n "${holders}" ]] || return 1
  for persona in ${PERSONAS}; do
    role_arn="arn:aws:iam::${account}:role/${PREFIX}-${persona}"
    granted="$(awk -F'\t' -v arn="${role_arn}" '$2 == arn { print $1 }' <<< "${holders}" | sort -u | tr '\n' ' ')"
    granted="${granted% }"
    expected="$(expected_layers "${persona}")"
    [[ "${granted}" == "${expected}" ]] || return 1
  done
}

p2_tags_applied() {
  local layer out
  for layer in lake-raw lake-trusted lake-refined athena-results; do
    out="$(aws_cli s3api get-bucket-tagging --bucket "${PREFIX}-${layer}" --output json)" || return 1
    jq -e '(.TagSet | map({(.Key): .Value}) | add) as $t
           | $t.turma == "eda262" and $t.grupo == "g07" and $t.projeto == "engenharia-de-dados"' <<< "${out}" >/dev/null || return 1
  done
}

run_part_2() {
  printf '%sVerificacao EDA262 -- Parte 2 (AV2) -- grupo g07%s\n' "${BOLD}" "${RESET}"
  printf '%srepositorio: %s%s\n' "${GRAY}" "${REPO_ROOT}" "${RESET}"

  section "1. Estrutura do repositorio"
  criterion "Terraform da Parte 2 em parte-2/ na raiz do repositorio" test -d parte-2
  criterion "DECISOES.md na raiz do repositorio"                     test -f DECISOES.md
  criterion "README.md com instrucoes de deploy/destroy"             test -f README.md
  criterion "Script de aceitacao em verificacao/verifica.sh"         test -x verificacao/verifica.sh
  criterion "Apresentacao apresentacao-parte-2-g07.pdf gerada"       test -f apresentacao-parte-2-g07.pdf

  section "2. Infraestrutura como codigo"
  criterion "Terraform empacotado em modulos (data-lake, governance)" p2_packaged_as_modules
  criterion "Backend remoto declarado (S3 + DynamoDB)"               p2_remote_backend
  criterion "Workspace do Terraform em uso"                          p2_workspace_in_use
  criterion "Schema declarado em IaC (colunas explicitas)"           p2_schema_declared
  criterion "Nenhum recurso aws_glue_crawler no codigo"              p2_no_crawler_in_code
  criterion "Tags obrigatorias declaradas (turma/grupo/projeto)"     p2_tags_declared
  criterion "Tres camadas declaradas (raw / trusted / refined)"      p2_three_layers_declared
  criterion "Formato Parquet com compressao declarado"               p2_parquet_declared
  criterion "Chaves de particao declaradas nas tabelas"              p2_partitions_declared
  criterion "Lake Formation declarado (settings, registro, grants)"  p2_lake_formation_declared

  section "3. Decisoes e evidencias"
  criterion "DECISOES.md (Parte 2): grao, chaves, particao, formato e custo" p2_decisions_cover_topics
  criterion "DECISOES.md sem numeros pendentes de medicao"            p2_decisions_measured
  criterion "Meta de custo por consulta declarada e cumprida"         p2_cost_target_met
  criterion "Mesma resposta nas tres camadas (raw/trusted/refined)"   p2_layers_agree
  criterion "Granularidade comprovada (0 chave duplicada)"            p2_grain_proven
  criterion "Backfill registrado (>= 2 particoes EPSS carregadas)"    p2_backfill_recorded
  criterion "Ingestao idempotente comprovada (recarga sem duplicar)"  p2_idempotency_proven
  criterion "Matriz de acesso por camada comprovada (Lake Formation)" p2_access_matrix_proven
  criterion "Resultado da consulta de negocio salvo"                  test -f "${EVIDENCE}/business-question-result.csv"

  if [[ "${REPO_ONLY}" -eq 1 ]]; then
    printf '\n%smodo --repo-only: criterios de AWS nao verificados%s\n' "${GRAY}" "${RESET}"
    return 0
  fi

  section "4. Recursos provisionados na AWS"
  aws_credentials_or_fail || return 0
  criterion "Bucket da camada raw (${PREFIX}-lake-raw)"            p2_bucket_exists "${PREFIX}-lake-raw"
  criterion "Bucket da camada trusted (${PREFIX}-lake-trusted)"    p2_bucket_exists "${PREFIX}-lake-trusted"
  criterion "Bucket da camada refined (${PREFIX}-lake-refined)"    p2_bucket_exists "${PREFIX}-lake-refined"
  criterion "Bucket de resultados do Athena"                        p2_bucket_exists "${PREFIX}-athena-results"
  criterion "Bancos no Glue por camada (raw/trusted/refined)"       p2_layer_databases_exist
  criterion "Todas as tabelas declaram a granularidade no catalogo" p2_tables_declare_grain
  criterion "Tabelas trusted/refined em Parquet e particionadas"    p2_modeled_tables_parquet_and_partitioned
  criterion "Nenhuma tabela ou Crawler criado por Glue Crawler"     p2_no_crawler_tables
  criterion "Athena WorkGroup do pipeline (${PREFIX}-wg)"           p2_workgroup_exists "${PREFIX}-wg"
  criterion "WorkGroups isolados por perfil de acesso"              p2_persona_workgroups_exist
  criterion "Particoes historicas carregadas no trusted (backfill)"  p2_epss_backfilled_in_aws
  criterion "Buckets das camadas registrados no Lake Formation"     p2_buckets_registered
  criterion "Lake Formation em vigor (sem IAMAllowedPrincipals padrao)" p2_lake_formation_enforced
  criterion "Grants por camada iguais a matriz declarada"           p2_grants_match_matrix
  criterion "Tags obrigatorias aplicadas nos buckets"               p2_tags_applied
}
