#!/usr/bin/env bash
#
# Proves the ingestion is idempotent: re-loads a day that is already in the lake -- raw,
# trusted and refined -- and checks that nothing was duplicated.
#
# An append-only INSERT INTO run twice would double the day's rows. Partition overwrite
# (clear the partition prefix, then insert) must leave the counts exactly as they were.
#
# Evidence: docs/evidence/part-2/idempotency-check.json
#
# Usage: scripts/part-2/check_idempotency.sh [--profile NAME] [--date yyyy-MM-dd]
#        (default date: the newest day in trusted.epss_scores)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
DAY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --date)    DAY="${2:?--date needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd aws jq awk terraform
use_profile "${PROFILE}"

TRUSTED_DB="$(tf_output trusted_db)"
REFINED_DB="$(tf_output refined_db)"
WORKGROUP="$(tf_output pipeline_workgroup)"
TRUSTED_URI="$(table_location trusted_epss_scores)"
REFINED_URI="$(table_location refined_vendor_exposure_daily)"

[[ -n "${DAY}" ]] || DAY="$(latest_partition "${TRUSTED_DB}" epss_scores)"
require_date "${DAY}"
glue_partition_values "${TRUSTED_DB}" epss_scores | grep -qx "${DAY}" \
  || die "${DAY} is not loaded yet -- idempotency is about re-loading a day that already exists"

PROFILE_ARGS=()
[[ -z "${PROFILE}" ]] || PROFILE_ARGS=(--profile "${PROFILE}")

# Prints "rows<TAB>distinct_keys" for the day in trusted and in refined.
measure() {
  local sql id
  sql="$(render_sql "${SQL_DIR}/etl/check_trusted_epss.sql" trusted_db="${TRUSTED_DB}" date_from="${DAY}" date_to="${DAY}")"
  id="$(athena_must "Counting trusted.epss_scores ${DAY}" "${sql}" "${WORKGROUP}" "${TRUSTED_DB}")"
  athena_rows_tsv "${id}" | awk -F'\t' '{ printf "%s\t%s\t", $2, $3 }'
  sql="$(render_sql "${SQL_DIR}/etl/check_refined.sql" refined_db="${REFINED_DB}" date_from="${DAY}" date_to="${DAY}")"
  id="$(athena_must "Counting refined.vendor_exposure_daily ${DAY}" "${sql}" "${WORKGROUP}" "${REFINED_DB}")"
  athena_rows_tsv "${id}" | awk -F'\t' '{ printf "%s\t%s\n", $2, $3 }'
}

log "Measuring ${DAY} before the re-load"
IFS=$'\t' read -r T_ROWS_1 T_KEYS_1 R_ROWS_1 R_KEYS_1 <<< "$(measure)"
T_FILES_1="$(count_partition_objects "${TRUSTED_URI}" snapshot_date "${DAY}")"
R_FILES_1="$(count_partition_objects "${REFINED_URI}" snapshot_date "${DAY}")"

log "Re-loading ${DAY} through every layer (the same commands a scheduled run would use)"
"${PART2_DIR}/ingest_epss.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --date "${DAY}" --evidence-file idempotency-epss-reload.json
"${PART2_DIR}/build_refined.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --date "${DAY}" --evidence-file idempotency-refined-rebuild.json

log "Measuring ${DAY} after the re-load"
IFS=$'\t' read -r T_ROWS_2 T_KEYS_2 R_ROWS_2 R_KEYS_2 <<< "$(measure)"
T_FILES_2="$(count_partition_objects "${TRUSTED_URI}" snapshot_date "${DAY}")"
R_FILES_2="$(count_partition_objects "${REFINED_URI}" snapshot_date "${DAY}")"

IDEMPOTENT=false
if [[ "${T_ROWS_1}" == "${T_ROWS_2}" && "${R_ROWS_1}" == "${R_ROWS_2}" \
   && "${T_ROWS_2}" == "${T_KEYS_2}" && "${R_ROWS_2}" == "${R_KEYS_2}" ]]; then
  IDEMPOTENT=true
fi

mkdir -p "${EVIDENCE_DIR}"
jq -n \
  --arg day "${DAY}" --arg checked_at "$(now_utc_iso)" --argjson idempotent "${IDEMPOTENT}" \
  --argjson t_rows_1 "${T_ROWS_1}" --argjson t_keys_1 "${T_KEYS_1}" --argjson t_files_1 "${T_FILES_1}" \
  --argjson t_rows_2 "${T_ROWS_2}" --argjson t_keys_2 "${T_KEYS_2}" --argjson t_files_2 "${T_FILES_2}" \
  --argjson r_rows_1 "${R_ROWS_1}" --argjson r_keys_1 "${R_KEYS_1}" --argjson r_files_1 "${R_FILES_1}" \
  --argjson r_rows_2 "${R_ROWS_2}" --argjson r_keys_2 "${R_KEYS_2}" --argjson r_files_2 "${R_FILES_2}" \
  '{
     day: $day,
     checked_at_utc: $checked_at,
     method: "partition overwrite: clear the partition prefix, then INSERT INTO",
     idempotent: $idempotent,
     trusted_epss_scores: {
       before: {rows: $t_rows_1, distinct_cve_id: $t_keys_1, s3_objects: $t_files_1},
       after:  {rows: $t_rows_2, distinct_cve_id: $t_keys_2, s3_objects: $t_files_2},
       rows_if_append_only: ($t_rows_1 * 2)
     },
     refined_vendor_exposure_daily: {
       before: {rows: $r_rows_1, distinct_vendors: $r_keys_1, s3_objects: $r_files_1},
       after:  {rows: $r_rows_2, distinct_vendors: $r_keys_2, s3_objects: $r_files_2},
       rows_if_append_only: ($r_rows_1 * 2)
     }
   }' > "${EVIDENCE_DIR}/idempotency-check.json"

echo
printf '%sIdempotency -- %s re-loaded%s\n' "${C_BOLD}" "${DAY}" "${C_RESET}"
printf '  trusted.epss_scores           rows %s -> %s  (append-only would give %s)\n' "${T_ROWS_1}" "${T_ROWS_2}" "$(( T_ROWS_1 * 2 ))"
printf '  refined.vendor_exposure_daily rows %s -> %s  (append-only would give %s)\n' "${R_ROWS_1}" "${R_ROWS_2}" "$(( R_ROWS_1 * 2 ))"
echo
ok "evidence -> ${EVIDENCE_DIR}/idempotency-check.json"

[[ "${IDEMPOTENT}" == "true" ]] || die "re-loading ${DAY} changed the row counts -- the load is NOT idempotent"
ok "idempotent: re-loading ${DAY} left every count unchanged"
