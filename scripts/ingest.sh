#!/usr/bin/env bash
#
# Ingests the CISA KEV catalog into the lake:
#   raw     <- the source document, byte-for-byte, for auditability
#   trusted <- line-delimited JSON matching the Glue schema, cleaned and typed
#
# Data-quality gates run between the two: the trusted layer is only published if the
# declared grain actually holds. A failed gate exits non-zero and uploads nothing.
#
# Usage: scripts/ingest.sh [--profile NAME] [--source-file PATH] [--keep-local]

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
    -h|--help)     sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd aws jq curl terraform

if [[ -n "${PROFILE}" ]]; then
  export AWS_PROFILE="${PROFILE}"
fi
export AWS_PROFILE_OVERRIDE="${PROFILE}"

LAKE_REGION="$(tf_output aws_region)"
export AWS_REGION_OVERRIDE="${LAKE_REGION}"

RAW_URI="$(tf_output raw_uri)"
TRUSTED_URI="$(tf_output trusted_table_uri)"

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064  # WORK_DIR must expand now, not at trap time
trap "[[ ${KEEP_LOCAL} -eq 1 ]] || rm -rf '${WORK_DIR}'" EXIT

RAW_FILE="${WORK_DIR}/known_exploited_vulnerabilities.json"
TRUSTED_FILE="${WORK_DIR}/kev_vulnerabilities.json"

# --- acquire -------------------------------------------------------------------
if [[ -n "${SOURCE_FILE}" ]]; then
  log "Using local source file: ${SOURCE_FILE}"
  [[ -f "${SOURCE_FILE}" ]] || die "source file not found: ${SOURCE_FILE}"
  cp "${SOURCE_FILE}" "${RAW_FILE}"
else
  log "Downloading CISA KEV catalog"
  curl -fsSL --retry 3 --retry-delay 2 --max-time 120 "${KEV_URL}" -o "${RAW_FILE}" \
    || die "download failed: ${KEV_URL}"
fi

jq -e . "${RAW_FILE}" >/dev/null 2>&1 || die "source payload is not valid JSON"

CATALOG_VERSION="$(jq -r '.catalogVersion // "unknown"' "${RAW_FILE}")"
DECLARED_COUNT="$(jq -r '.count // 0' "${RAW_FILE}")"
ACTUAL_COUNT="$(jq -r '.vulnerabilities | length' "${RAW_FILE}")"
RAW_BYTES="$(wc -c < "${RAW_FILE}" | tr -d ' ')"
INGESTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

ok "catalogVersion ${CATALOG_VERSION}: ${ACTUAL_COUNT} records, ${RAW_BYTES} bytes"

# Gate 1: the feed's own record count must match what it actually shipped.
[[ "${DECLARED_COUNT}" -eq "${ACTUAL_COUNT}" ]] \
  || die "gate failed: feed declares ${DECLARED_COUNT} records but contains ${ACTUAL_COUNT}"

# --- transform -----------------------------------------------------------------
log "Transforming raw -> trusted"
jq -c --arg ingested_at "${INGESTED_AT}" -f "${SCRIPT_DIR}/kev_to_trusted.jq" \
  "${RAW_FILE}" > "${TRUSTED_FILE}" || die "transformation failed"

TRUSTED_ROWS="$(wc -l < "${TRUSTED_FILE}" | tr -d ' ')"
TRUSTED_BYTES="$(wc -c < "${TRUSTED_FILE}" | tr -d ' ')"

# --- data-quality gates --------------------------------------------------------
log "Running data-quality gates"

[[ "${TRUSTED_ROWS}" -eq "${ACTUAL_COUNT}" ]] \
  || die "gate failed: ${ACTUAL_COUNT} source records produced ${TRUSTED_ROWS} trusted rows"
ok "row count preserved: ${TRUSTED_ROWS}"

DISTINCT_CVE="$(jq -s '[.[].cve_id] | unique | length' "${TRUSTED_FILE}")"
[[ "${DISTINCT_CVE}" -eq "${TRUSTED_ROWS}" ]] \
  || die "gate failed: declared grain is one row per CVE, but ${TRUSTED_ROWS} rows hold only ${DISTINCT_CVE} distinct cve_id"
ok "grain holds: ${TRUSTED_ROWS} rows / ${DISTINCT_CVE} distinct cve_id"

EMPTY_KEYS="$(jq -s '[.[] | select(.cve_id == "")] | length' "${TRUSTED_FILE}")"
[[ "${EMPTY_KEYS}" -eq 0 ]] || die "gate failed: ${EMPTY_KEYS} rows have an empty cve_id"
ok "no empty natural keys"

DIRTY="$(jq -s '[.[] | select((.vendor_project | test("^\\s|\\s$")) or (.product | test("^\\s|\\s$")))] | length' "${TRUSTED_FILE}")"
[[ "${DIRTY}" -eq 0 ]] || die "gate failed: ${DIRTY} rows still carry untrimmed vendor/product values"
ok "vendor/product whitespace normalized"

BAD_DATES="$(jq -s '[.[] | select((.date_added | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not))] | length' "${TRUSTED_FILE}")"
[[ "${BAD_DATES}" -eq 0 ]] || die "gate failed: ${BAD_DATES} rows have a non ISO-8601 date_added"
ok "date_added is ISO-8601 on every row"

# --- publish -------------------------------------------------------------------
log "Uploading raw layer"
aws_cli s3 cp "${RAW_FILE}" "${RAW_URI}known_exploited_vulnerabilities.json" --only-show-errors

log "Uploading trusted layer"
aws_cli s3 cp "${TRUSTED_FILE}" "${TRUSTED_URI}kev_vulnerabilities.json" --only-show-errors

# --- evidence ------------------------------------------------------------------
mkdir -p "${EVIDENCE_DIR}"
METRICS_FILE="${EVIDENCE_DIR}/ingest-metrics.json"
jq -n \
  --arg catalog_version "${CATALOG_VERSION}" \
  --arg ingested_at "${INGESTED_AT}" \
  --arg raw_uri "${RAW_URI}" \
  --arg trusted_uri "${TRUSTED_URI}" \
  --argjson source_records "${ACTUAL_COUNT}" \
  --argjson trusted_rows "${TRUSTED_ROWS}" \
  --argjson distinct_cve_id "${DISTINCT_CVE}" \
  --argjson raw_bytes "${RAW_BYTES}" \
  --argjson trusted_bytes "${TRUSTED_BYTES}" \
  '{
     catalog_version: $catalog_version,
     ingested_at: $ingested_at,
     raw_uri: $raw_uri,
     trusted_uri: $trusted_uri,
     source_records: $source_records,
     trusted_rows: $trusted_rows,
     distinct_cve_id: $distinct_cve_id,
     raw_bytes: $raw_bytes,
     trusted_bytes: $trusted_bytes,
     grain: "one row per cve_id"
   }' > "${METRICS_FILE}"

echo
ok "raw     -> ${RAW_URI}known_exploited_vulnerabilities.json  (${RAW_BYTES} bytes)"
ok "trusted -> ${TRUSTED_URI}kev_vulnerabilities.json  (${TRUSTED_BYTES} bytes, ${TRUSTED_ROWS} rows)"
ok "metrics -> ${METRICS_FILE}"

cat <<NEXT

Next:
  scripts/run_query.sh ${PROFILE:+--profile ${PROFILE}}
NEXT
