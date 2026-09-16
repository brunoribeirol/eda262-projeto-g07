#!/usr/bin/env bash
#
# Runs the graded Athena queries and measures what each one actually costs.
#
# The SQL is not duplicated here: it is fetched from the Athena named query that
# Terraform created, so what executes is provably what is in version control.
#
# Evidence written to docs/evidence/:
#   business-question-result.csv  -- the answer, straight from Athena's own output
#   query-cost.json               -- scanned bytes, billed bytes, runtime, USD cost
#   grain-check-result.csv        -- proof that the declared grain holds in the lake
#
# Usage: scripts/run_query.sh [--profile NAME] [--price-per-tb USD] [--quiet]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
# Athena scan pricing, us-east-1, as of 2026-09. Override for another region.
PRICE_PER_TB="5.00"
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --price-per-tb) PRICE_PER_TB="${2:?--price-per-tb needs a value}"; shift 2 ;;
    --quiet)        QUIET=1; shift ;;
    -h|--help)      sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd aws jq terraform awk

if [[ -n "${PROFILE}" ]]; then
  export AWS_PROFILE="${PROFILE}"
fi
export AWS_PROFILE_OVERRIDE="${PROFILE}"

LAKE_REGION="$(tf_output aws_region)"
export AWS_REGION_OVERRIDE="${LAKE_REGION}"

WORKGROUP="$(tf_output athena_workgroup)"
GLUE_DB="$(tf_output glue_database)"
RESULTS_BUCKET="$(tf_output athena_results_bucket)"

# Athena bills a 10 MB minimum per query regardless of how little it scans.
readonly ATHENA_MIN_BILLED_BYTES=10485760
readonly BYTES_PER_TB=1099511627776

mkdir -p "${EVIDENCE_DIR}"

# Executes a named query to completion and echoes its execution id.
run_named_query() {
  local named_query_id="$1" label="$2" sql execution_id state reason

  sql="$(aws_cli athena get-named-query \
          --named-query-id "${named_query_id}" \
          --query 'NamedQuery.QueryString' --output text)" \
    || die "could not fetch named query ${named_query_id}"

  log "Running: ${label}" >&2

  execution_id="$(aws_cli athena start-query-execution \
                    --query-string "${sql}" \
                    --work-group "${WORKGROUP}" \
                    --query-execution-context "Database=${GLUE_DB}" \
                    --query 'QueryExecutionId' --output text)" \
    || die "could not start query execution"

  # Poll. Athena has no blocking wait; these queries finish in seconds.
  local attempt=0
  while (( attempt < 120 )); do
    state="$(aws_cli athena get-query-execution \
               --query-execution-id "${execution_id}" \
               --query 'QueryExecution.Status.State' --output text)"
    case "${state}" in
      SUCCEEDED) break ;;
      FAILED|CANCELLED)
        reason="$(aws_cli athena get-query-execution \
                    --query-execution-id "${execution_id}" \
                    --query 'QueryExecution.Status.StateChangeReason' --output text 2>/dev/null || true)"
        die "query ${state}: ${reason:-no reason reported}"
        ;;
      *) sleep 1; attempt=$(( attempt + 1 )) ;;
    esac
  done
  [[ "${state}" == "SUCCEEDED" ]] || die "query did not finish within 120s (last state: ${state})"

  printf '%s' "${execution_id}"
}

# --- business question ---------------------------------------------------------
BQ_EXECUTION_ID="$(run_named_query "$(tf_output business_question_named_query_id)" "business question")"

STATS="$(aws_cli athena get-query-execution \
           --query-execution-id "${BQ_EXECUTION_ID}" \
           --query 'QueryExecution.Statistics' --output json)"

SCANNED_BYTES="$(jq -r '.DataScannedInBytes // 0' <<< "${STATS}")"
ENGINE_MS="$(jq -r '.EngineExecutionTimeInMillis // 0' <<< "${STATS}")"
TOTAL_MS="$(jq -r '.TotalExecutionTimeInMillis // 0' <<< "${STATS}")"

BILLED_BYTES="${SCANNED_BYTES}"
if (( BILLED_BYTES < ATHENA_MIN_BILLED_BYTES )); then
  BILLED_BYTES="${ATHENA_MIN_BILLED_BYTES}"
fi

COST_USD="$(awk -v b="${BILLED_BYTES}" -v tb="${BYTES_PER_TB}" -v p="${PRICE_PER_TB}" \
  'BEGIN { printf "%.8f", (b / tb) * p }')"
QUERIES_PER_USD="$(awk -v c="${COST_USD}" 'BEGIN { if (c > 0) printf "%d", 1 / c; else print 0 }')"

# Athena writes the authoritative result CSV to the workgroup's output location.
RESULT_CSV="${EVIDENCE_DIR}/business-question-result.csv"
aws_cli s3 cp "s3://${RESULTS_BUCKET}/${BQ_EXECUTION_ID}.csv" "${RESULT_CSV}" --only-show-errors \
  || die "could not download the result CSV for execution ${BQ_EXECUTION_ID}"

# --- grain check ---------------------------------------------------------------
GC_EXECUTION_ID="$(run_named_query "$(tf_output grain_check_named_query_id)" "grain assertion")"
GRAIN_CSV="${EVIDENCE_DIR}/grain-check-result.csv"
aws_cli s3 cp "s3://${RESULTS_BUCKET}/${GC_EXECUTION_ID}.csv" "${GRAIN_CSV}" --only-show-errors \
  || die "could not download the grain-check CSV"

# Row 1 is the header; row 2 holds total_rows, distinct_cve_id, duplicate_rows.
GRAIN_TOTAL="$(awk -F'","' 'NR==2 { gsub(/"/, "", $1); print $1 }' "${GRAIN_CSV}")"
GRAIN_DISTINCT="$(awk -F'","' 'NR==2 { gsub(/"/, "", $2); print $2 }' "${GRAIN_CSV}")"
GRAIN_DUPES="$(awk -F'","' 'NR==2 { gsub(/"/, "", $3); print $3 }' "${GRAIN_CSV}")"

if [[ "${GRAIN_DUPES}" != "0" ]]; then
  die "grain violated in the lake: ${GRAIN_DUPES} duplicate cve_id rows found"
fi

# --- evidence ------------------------------------------------------------------
COST_JSON="${EVIDENCE_DIR}/query-cost.json"
jq -n \
  --arg execution_id "${BQ_EXECUTION_ID}" \
  --arg workgroup "${WORKGROUP}" \
  --arg region "${LAKE_REGION}" \
  --arg measured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cost_usd "${COST_USD}" \
  --arg price_per_tb_usd "${PRICE_PER_TB}" \
  --argjson scanned_bytes "${SCANNED_BYTES}" \
  --argjson billed_bytes "${BILLED_BYTES}" \
  --argjson min_billed_bytes "${ATHENA_MIN_BILLED_BYTES}" \
  --argjson engine_ms "${ENGINE_MS}" \
  --argjson total_ms "${TOTAL_MS}" \
  --argjson queries_per_usd "${QUERIES_PER_USD}" \
  --argjson grain_total_rows "${GRAIN_TOTAL}" \
  --argjson grain_distinct_cve "${GRAIN_DISTINCT}" \
  --argjson grain_duplicate_rows "${GRAIN_DUPES}" \
  '{
     query: "top vendors by KEV count, last 12 months",
     execution_id: $execution_id,
     workgroup: $workgroup,
     region: $region,
     measured_at: $measured_at,
     data_scanned_bytes: $scanned_bytes,
     billed_bytes: $billed_bytes,
     athena_min_billed_bytes: $min_billed_bytes,
     engine_execution_ms: $engine_ms,
     total_execution_ms: $total_ms,
     price_per_tb_usd: $price_per_tb_usd,
     cost_usd: $cost_usd,
     queries_per_usd: $queries_per_usd,
     grain_check: {
       total_rows: $grain_total_rows,
       distinct_cve_id: $grain_distinct_cve,
       duplicate_rows: $grain_duplicate_rows
     }
   }' > "${COST_JSON}"

# --- report --------------------------------------------------------------------
if [[ "${QUIET}" -eq 0 ]]; then
  echo
  printf '%sBusiness question -- top vendors by KEV count, last 12 months%s\n' "${C_BOLD}" "${C_RESET}"
  echo
  # Render the CSV as an aligned table without pulling in an extra dependency.
  awk -F'","' '{ gsub(/^"|"$/, ""); printf "  %-28s %10s %10s %12s %10s %12s\n", $1, $2, $3, $4, $5, $6 }' \
    "${RESULT_CSV}" | head -16
  echo
  printf '%sMeasured cost%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  data scanned    : %s bytes\n' "${SCANNED_BYTES}"
  printf '  billed          : %s bytes (Athena 10 MB minimum applies)\n' "${BILLED_BYTES}"
  printf '  engine runtime  : %s ms (total %s ms)\n' "${ENGINE_MS}" "${TOTAL_MS}"
  printf '  cost            : USD %s at USD %s/TB\n' "${COST_USD}" "${PRICE_PER_TB}"
  printf '  i.e.            : ~%s runs of this query per USD 1.00\n' "${QUERIES_PER_USD}"
  echo
  printf '%sGrain assertion%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  %s rows / %s distinct cve_id / %s duplicates\n' "${GRAIN_TOTAL}" "${GRAIN_DISTINCT}" "${GRAIN_DUPES}"
  echo
fi

ok "result  -> ${RESULT_CSV}"
ok "cost    -> ${COST_JSON}"
ok "grain   -> ${GRAIN_CSV}"
