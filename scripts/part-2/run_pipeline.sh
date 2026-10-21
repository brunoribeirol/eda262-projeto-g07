#!/usr/bin/env bash
#
# Runs the Part 2 pipeline end to end:
#   1. KEV snapshot          raw -> trusted     (ingest_kev.sh)
#   2. EPSS daily scores     raw -> trusted     (ingest_epss.sh)
#   3. vendor exposure       trusted -> refined (build_refined.sh)
#
# Two modes:
#   --days N        initial backfill: the last N published EPSS days, then refined for them
#   --incremental   routine run (default): only what is new since the last run. Each layer
#                   keeps its own high-water mark -- the newest partition it holds -- so if a
#                   previous run died between trusted and refined, refined catches up here.
#
# Every step is idempotent (partition overwrite), so any failure is fixed by re-running.
#
# Usage:
#   scripts/part-2/run_pipeline.sh --days 30          # first load
#   scripts/part-2/run_pipeline.sh                    # every later run (= --incremental)
# Options: [--profile NAME] [--to yyyy-MM-dd]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
DAYS=""
TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)     PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --days)        DAYS="${2:?--days needs a value}"; shift 2 ;;
    --incremental) DAYS=""; shift ;;
    --to)          TO="${2:?--to needs a value}"; shift 2 ;;
    -h|--help)     sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -z "${DAYS}" ]] || [[ "${DAYS}" =~ ^[0-9]+$ && "${DAYS}" -ge 1 ]] || die "--days must be a positive integer"
[[ -z "${TO}" ]] || require_date "${TO}"
use_profile "${PROFILE}"

TRUSTED_DB="$(tf_output trusted_db)"
REFINED_DB="$(tf_output refined_db)"

PROFILE_ARGS=()
[[ -z "${PROFILE}" ]] || PROFILE_ARGS=(--profile "${PROFILE}")
TO_ARGS=()
[[ -z "${TO}" ]] || TO_ARGS=(--to "${TO}")

step() { printf '\n%s[%s/3]%s %s\n' "${C_BOLD}" "$1" "${C_RESET}" "$2"; }

step 1 "KEV catalog snapshot"
"${PART2_DIR}/ingest_kev.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}

if [[ -n "${DAYS}" ]]; then
  step 2 "EPSS initial backfill: last ${DAYS} published day(s)"
  "${PART2_DIR}/ingest_epss.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --days "${DAYS}" ${TO_ARGS[@]+"${TO_ARGS[@]}"}
  REFINED_FROM="$(jq -r '.range.from' "${EVIDENCE_DIR}/epss-ingest.json")"
  REFINED_TO="$(jq -r '.range.to' "${EVIDENCE_DIR}/epss-ingest.json")"
else
  step 2 "EPSS incremental load (from the trusted high-water mark)"
  "${PART2_DIR}/ingest_epss.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --incremental ${TO_ARGS[@]+"${TO_ARGS[@]}"}

  TRUSTED_MARK="$(latest_partition "${TRUSTED_DB}" epss_scores)"
  REFINED_MARK="$(glue_partition_values "${REFINED_DB}" vendor_exposure_daily | tail -n 1)"
  if [[ -z "${REFINED_MARK}" ]]; then
    REFINED_FROM="$(glue_partition_values "${TRUSTED_DB}" epss_scores | head -n 1)"
  else
    REFINED_FROM="$(date_shift "${REFINED_MARK}" 1)"
  fi
  REFINED_TO="${TRUSTED_MARK}"
fi

if [[ "${REFINED_FROM}" > "${REFINED_TO}" ]]; then
  step 3 "Refined layer"
  ok "refined.vendor_exposure_daily is up to date (high-water mark ${REFINED_TO})"
else
  step 3 "Refined layer ${REFINED_FROM} .. ${REFINED_TO}"
  "${PART2_DIR}/build_refined.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --from "${REFINED_FROM}" --to "${REFINED_TO}"
fi

cat <<NEXT

Load history: ${EVIDENCE_DIR}/load-history.jsonl
Next:
  scripts/part-2/run_query.sh ${PROFILE:+--profile ${PROFILE}}
NEXT
