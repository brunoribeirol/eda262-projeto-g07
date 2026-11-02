#!/usr/bin/env bash
# Acceptance criteria -- EDA262 Part 2 (AV2). Sourced by verificacao/verifica.sh.
#
# Part 2 extends Part 1, so every Part 1 criterion is re-checked against parte-2/, plus the
# Part 2 requirements: three layers, partitioned Parquet with a met cost target, idempotent
# ingestion with backfill, and per-layer access through Lake Formation.
#
# Two kinds of evidence, never confused: section 3 checks what is COMMITTED (one run, cited
# by the documents); section 5 MEASURES the same claims in the account, right now, with the
# SQL Terraform published -- a lake that does not deliver fails there whatever the files say.

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

# Every evidence file from ONE run, and DECISOES.md, DECISIONS.md and the decks quoting that
# run's numbers (the AV1 slides, evidence and decisions had drifted to three runs).
p2_evidence_single_run_and_cited() { "${REPO_ROOT}/scripts/part-2/check_evidence_sync.sh" --quiet; }

evidence_run_id() { jq -r '.run_id // "nenhuma"' "${EVIDENCE}/run-manifest.json" 2>/dev/null || echo nenhuma; }

# The teardown that closes the same run, with nothing orphaned (checked against AWS by
# destroy.sh). Only judged with --repo-only: while the lake is up there is no teardown yet.
p2_destroy_recorded() {
  local f="${EVIDENCE}/destroy-check.json"
  [[ -f "${f}" ]] || return 1
  CRITERION_DETAIL="$(jq -r '"\(.terraform_resources_destroyed) recursos destruidos, \(.resources_checked_in_aws) conferidos na AWS, orfaos: \(.orphaned)"' "${f}")"
  jq -e --arg run "$(evidence_run_id)" '.orphaned == false and .run_id == $run' "${f}"
}

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

# --- AWS: measured now ------------------------------------------------------------------
# Each check runs the named query Terraform published -- the same SQL as the pipeline -- on
# the newest 30 days in the lake (anchored on the data, never on today's date).

LIVE_STATE=""
live_prepare() {
  case "${LIVE_STATE}" in ok) return 0 ;; failed) return 1 ;; esac
  LIVE_STATE=failed
  local caller days
  caller="$(aws_cli sts get-caller-identity --output json)" || return 1
  ACCOUNT_ID="$(jq -r '.Account' <<< "${caller}")"
  ARN_PARTITION="$(jq -r '.Arn | split(":")[1]' <<< "${caller}")"
  days="$(glue_values "${REFINED_DB}" vendor_exposure_daily)" || return 1
  [[ -n "${days}" ]] || return 1
  LIVE_LAST="$(tail -n 1 <<< "${days}")"
  LIVE_FIRST="$(tail -n 30 <<< "${days}" | head -n 1)"
  LIVE_DAYS="$(tail -n 30 <<< "${days}" | wc -l | tr -d ' ')"
  LIVE_KEV="$(glue_values "${TRUSTED_DB}" kev_vulnerabilities | tail -n 1)"
  [[ -n "${LIVE_KEV}" ]] || return 1
  LIVE_STATE=ok
}

# Partition values of a table, every page merged, sorted.
glue_values() {
  aws_cli glue get-partitions --database-name "$1" --table-name "$2" --output json \
    | jq -r -s '[.[].Partitions[].Values[0]] | sort | .[]'
}

# SQL of the named query "<prefix>-<key>" in the pipeline WorkGroup.
named_query() {
  local ids
  ids="$(aws_cli athena list-named-queries --work-group "${PREFIX}-wg" --output json \
           | jq -r -s '[.[].NamedQueryIds[]] | join(" ")')" || return 1
  [[ -n "${ids}" ]] || return 1
  # shellcheck disable=SC2086  # one argument per id
  aws_cli athena batch-get-named-query --named-query-ids ${ids} --output json \
    | jq -r -e --arg n "${PREFIX}-$1" '.NamedQueries[] | select(.Name == $n) | .QueryString'
}

sql_literal() { printf "'%s'" "$1"; }

# The graded query on refined, run once and shared by the checks below.
LIVE_REFINED_ID=""
live_business_question() {
  [[ -z "${LIVE_REFINED_ID}" ]] || return 0
  live_prepare || return 1
  local sql
  sql="$(named_query business-question)" || return 1
  LIVE_REFINED_ID="$(athena_execute "${sql}" "${PREFIX}-wg" "${REFINED_DB}" \
                       "$(sql_literal "${LIVE_FIRST}")" "$(sql_literal "${LIVE_LAST}")")" \
    || { LIVE_REFINED_ID=""; return 1; }
}

# Bytes the business question scans now, against the target declared on the WorkGroup tag.
p2_live_cost_target() {
  live_business_question || return 1
  local per_day bytes limit
  per_day="$(aws_cli athena list-tags-for-resource --output json \
               --resource-arn "arn:${ARN_PARTITION}:athena:${REGION}:${ACCOUNT_ID}:workgroup/${PREFIX}-wg" \
             | jq -r -e '.Tags[] | select(.Key == "cost_target_bytes_per_window_day") | .Value')" || return 1
  [[ "${per_day}" =~ ^[0-9]+$ ]] || return 1
  bytes="$(athena_scanned_bytes "${LIVE_REFINED_ID}")" || return 1
  limit=$(( per_day * LIVE_DAYS ))
  CRITERION_DETAIL="${LIVE_FIRST}..${LIVE_LAST}: ${bytes} B lidos, meta ${limit} B (${per_day} B x ${LIVE_DAYS} dias)"
  (( bytes <= limit ))
}

# The same question from trusted and from raw must return the very same CSV.
p2_live_layers_agree() {
  live_business_question || return 1
  local params trusted_id raw_id
  params=("$(sql_literal "${LIVE_FIRST}")" "$(sql_literal "${LIVE_LAST}")"
          "$(sql_literal "${LIVE_FIRST}")" "$(sql_literal "${LIVE_LAST}")" "$(sql_literal "${LIVE_KEV}")")
  trusted_id="$(athena_execute "$(named_query business-question-from-trusted)" "${PREFIX}-wg" "${TRUSTED_DB}" "${params[@]}")" || return 1
  raw_id="$(athena_execute "$(named_query business-question-from-raw)" "${PREFIX}-wg" "${RAW_DB}" "${params[@]}")" || return 1
  athena_result_to "${LIVE_REFINED_ID}" "${VERIFY_TMP}/refined.csv" || return 1
  athena_result_to "${trusted_id}" "${VERIFY_TMP}/trusted.csv" || return 1
  athena_result_to "${raw_id}" "${VERIFY_TMP}/raw.csv" || return 1
  CRITERION_DETAIL="$(( $(wc -l < "${VERIFY_TMP}/refined.csv") - 1 )) fabricantes; raw $(athena_scanned_bytes "${raw_id}") B, trusted $(athena_scanned_bytes "${trusted_id}") B"
  cmp -s "${VERIFY_TMP}/refined.csv" "${VERIFY_TMP}/trusted.csv" && cmp -s "${VERIFY_TMP}/refined.csv" "${VERIFY_TMP}/raw.csv"
}

# Grain of every modeled table, over every partition: what a non-idempotent load would break.
p2_live_grain() {
  live_prepare || return 1
  local id rows
  id="$(athena_execute "$(named_query grain-check)" "${PREFIX}-wg" "${TRUSTED_DB}")" || return 1
  rows="$(athena_rows "${id}")" || return 1
  [[ "$(grep -c . <<< "${rows}")" -eq 3 ]] || return 1
  CRITERION_DETAIL="$(awk -F'\t' '{ n += $3; d += $5 } END { printf "3 tabelas, %d linhas, %d duplicadas", n, d }' <<< "${rows}")"
  awk -F'\t' '{ d += $5 } END { exit (d == 0 ? 0 : 1) }' <<< "${rows}"
}

probe_sql() {
  case "$1" in
    raw)     printf 'SELECT count(*) FROM "%s"."kev_records" WHERE catalog_date = %s' "${RAW_DB}" "$(sql_literal "${LIVE_KEV}")" ;;
    trusted) printf 'SELECT count(*) FROM "%s"."kev_vulnerabilities" WHERE catalog_date = %s' "${TRUSTED_DB}" "$(sql_literal "${LIVE_KEV}")" ;;
    refined) printf 'SELECT count(*) FROM "%s"."vendor_exposure_daily" WHERE snapshot_date = %s' "${REFINED_DB}" "$(sql_literal "${LIVE_LAST}")" ;;
  esac
}

# Assumes every persona role and queries every layer through its own WorkGroup. A denial
# counts only if it is a permission error AND some persona can read that layer -- otherwise
# a broken probe would pass for a working permission.
p2_live_access_matrix() {
  live_prepare || return 1
  local persona layer creds key secret token expected actual checks=0 matches=0 readable=""
  for persona in ${PERSONAS}; do
    creds="$(aws_cli sts assume-role --role-session-name eda262-g07-verifica \
               --role-arn "arn:${ARN_PARTITION}:iam::${ACCOUNT_ID}:role/${PREFIX}-${persona}" \
               --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)" || return 1
    read -r key secret token <<< "${creds}"
    for layer in raw trusted refined; do
      checks=$(( checks + 1 ))
      expected=denied
      [[ " $(expected_layers "${persona}") " == *" ${layer} "* ]] && expected=granted
      actual="$(
        export AWS_ACCESS_KEY_ID="${key}" AWS_SECRET_ACCESS_KEY="${secret}" AWS_SESSION_TOKEN="${token}"
        unset AWS_PROFILE AWS_DEFAULT_PROFILE
        PROFILE=""
        if athena_execute "$(probe_sql "${layer}")" "${PREFIX}-wg-${persona}" "${DB_PREFIX}_${layer}" >/dev/null; then
          echo granted
        elif grep -qiE 'lake ?formation|insufficient|permission|not authorized|access ?denied|does not exist|not found' <<< "$(athena_reason)"; then
          echo denied
        else
          echo error
        fi
      )"
      [[ "${actual}" != "${expected}" ]] || matches=$(( matches + 1 ))
      [[ "${actual}" != "granted" ]] || readable="${readable} ${layer}"
    done
  done
  CRITERION_DETAIL="${matches} de ${checks} combinacoes perfil x camada iguais a matriz declarada"
  [[ "${matches}" -eq "${checks}" ]] || return 1
  for layer in raw trusted refined; do
    [[ " ${readable} " == *" ${layer} "* ]] || return 1
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
  printf '%sregiao: %s (%s)%s\n' "${GRAY}" "${REGION}" "${REGION_SOURCE}" "${RESET}"
  printf '%sevidencias versionadas: execucao %s%s\n' "${GRAY}" "$(evidence_run_id)" "${RESET}"

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

  section "3. Decisoes e evidencias versionadas"
  criterion "DECISOES.md (Parte 2): grao, chaves, particao, formato e custo" p2_decisions_cover_topics
  criterion "DECISOES.md sem numeros pendentes de medicao"            p2_decisions_measured
  criterion "Evidencias de uma unica execucao, citadas no DECISOES.md e nas apresentacoes" p2_evidence_single_run_and_cited
  criterion "Meta de custo em bytes declarada e cumprida (refined)"   p2_cost_target_met
  criterion "Mesma resposta nas tres camadas (raw/trusted/refined)"   p2_layers_agree
  criterion "Granularidade comprovada (0 chave duplicada)"            p2_grain_proven
  criterion "Backfill registrado (>= 2 particoes EPSS carregadas)"    p2_backfill_recorded
  criterion "Ingestao idempotente comprovada (recarga sem duplicar)"  p2_idempotency_proven
  criterion "Matriz de acesso por camada comprovada (Lake Formation)" p2_access_matrix_proven
  criterion "Resultado da consulta de negocio salvo"                  test -f "${EVIDENCE}/business-question-result.csv"

  if [[ "${REPO_ONLY}" -eq 1 ]]; then
    criterion "Destroy da mesma execucao registrado, sem recursos orfaos" p2_destroy_recorded
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

  section "5. Medido agora na conta (Athena, consultas publicadas pela Terraform)"
  criterion "Meta de custo em bytes cumprida pela pergunta de negocio (refined)" p2_live_cost_target
  criterion "Mesma resposta nas tres camadas (raw / trusted / refined)"         p2_live_layers_agree
  criterion "Granularidade e idempotencia: 0 chave duplicada em toda tabela"    p2_live_grain
  criterion "Cada perfil le exatamente as camadas declaradas (Lake Formation)"  p2_live_access_matrix
}
