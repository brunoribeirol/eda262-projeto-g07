#!/usr/bin/env bash
#
# Loads FIRST EPSS daily snapshots through raw -> trusted. Also the backfill command:
# any past day EPSS still publishes can be (re)loaded by date.
#
#   raw      epss_scores/snapshot_date=D/epss_scores-D.csv.gz   the file as published
#   trusted  epss_scores, partition snapshot_date=D (Parquet + ZSTD, via Athena INSERT)
#
# Idempotent by partition overwrite: each day's raw and trusted prefixes are cleared right
# before they are rewritten, so loading a day twice leaves exactly one copy of its rows.
# The trusted load runs in batches of up to --batch-days partitions per INSERT (Athena's
# hard limit is 100), because one INSERT over many files is billed once instead of paying
# the 10 MB minimum per day.
#
# Three ways to choose the days:
#   --incremental   everything EPSS published after the newest trusted day (the high-water
#                   mark) -- the routine daily run. Loading nothing is a valid outcome.
#   --days N        the last N published days -- the initial backfill
#   --date / --from --to   explicit days -- re-load or repair specific partitions
#
# Usage:
#   scripts/part-2/ingest_epss.sh --incremental
#   scripts/part-2/ingest_epss.sh --days 30                             # initial backfill
#   scripts/part-2/ingest_epss.sh --from 2026-09-21 --to 2026-10-20     # backfill a range
#   scripts/part-2/ingest_epss.sh --date 2026-10-20                     # re-load one day
# Options: [--profile NAME] [--to D] [--dry-run] [--source-dir DIR] [--batch-days N]
#          [--max-reject-ratio R] [--evidence-file NAME]
#
# --dry-run prints the resolved range as "FROM TO" (nothing when up to date) and exits.
# Every run that loads data appends one summary line to docs/evidence/part-2/load-history.jsonl.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EPSS_URL="https://epss.empiricalsecurity.com"
PROFILE=""
FROM=""
TO=""
DAYS=""
INCREMENTAL=0
DRY_RUN=0
SOURCE_DIR=""
BATCH_DAYS=30
MAX_REJECT_RATIO="0.001"
EVIDENCE_FILE="epss-ingest.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)          PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --date)             FROM="${2:?--date needs a value}"; TO="$2"; shift 2 ;;
    --from)             FROM="${2:?--from needs a value}"; shift 2 ;;
    --to)               TO="${2:?--to needs a value}"; shift 2 ;;
    --days)             DAYS="${2:?--days needs a value}"; shift 2 ;;
    --incremental)      INCREMENTAL=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --source-dir)       SOURCE_DIR="${2:?--source-dir needs a value}"; shift 2 ;;
    --batch-days)       BATCH_DAYS="${2:?--batch-days needs a value}"; shift 2 ;;
    --max-reject-ratio) MAX_REJECT_RATIO="${2:?--max-reject-ratio needs a value}"; shift 2 ;;
    --evidence-file)    EVIDENCE_FILE="${2:?--evidence-file needs a value}"; shift 2 ;;
    -h|--help)          sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd aws jq curl gzip awk terraform
[[ "${BATCH_DAYS}" =~ ^[0-9]+$ && "${BATCH_DAYS}" -ge 1 && "${BATCH_DAYS}" -le 100 ]] \
  || die "--batch-days must be between 1 and 100 (Athena writes at most 100 partitions per INSERT)"
[[ "${EVIDENCE_FILE}" =~ ^[a-z0-9._-]+\.json$ ]] || die "--evidence-file must be a plain file name ending in .json"
MODE="explicit"
[[ -z "${DAYS}" ]] || MODE="backfill"
[[ "${INCREMENTAL}" -eq 0 ]] || MODE="incremental"

# --- resolve the date range --------------------------------------------------------
# EPSS publishes once a day (~12:00 UTC). The latest available day is today if its file
# already exists, otherwise yesterday.
latest_published_day() {
  local today
  today="$(date -u '+%Y-%m-%d')"
  if curl -fsIL --max-time 30 "${EPSS_URL}/epss_scores-${today}.csv.gz" >/dev/null 2>&1; then
    printf '%s' "${today}"
  else
    date_shift "${today}" -1
  fi
}

use_profile "${PROFILE}"
RAW_DB="$(tf_output raw_db)"
TRUSTED_DB="$(tf_output trusted_db)"

if [[ "${INCREMENTAL}" -eq 1 ]]; then
  [[ -z "${DAYS}" && -z "${FROM}" ]] || die "--incremental decides the range itself; drop --days/--date/--from"
  LOADED_DAYS="$(glue_partition_values "${TRUSTED_DB}" epss_scores)"
  [[ -n "${LOADED_DAYS}" ]] \
    || die "no trusted EPSS day yet, so there is no high-water mark. Run the initial backfill first: --days 30"
  WATERMARK="$(tail -n 1 <<< "${LOADED_DAYS}")"

  # A gap behind the watermark is never refilled by an incremental run -- surface it.
  GAPS="$(date_range "$(head -n 1 <<< "${LOADED_DAYS}")" "${WATERMARK}" \
          | LOADED="${LOADED_DAYS}" awk 'BEGIN { n = split(ENVIRON["LOADED"], d, "\n"); for (i = 1; i <= n; i++) seen[d[i]] = 1 }
                                         !($0 in seen)')"
  if [[ -n "${GAPS}" ]]; then
    warn "$(wc -l <<< "${GAPS}" | tr -d ' ') day(s) missing behind the high-water mark: $(tr '\n' ' ' <<< "${GAPS}")"
    warn "repair with: scripts/part-2/ingest_epss.sh --from <day> --to <day>"
  fi

  [[ -n "${TO}" ]] || TO="$(latest_published_day)"
  require_date "${TO}"
  FROM="$(date_shift "${WATERMARK}" 1)"
  if [[ "${FROM}" > "${TO}" ]]; then
    [[ "${DRY_RUN}" -eq 1 ]] || ok "trusted.epss_scores is up to date (high-water mark ${WATERMARK}, latest published ${TO})"
    exit 0
  fi
  log "High-water mark ${WATERMARK}: loading ${FROM} .. ${TO}" >&2   # stderr: --dry-run output stays parseable
elif [[ -n "${DAYS}" ]]; then
  [[ "${DAYS}" =~ ^[0-9]+$ && "${DAYS}" -ge 1 ]] || die "--days must be a positive integer"
  [[ -n "${TO}" ]] || TO="$(latest_published_day)"
  FROM="$(date_shift "${TO}" "-$(( DAYS - 1 ))")"
fi
[[ -n "${FROM}" && -n "${TO}" ]] || die "give --incremental, --days, --date or --from/--to (see --help)"
require_date "${FROM}"
require_date "${TO}"
[[ ! "${FROM}" > "${TO}" ]] || die "--from (${FROM}) is after --to (${TO})"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '%s %s\n' "${FROM}" "${TO}"
  exit 0
fi

WORKGROUP="$(tf_output pipeline_workgroup)"
RAW_URI="$(table_location raw_epss_scores)"
TRUSTED_URI="$(table_location trusted_epss_scores)"

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT
MANIFEST="${WORK_DIR}/manifest.tsv"   # snapshot_date, data_rows, bytes, model_version
BATCHES="${WORK_DIR}/batches.jsonl"
: > "${MANIFEST}"
: > "${BATCHES}"

DAY_LIST=()
while IFS= read -r d; do DAY_LIST+=("${d}"); done <<< "$(date_range "${FROM}" "${TO}")"
log "EPSS range ${FROM} .. ${TO}: ${#DAY_LIST[@]} day(s)"

# --- acquire + gates before upload ----------------------------------------------------
for d in "${DAY_LIST[@]}"; do
  file="${WORK_DIR}/epss_scores-${d}.csv.gz"
  if [[ -n "${SOURCE_DIR}" && -f "${SOURCE_DIR}/epss_scores-${d}.csv.gz" ]]; then
    cp "${SOURCE_DIR}/epss_scores-${d}.csv.gz" "${file}"
  else
    curl -fsSL --retry 3 --retry-delay 2 --max-time 120 "${EPSS_URL}/epss_scores-${d}.csv.gz" -o "${file}" \
      || die "download failed for ${d} -- EPSS has not published that day (or it is unreachable)"
  fi

  gzip -t "${file}" 2>/dev/null || die "gate failed: ${d} is not a valid gzip file"
  header="$(gzip -dc "${file}" | head -n 2 | tr -d '\r' || true)"
  meta_line="$(sed -n 1p <<< "${header}")"
  columns_line="$(sed -n 2p <<< "${header}")"

  [[ "${meta_line}" =~ ^\#model_version:([^,]+),score_date:([0-9]{4}-[0-9]{2}-[0-9]{2}) ]] \
    || die "gate failed: ${d} has no '#model_version/score_date' metadata line"
  model_version="${BASH_REMATCH[1]}"
  score_date="${BASH_REMATCH[2]}"
  [[ "${score_date}" == "${d}" ]] || die "gate failed: file for ${d} declares score_date ${score_date}"
  [[ "${columns_line}" == "cve,epss,percentile" ]] || die "gate failed: ${d} has an unexpected header: ${columns_line}"

  data_rows="$(gzip -dc "${file}" | awk 'END { print NR - 2 }')"
  bytes="$(wc -c < "${file}" | tr -d ' ')"
  [[ "${data_rows}" -gt 0 ]] || die "gate failed: ${d} has no data rows"
  printf '%s\t%s\t%s\t%s\n' "${d}" "${data_rows}" "${bytes}" "${model_version}" >> "${MANIFEST}"
done
ok "${#DAY_LIST[@]} file(s) passed the header, date and integrity gates"

# --- raw -------------------------------------------------------------------------
log "Publishing raw partitions"
for d in "${DAY_LIST[@]}"; do
  clear_partition "${RAW_URI}" snapshot_date "${d}"
  aws_cli s3 cp "${WORK_DIR}/epss_scores-${d}.csv.gz" "${RAW_URI}snapshot_date=${d}/epss_scores-${d}.csv.gz" --only-show-errors
done
ok "raw: ${#DAY_LIST[@]} partition(s) under ${RAW_URI}"

# --- trusted, in batches ----------------------------------------------------------
INGESTED_AT="$(now_utc_sql)"
i=0
while (( i < ${#DAY_LIST[@]} )); do
  last=$(( i + BATCH_DAYS - 1 ))
  (( last < ${#DAY_LIST[@]} )) || last=$(( ${#DAY_LIST[@]} - 1 ))
  batch_from="${DAY_LIST[$i]}"
  batch_to="${DAY_LIST[$last]}"

  j="${i}"
  while (( j <= last )); do
    clear_partition "${TRUSTED_URI}" snapshot_date "${DAY_LIST[$j]}"
    j=$(( j + 1 ))
  done

  sql="$(render_sql "${SQL_DIR}/etl/trusted_epss_scores.sql" \
          raw_db="${RAW_DB}" trusted_db="${TRUSTED_DB}" \
          date_from="${batch_from}" date_to="${batch_to}" ingested_at="${INGESTED_AT}")"
  execution_id="$(athena_must "Loading trusted.epss_scores ${batch_from} .. ${batch_to}" "${sql}" "${WORKGROUP}" "${TRUSTED_DB}")"
  athena_stats "${execution_id}" \
    | jq -c --arg from "${batch_from}" --arg to "${batch_to}" --argjson days $(( last - i + 1 )) \
        '{from: $from, to: $to, partitions: $days} + .' >> "${BATCHES}"
  i=$(( last + 1 ))
done

# --- gates after load ---------------------------------------------------------------
check_sql="$(render_sql "${SQL_DIR}/etl/check_trusted_epss.sql" trusted_db="${TRUSTED_DB}" date_from="${FROM}" date_to="${TO}")"
check_id="$(athena_must "Checking trusted partitions" "${check_sql}" "${WORKGROUP}" "${TRUSTED_DB}")"
athena_rows_tsv "${check_id}" > "${WORK_DIR}/trusted.tsv"

# Joins the manifest (what was downloaded) with what landed in trusted, per day.
awk -F'\t' -v max_ratio="${MAX_REJECT_RATIO}" '
  NR == FNR { expected[$1] = $2; next }
  {
    loaded[$1] = 1
    if ($2 != $3)        { printf "grain violated on %s: %s rows / %s distinct cve_id\n", $1, $2, $3; bad = 1 }
    if ($4 != 1)         { printf "%s mixes %s EPSS model versions\n", $1, $4; bad = 1 }
    rejected = expected[$1] - $2
    if (rejected < 0 || rejected > expected[$1] * max_ratio) {
      printf "%s: %s source rows, %s trusted rows (%s rejected)\n", $1, expected[$1], $2, rejected; bad = 1
    }
  }
  END {
    for (d in expected) if (!(d in loaded)) { printf "%s: no rows reached trusted\n", d; bad = 1 }
    exit bad
  }' "${MANIFEST}" "${WORK_DIR}/trusted.tsv" \
  || die "gate failed on the trusted load (see above)"
ok "trusted: every day landed with its source row count, 1 model version and 0 duplicate keys"

# --- evidence --------------------------------------------------------------------
mkdir -p "${EVIDENCE_DIR}"
jq -n \
  --arg mode "${MODE}" --arg from "${FROM}" --arg to "${TO}" --arg ingested_at "${INGESTED_AT}" \
  --slurpfile batches "${BATCHES}" \
  --argjson days "$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
                      | {snapshot_date: .[0], source_rows: (.[1] | tonumber),
                         source_gzip_bytes: (.[2] | tonumber), model_version: .[3]})' "${MANIFEST}")" \
  --argjson trusted "$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
                      | {snapshot_date: .[0], rows: (.[1] | tonumber), distinct_cve_id: (.[2] | tonumber)})' "${WORK_DIR}/trusted.tsv")" \
  '{
     source: "first-epss",
     mode: $mode,
     range: {from: $from, to: $to},
     partitions: ($days | length),
     ingested_at_utc: $ingested_at,
     totals: {
       source_rows: ($days | map(.source_rows) | add),
       source_gzip_bytes: ($days | map(.source_gzip_bytes) | add),
       trusted_rows: ($trusted | map(.rows) | add),
       insert_scanned_bytes: ($batches | map(.data_scanned_bytes) | add)
     },
     grain: "one row per (cve_id, snapshot_date)",
     days: $days,
     trusted: $trusted,
     trusted_inserts: $batches
   }' > "${EVIDENCE_DIR}/${EVIDENCE_FILE}"

# One line per load, never rewritten: the lake's growth over time, run by run.
jq -c '{
    ingested_at_utc, source, mode, from: .range.from, to: .range.to, partitions,
    source_rows: .totals.source_rows, trusted_rows: .totals.trusted_rows,
    insert_scanned_bytes: .totals.insert_scanned_bytes,
    inserts: (.trusted_inserts | length)
  }' "${EVIDENCE_DIR}/${EVIDENCE_FILE}" >> "${EVIDENCE_DIR}/load-history.jsonl"

ok "evidence -> ${EVIDENCE_DIR}/${EVIDENCE_FILE} (+1 line in load-history.jsonl)"
