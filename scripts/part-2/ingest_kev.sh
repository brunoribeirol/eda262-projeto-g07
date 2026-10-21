#!/usr/bin/env bash
#
# Loads one CISA KEV catalog snapshot through raw -> trusted.
#
#   raw      kev_catalog/catalog_date=D/   the source document, byte-for-byte (archive)
#            kev_records/catalog_date=D/   the same entries, one JSON object per line
#   trusted  kev_vulnerabilities, partition catalog_date=D (Parquet, via Athena INSERT)
#
# Idempotent: every write replaces its partition, so re-running for the same catalog
# leaves exactly one copy of each row. Gates run before upload and after the load.
#
# Usage: scripts/part-2/ingest_kev.sh [--profile NAME] [--source-file PATH] [--keep-local]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEV_URL="https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
PROFILE=""
SOURCE_FILE=""
KEEP_LOCAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)     PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --source-file) SOURCE_FILE="${2:?--source-file needs a value}"; shift 2 ;;
    --keep-local)  KEEP_LOCAL=1; shift ;;
    -h|--help)     sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd aws jq curl terraform
use_profile "${PROFILE}"

RAW_DB="$(tf_output raw_db)"
TRUSTED_DB="$(tf_output trusted_db)"
WORKGROUP="$(tf_output pipeline_workgroup)"
ARCHIVE_URI="$(tf_output kev_catalog_archive_uri)"
RAW_URI="$(table_location raw_kev_records)"
TRUSTED_URI="$(table_location trusted_kev_vulnerabilities)"

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064  # WORK_DIR must expand now, not at trap time
trap "[[ ${KEEP_LOCAL} -eq 1 ]] || rm -rf '${WORK_DIR}'" EXIT

SOURCE_DOC="${WORK_DIR}/known_exploited_vulnerabilities.json"
RECORDS="${WORK_DIR}/kev_records.json"

# --- acquire ---------------------------------------------------------------------
if [[ -n "${SOURCE_FILE}" ]]; then
  [[ -f "${SOURCE_FILE}" ]] || die "source file not found: ${SOURCE_FILE}"
  log "Using local KEV document: ${SOURCE_FILE}"
  cp "${SOURCE_FILE}" "${SOURCE_DOC}"
else
  log "Downloading the CISA KEV catalog"
  curl -fsSL --retry 3 --retry-delay 2 --max-time 120 "${KEV_URL}" -o "${SOURCE_DOC}" \
    || die "download failed: ${KEV_URL}"
fi

jq -e . "${SOURCE_DOC}" >/dev/null 2>&1 || die "gate failed: the KEV document is not valid JSON"

CATALOG_VERSION="$(jq -r '.catalogVersion // empty' "${SOURCE_DOC}")"
CATALOG_DATE="$(jq -r '(.dateReleased // "")[0:10]' "${SOURCE_DOC}")"
DECLARED_COUNT="$(jq -r '.count // 0' "${SOURCE_DOC}")"
ACTUAL_COUNT="$(jq -r '.vulnerabilities | length' "${SOURCE_DOC}")"
SOURCE_BYTES="$(wc -c < "${SOURCE_DOC}" | tr -d ' ')"

[[ "${CATALOG_VERSION}" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || die "gate failed: unexpected catalogVersion '${CATALOG_VERSION}'"
require_date "${CATALOG_DATE}"
ok "catalogVersion ${CATALOG_VERSION} (released ${CATALOG_DATE}): ${ACTUAL_COUNT} entries, ${SOURCE_BYTES} bytes"

# --- gates before upload -----------------------------------------------------------
[[ "${DECLARED_COUNT}" -eq "${ACTUAL_COUNT}" ]] \
  || die "gate failed: the feed declares ${DECLARED_COUNT} entries but ships ${ACTUAL_COUNT}"

# Re-frame to one object per line. Values are not touched -- the gate below proves it.
jq -c '.vulnerabilities[]' "${SOURCE_DOC}" > "${RECORDS}" || die "re-framing to JSON lines failed"
RECORD_LINES="$(wc -l < "${RECORDS}" | tr -d ' ')"
RECORD_BYTES="$(wc -c < "${RECORDS}" | tr -d ' ')"

[[ "${RECORD_LINES}" -eq "${ACTUAL_COUNT}" ]] \
  || die "gate failed: ${ACTUAL_COUNT} entries became ${RECORD_LINES} lines"
jq -e -n --slurpfile doc "${SOURCE_DOC}" --slurpfile lines "${RECORDS}" '$doc[0].vulnerabilities == $lines' >/dev/null \
  || die "gate failed: the JSON-lines file is not a lossless copy of the source entries"
ok "re-framed losslessly: ${RECORD_LINES} lines, values identical to the source"

UNTRIMMED_SOURCE="$(jq '[.vulnerabilities[] | select((.vendorProject | test("^\\s|\\s$")) or (.product | test("^\\s|\\s$")))] | length' "${SOURCE_DOC}")"

# --- raw -------------------------------------------------------------------------
log "Publishing raw partition catalog_date=${CATALOG_DATE}"
clear_partition "${ARCHIVE_URI}" catalog_date "${CATALOG_DATE}"
aws_cli s3 cp "${SOURCE_DOC}" "${ARCHIVE_URI}catalog_date=${CATALOG_DATE}/known_exploited_vulnerabilities.json" --only-show-errors
clear_partition "${RAW_URI}" catalog_date "${CATALOG_DATE}"
aws_cli s3 cp "${RECORDS}" "${RAW_URI}catalog_date=${CATALOG_DATE}/kev_records.json" --only-show-errors

# --- trusted ---------------------------------------------------------------------
INGESTED_AT="$(now_utc_sql)"
clear_partition "${TRUSTED_URI}" catalog_date "${CATALOG_DATE}"

SQL="$(render_sql "${SQL_DIR}/etl/trusted_kev_vulnerabilities.sql" \
        raw_db="${RAW_DB}" trusted_db="${TRUSTED_DB}" catalog_date="${CATALOG_DATE}" \
        catalog_version="${CATALOG_VERSION}" ingested_at="${INGESTED_AT}")"
INSERT_ID="$(athena_must "Loading trusted.kev_vulnerabilities (raw -> Parquet)" "${SQL}" "${WORKGROUP}" "${TRUSTED_DB}")"
INSERT_STATS="$(athena_stats "${INSERT_ID}")"

# --- gates after load ---------------------------------------------------------------
CHECK_SQL="$(render_sql "${SQL_DIR}/etl/check_trusted_kev.sql" trusted_db="${TRUSTED_DB}" catalog_date="${CATALOG_DATE}")"
CHECK_ID="$(athena_must "Checking the trusted partition" "${CHECK_SQL}" "${WORKGROUP}" "${TRUSTED_DB}")"
IFS=$'\t' read -r T_ROWS T_DISTINCT T_UNTRIMMED T_NULL_DATES <<< "$(athena_rows_tsv "${CHECK_ID}")"

[[ "${T_ROWS}" -eq "${ACTUAL_COUNT}" ]] || die "gate failed: ${ACTUAL_COUNT} source entries, ${T_ROWS} trusted rows"
[[ "${T_DISTINCT}" -eq "${T_ROWS}" ]]   || die "gate failed: grain violated, ${T_ROWS} rows / ${T_DISTINCT} distinct cve_id"
[[ "${T_UNTRIMMED}" -eq 0 ]]            || die "gate failed: ${T_UNTRIMMED} rows still carry untrimmed vendor/product"
[[ "${T_NULL_DATES}" -eq 0 ]]           || die "gate failed: ${T_NULL_DATES} rows have no date_added"
ok "trusted: ${T_ROWS} rows / ${T_DISTINCT} distinct cve_id; whitespace fixed on ${UNTRIMMED_SOURCE} source rows"

# --- evidence --------------------------------------------------------------------
mkdir -p "${EVIDENCE_DIR}"
jq -n \
  --arg catalog_version "${CATALOG_VERSION}" \
  --arg catalog_date "${CATALOG_DATE}" \
  --arg ingested_at "${INGESTED_AT}" \
  --argjson source_entries "${ACTUAL_COUNT}" \
  --argjson source_bytes "${SOURCE_BYTES}" \
  --argjson raw_record_bytes "${RECORD_BYTES}" \
  --argjson untrimmed_source_rows "${UNTRIMMED_SOURCE}" \
  --argjson trusted_rows "${T_ROWS}" \
  --argjson trusted_distinct_cve_id "${T_DISTINCT}" \
  --argjson insert "${INSERT_STATS}" \
  '{
     source: "cisa-kev",
     catalog_version: $catalog_version,
     catalog_date: $catalog_date,
     ingested_at_utc: $ingested_at,
     source_entries: $source_entries,
     source_bytes: $source_bytes,
     raw_record_bytes: $raw_record_bytes,
     untrimmed_source_rows: $untrimmed_source_rows,
     trusted_rows: $trusted_rows,
     trusted_distinct_cve_id: $trusted_distinct_cve_id,
     grain: "one row per (cve_id, catalog_date)",
     trusted_insert: $insert
   }' > "${EVIDENCE_DIR}/kev-ingest.json"

jq -c '{
    ingested_at_utc, source, mode: "snapshot", from: .catalog_date, to: .catalog_date, partitions: 1,
    source_rows: .source_entries, trusted_rows, insert_scanned_bytes: .trusted_insert.data_scanned_bytes, inserts: 1
  }' "${EVIDENCE_DIR}/kev-ingest.json" >> "${EVIDENCE_DIR}/load-history.jsonl"

ok "evidence -> ${EVIDENCE_DIR}/kev-ingest.json (+1 line in load-history.jsonl)"
