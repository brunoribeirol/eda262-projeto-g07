#!/usr/bin/env bash
#
# Answers the Part 2 business question and measures what it costs -- and what it would
# cost without each layer of the lake.
#
#   1. business question on refined (the graded query)    -> checked against the cost target
#   2. the same question recomputed from trusted Parquet  -> what the refined layer saves
#   3. the same question computed from the raw files      -> what the whole lake saves
#   4. one EPSS column for 1 day vs the whole window      -> what partitioning saves
#   5. grain assertion on every trusted/refined table
#
# The SQL is fetched from the Athena named queries Terraform created, so what runs is
# provably what is in parte-2/sql/analytics/. The three answers must be identical.
#
# Evidence written to docs/evidence/part-2/:
#   business-question-result.csv  the answer (refined)
#   query-cost.json               measured cost of the graded query vs the declared target
#   cost-comparison.json          raw vs trusted vs refined, and partition pruning
#   grain-check-result.csv        duplicate_rows per table (must all be 0)
#
# Usage: scripts/part-2/run_query.sh [--profile NAME] [--window-days 30] [--price-per-tb USD]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
WINDOW_DAYS=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --window-days)  WINDOW_DAYS="${2:?--window-days needs a value}"; shift 2 ;;
    --price-per-tb) PRICE_PER_TB="${2:?--price-per-tb needs a value}"; shift 2 ;;
    -h|--help)      sed -n '2,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd aws jq awk terraform cmp
[[ "${WINDOW_DAYS}" =~ ^[0-9]+$ && "${WINDOW_DAYS}" -ge 1 ]] || die "--window-days must be a positive integer"
use_profile "${PROFILE}"

RAW_DB="$(tf_output raw_db)"
TRUSTED_DB="$(tf_output trusted_db)"
REFINED_DB="$(tf_output refined_db)"
WORKGROUP="$(tf_output pipeline_workgroup)"
TARGET_BYTES="$(tf_output cost_target_bytes_per_query)"

# --- window -------------------------------------------------------------------------
LAST_DAY="$(latest_partition "${REFINED_DB}" vendor_exposure_daily)"
FIRST_DAY="$(date_shift "${LAST_DAY}" "-$(( WINDOW_DAYS - 1 ))")"
EARLIEST="$(glue_partition_values "${REFINED_DB}" vendor_exposure_daily | head -n 1)"
[[ ! "${FIRST_DAY}" < "${EARLIEST}" ]] || FIRST_DAY="${EARLIEST}"
KEV_DATE="$(latest_partition "${TRUSTED_DB}" kev_vulnerabilities)"
log "Window ${FIRST_DAY} .. ${LAST_DAY} | KEV snapshot ${KEV_DATE}"

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT
mkdir -p "${EVIDENCE_DIR}"

q() { printf "'%s'" "$1"; }   # a SQL string literal for an execution parameter

# --- 1-3. the business question on each layer ---------------------------------------
REFINED_ID="$(athena_must "Business question -- refined (graded)" \
  "$(named_query_sql business-question)" "${WORKGROUP}" "${REFINED_DB}" \
  "$(q "${FIRST_DAY}")" "$(q "${LAST_DAY}")")"

TRUSTED_ID="$(athena_must "Same question -- from trusted (comparison)" \
  "$(named_query_sql business-question-from-trusted)" "${WORKGROUP}" "${TRUSTED_DB}" \
  "$(q "${FIRST_DAY}")" "$(q "${LAST_DAY}")" "$(q "${FIRST_DAY}")" "$(q "${LAST_DAY}")" "$(q "${KEV_DATE}")")"

RAW_ID="$(athena_must "Same question -- from raw (comparison)" \
  "$(named_query_sql business-question-from-raw)" "${WORKGROUP}" "${RAW_DB}" \
  "$(q "${FIRST_DAY}")" "$(q "${LAST_DAY}")" "$(q "${FIRST_DAY}")" "$(q "${LAST_DAY}")" "$(q "${KEV_DATE}")")"

RESULT_CSV="${EVIDENCE_DIR}/business-question-result.csv"
athena_result_csv "${REFINED_ID}" "${RESULT_CSV}"
athena_result_csv "${TRUSTED_ID}" "${WORK_DIR}/from-trusted.csv"
athena_result_csv "${RAW_ID}" "${WORK_DIR}/from-raw.csv"

RESULTS_IDENTICAL=true
if ! cmp -s "${RESULT_CSV}" "${WORK_DIR}/from-trusted.csv" || ! cmp -s "${RESULT_CSV}" "${WORK_DIR}/from-raw.csv"; then
  RESULTS_IDENTICAL=false
  warn "the three layers returned different answers:"
  diff "${RESULT_CSV}" "${WORK_DIR}/from-trusted.csv" >&2 || true
  diff "${RESULT_CSV}" "${WORK_DIR}/from-raw.csv" >&2 || true
fi

# --- 4. partition pruning -----------------------------------------------------------
ONE_DAY_ID="$(athena_must "Pruning probe -- 1 day" \
  "$(named_query_sql epss-scan-profile)" "${WORKGROUP}" "${TRUSTED_DB}" "$(q "${LAST_DAY}")" "$(q "${LAST_DAY}")")"
ALL_DAYS_ID="$(athena_must "Pruning probe -- whole window" \
  "$(named_query_sql epss-scan-profile)" "${WORKGROUP}" "${TRUSTED_DB}" "$(q "${FIRST_DAY}")" "$(q "${LAST_DAY}")")"

# --- 5. grain -----------------------------------------------------------------------
GRAIN_ID="$(athena_must "Grain assertion -- trusted and refined" \
  "$(named_query_sql grain-check)" "${WORKGROUP}" "${TRUSTED_DB}")"
GRAIN_CSV="${EVIDENCE_DIR}/grain-check-result.csv"
athena_result_csv "${GRAIN_ID}" "${GRAIN_CSV}"
GRAIN_DUPLICATES="$(awk -F'","' 'NR > 1 { gsub(/"/, "", $5); total += $5 } END { print total + 0 }' "${GRAIN_CSV}")"

# --- evidence -----------------------------------------------------------------------
stats_with_cost() {
  local stats bytes
  stats="$(athena_stats "$1")"
  bytes="$(jq -r '.data_scanned_bytes' <<< "${stats}")"
  jq --argjson billed "$(billed_bytes "${bytes}")" --arg cost "$(cost_usd "${bytes}")" \
    '. + {billed_bytes: $billed, cost_usd: $cost}' <<< "${stats}"
}

REFINED_STATS="$(stats_with_cost "${REFINED_ID}")"
TRUSTED_STATS="$(stats_with_cost "${TRUSTED_ID}")"
RAW_STATS="$(stats_with_cost "${RAW_ID}")"
ONE_DAY_STATS="$(stats_with_cost "${ONE_DAY_ID}")"
ALL_DAYS_STATS="$(stats_with_cost "${ALL_DAYS_ID}")"

REFINED_BYTES="$(jq -r '.data_scanned_bytes' <<< "${REFINED_STATS}")"
TARGET_MET=false
(( REFINED_BYTES <= TARGET_BYTES )) && TARGET_MET=true
WINDOW_PARTITIONS="$(glue_partition_values "${REFINED_DB}" vendor_exposure_daily \
                      | awk -v f="${FIRST_DAY}" -v l="${LAST_DAY}" '$0 >= f && $0 <= l' | wc -l | tr -d ' ')"

jq -n \
  --arg first "${FIRST_DAY}" --arg last "${LAST_DAY}" --arg kev "${KEV_DATE}" \
  --arg region "$(tf_output aws_region)" --arg workgroup "${WORKGROUP}" \
  --arg measured_at "$(now_utc_iso)" --arg price "${PRICE_PER_TB}" \
  --argjson target "${TARGET_BYTES}" --argjson target_met "${TARGET_MET}" \
  --argjson min_billed "${ATHENA_MIN_BILLED_BYTES}" --argjson window_partitions "${WINDOW_PARTITIONS}" \
  --argjson stats "${REFINED_STATS}" --argjson grain_duplicates "${GRAIN_DUPLICATES}" \
  '{
     query: "top vendors by KEV CVEs added in the last 12 months, with their EPSS over the window",
     layer: "refined",
     window: {first_day: $first, last_day: $last, partitions: $window_partitions},
     kev_catalog_date: $kev,
     region: $region,
     workgroup: $workgroup,
     measured_at: $measured_at,
     execution_id: $stats.execution_id,
     data_scanned_bytes: $stats.data_scanned_bytes,
     billed_bytes: $stats.billed_bytes,
     athena_min_billed_bytes: $min_billed,
     engine_execution_ms: $stats.engine_execution_ms,
     total_execution_ms: $stats.total_execution_ms,
     price_per_tb_usd: $price,
     cost_usd: $stats.cost_usd,
     cost_target: {max_scanned_bytes: $target, met: $target_met},
     grain_check: {duplicate_rows: $grain_duplicates}
   }' > "${EVIDENCE_DIR}/query-cost.json"

jq -n \
  --argjson refined "${REFINED_STATS}" --argjson trusted "${TRUSTED_STATS}" --argjson raw "${RAW_STATS}" \
  --argjson one_day "${ONE_DAY_STATS}" --argjson all_days "${ALL_DAYS_STATS}" \
  --argjson identical "${RESULTS_IDENTICAL}" --arg first "${FIRST_DAY}" --arg last "${LAST_DAY}" \
  '{
     window: {first_day: $first, last_day: $last},
     results_identical_across_layers: $identical,
     business_question: {raw: $raw, trusted: $trusted, refined: $refined},
     scanned_bytes_ratio: {
       raw_over_refined: (if $refined.data_scanned_bytes > 0 then $raw.data_scanned_bytes / $refined.data_scanned_bytes else null end),
       raw_over_trusted: (if $trusted.data_scanned_bytes > 0 then $raw.data_scanned_bytes / $trusted.data_scanned_bytes else null end),
       trusted_over_refined: (if $refined.data_scanned_bytes > 0 then $trusted.data_scanned_bytes / $refined.data_scanned_bytes else null end)
     },
     partition_pruning: {
       one_day: $one_day,
       whole_window: $all_days,
       whole_window_over_one_day: (if $one_day.data_scanned_bytes > 0 then $all_days.data_scanned_bytes / $one_day.data_scanned_bytes else null end)
     }
   }' > "${EVIDENCE_DIR}/cost-comparison.json"

# --- report -------------------------------------------------------------------------
echo
printf '%sBusiness question -- %s .. %s%s\n\n' "${C_BOLD}" "${FIRST_DAY}" "${LAST_DAY}" "${C_RESET}"
awk -F'","' '{ gsub(/^"|"$/, ""); printf "  %-24s %8s %8s %8s %10s %10s %10s %6s\n", $1, $2, $3, $4, $5, $6, $7, $8 }' \
  "${RESULT_CSV}" | head -16
echo
printf '%sCost per execution of the same question%s\n' "${C_BOLD}" "${C_RESET}"
for layer in raw trusted refined; do
  jq -r --arg l "${layer}" '.business_question[$l] | "  \(($l + "        ")[0:8]) \(.data_scanned_bytes) bytes scanned  -> USD \(.cost_usd)"' \
    "${EVIDENCE_DIR}/cost-comparison.json"
done
jq -r '"  pruning   1 day: \(.partition_pruning.one_day.data_scanned_bytes) B | window: \(.partition_pruning.whole_window.data_scanned_bytes) B"' \
  "${EVIDENCE_DIR}/cost-comparison.json"
printf '  answers identical across layers: %s\n' "${RESULTS_IDENTICAL}"
printf '  grain duplicates (all tables):   %s\n\n' "${GRAIN_DUPLICATES}"

ok "result      -> ${RESULT_CSV}"
ok "cost        -> ${EVIDENCE_DIR}/query-cost.json"
ok "comparison  -> ${EVIDENCE_DIR}/cost-comparison.json"
ok "grain       -> ${GRAIN_CSV}"

# Fail loudly AFTER writing the evidence, so a miss is documented, not hidden.
[[ "${GRAIN_DUPLICATES}" -eq 0 ]] || die "grain violated: ${GRAIN_DUPLICATES} duplicate key rows"
[[ "${RESULTS_IDENTICAL}" == "true" ]] || die "the layers disagree on the answer -- a transformation is wrong"
[[ "${TARGET_MET}" == "true" ]] || die "cost target missed: ${REFINED_BYTES} bytes scanned > target ${TARGET_BYTES}"
ok "cost target met: ${REFINED_BYTES} bytes scanned <= ${TARGET_BYTES} (USD $(jq -r '.cost_usd' <<< "${REFINED_STATS}"))"
