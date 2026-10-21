#!/usr/bin/env bash
#
# Builds refined.vendor_exposure_daily (trusted -> refined) for a range of EPSS days.
#
# Uses one KEV snapshot as the dimension (the latest trusted one unless told otherwise)
# and applies the point-in-time rule documented in the SQL. Idempotent by partition
# overwrite, in batches of up to --batch-days partitions per INSERT.
#
# Usage:
#   scripts/part-2/build_refined.sh --from 2026-09-21 --to 2026-10-20
#   scripts/part-2/build_refined.sh --date 2026-10-20
# Options: [--profile NAME] [--kev-catalog-date D] [--batch-days N] [--evidence-file NAME]
#
# Incremental runs build only the new days, each with the KEV snapshot current at build
# time (recorded per row in kev_catalog_date). Rebuilding a whole range with one snapshot
# is a deliberate full refresh: pass the range explicitly.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
FROM=""
TO=""
KEV_CATALOG_DATE=""
BATCH_DAYS=30
EVIDENCE_FILE="refined-build.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)          PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --date)             FROM="${2:?--date needs a value}"; TO="$2"; shift 2 ;;
    --from)             FROM="${2:?--from needs a value}"; shift 2 ;;
    --to)               TO="${2:?--to needs a value}"; shift 2 ;;
    --kev-catalog-date) KEV_CATALOG_DATE="${2:?--kev-catalog-date needs a value}"; shift 2 ;;
    --batch-days)       BATCH_DAYS="${2:?--batch-days needs a value}"; shift 2 ;;
    --evidence-file)    EVIDENCE_FILE="${2:?--evidence-file needs a value}"; shift 2 ;;
    -h|--help)          sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "${EVIDENCE_FILE}" =~ ^[a-z0-9._-]+\.json$ ]] || die "--evidence-file must be a plain file name ending in .json"

require_cmd aws jq awk terraform
[[ -n "${FROM}" && -n "${TO}" ]] || die "give --date or --from/--to (see --help)"
require_date "${FROM}"
require_date "${TO}"
[[ ! "${FROM}" > "${TO}" ]] || die "--from (${FROM}) is after --to (${TO})"
[[ "${BATCH_DAYS}" =~ ^[0-9]+$ && "${BATCH_DAYS}" -ge 1 && "${BATCH_DAYS}" -le 100 ]] \
  || die "--batch-days must be between 1 and 100"

use_profile "${PROFILE}"

TRUSTED_DB="$(tf_output trusted_db)"
REFINED_DB="$(tf_output refined_db)"
WORKGROUP="$(tf_output pipeline_workgroup)"
REFINED_URI="$(table_location refined_vendor_exposure_daily)"

if [[ -z "${KEV_CATALOG_DATE}" ]]; then
  KEV_CATALOG_DATE="$(latest_partition "${TRUSTED_DB}" kev_vulnerabilities)"
fi
require_date "${KEV_CATALOG_DATE}"
log "KEV dimension: trusted.kev_vulnerabilities catalog_date=${KEV_CATALOG_DATE}"

# Only days that exist in trusted can be built; anything else would be an empty partition.
TRUSTED_DAYS="$(glue_partition_values "${TRUSTED_DB}" epss_scores)"
DAY_LIST=()
while IFS= read -r d; do
  if grep -qx "${d}" <<< "${TRUSTED_DAYS}"; then
    DAY_LIST+=("${d}")
  else
    warn "skipping ${d}: no trusted.epss_scores partition (run ingest_epss.sh for it first)"
  fi
done <<< "$(date_range "${FROM}" "${TO}")"
[[ ${#DAY_LIST[@]} -gt 0 ]] || die "no trusted EPSS day in ${FROM} .. ${TO}"

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT
BATCHES="${WORK_DIR}/batches.jsonl"
: > "${BATCHES}"

BUILT_AT="$(now_utc_sql)"
i=0
while (( i < ${#DAY_LIST[@]} )); do
  last=$(( i + BATCH_DAYS - 1 ))
  (( last < ${#DAY_LIST[@]} )) || last=$(( ${#DAY_LIST[@]} - 1 ))
  batch_from="${DAY_LIST[$i]}"
  batch_to="${DAY_LIST[$last]}"

  j="${i}"
  while (( j <= last )); do
    clear_partition "${REFINED_URI}" snapshot_date "${DAY_LIST[$j]}"
    j=$(( j + 1 ))
  done

  sql="$(render_sql "${SQL_DIR}/etl/refined_vendor_exposure_daily.sql" \
          trusted_db="${TRUSTED_DB}" refined_db="${REFINED_DB}" \
          date_from="${batch_from}" date_to="${batch_to}" \
          kev_catalog_date="${KEV_CATALOG_DATE}" built_at="${BUILT_AT}")"
  execution_id="$(athena_must "Building refined.vendor_exposure_daily ${batch_from} .. ${batch_to}" "${sql}" "${WORKGROUP}" "${REFINED_DB}")"
  athena_stats "${execution_id}" \
    | jq -c --arg from "${batch_from}" --arg to "${batch_to}" --argjson days $(( last - i + 1 )) \
        '{from: $from, to: $to, partitions: $days} + .' >> "${BATCHES}"
  i=$(( last + 1 ))
done

# --- gates after load ---------------------------------------------------------------
check_sql="$(render_sql "${SQL_DIR}/etl/check_refined.sql" refined_db="${REFINED_DB}" date_from="${FROM}" date_to="${TO}")"
check_id="$(athena_must "Checking refined partitions" "${check_sql}" "${WORKGROUP}" "${REFINED_DB}")"
athena_rows_tsv "${check_id}" > "${WORK_DIR}/refined.tsv"

BUILT_DAYS="$(wc -l < "${WORK_DIR}/refined.tsv" | tr -d ' ')"
[[ "${BUILT_DAYS}" -eq ${#DAY_LIST[@]} ]] || die "gate failed: ${#DAY_LIST[@]} day(s) requested, ${BUILT_DAYS} built"
awk -F'\t' '$2 != $3 { printf "grain violated on %s: %s rows / %s vendors\n", $1, $2, $3; bad = 1 } END { exit bad }' \
  "${WORK_DIR}/refined.tsv" || die "gate failed: refined grain (vendor_project, snapshot_date) violated"
ok "refined: ${BUILT_DAYS} day(s), one row per vendor per day"

# --- evidence --------------------------------------------------------------------
mkdir -p "${EVIDENCE_DIR}"
jq -n \
  --arg from "${FROM}" --arg to "${TO}" --arg kev "${KEV_CATALOG_DATE}" --arg built_at "${BUILT_AT}" \
  --slurpfile batches "${BATCHES}" \
  --argjson days "$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
                     | {snapshot_date: .[0], rows: (.[1] | tonumber), vendors: (.[2] | tonumber),
                        kev_cves: (.[3] | tonumber), epss_scored_cves: (.[4] | tonumber)})' "${WORK_DIR}/refined.tsv")" \
  '{
     table: "refined.vendor_exposure_daily",
     grain: "one row per (vendor_project, snapshot_date)",
     range: {from: $from, to: $to},
     kev_catalog_date: $kev,
     built_at_utc: $built_at,
     partitions: ($days | length),
     rows: ($days | map(.rows) | add),
     inserts: $batches,
     days: $days
   }' > "${EVIDENCE_DIR}/${EVIDENCE_FILE}"

jq -c '{
    ingested_at_utc: .built_at_utc, source: "refined.vendor_exposure_daily", mode: "build",
    from: .range.from, to: .range.to, partitions, rows, kev_catalog_date,
    insert_scanned_bytes: (.inserts | map(.data_scanned_bytes) | add),
    inserts: (.inserts | length)
  }' "${EVIDENCE_DIR}/${EVIDENCE_FILE}" >> "${EVIDENCE_DIR}/load-history.jsonl"

ok "evidence -> ${EVIDENCE_DIR}/${EVIDENCE_FILE} (+1 line in load-history.jsonl)"
