#!/usr/bin/env bash
#
# Reproduces, offline, the source-side numbers quoted in DECISOES.md (Part 2): EPSS volume
# and quality, Parquet size per codec and per column, KEV vs EPSS distribution, and the size
# of the refined aggregate. Needs no AWS account -- only curl, gzip and the DuckDB CLI.
#
# Optional tooling: nothing in the pipeline depends on this script or on DuckDB.
#
# Usage: scripts/part-2/profile_sources.sh [--days 30] [--to yyyy-MM-dd] [--cache-dir DIR]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EPSS_URL="https://epss.empiricalsecurity.com"
KEV_URL="https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
DAYS=30
TO=""
CACHE_DIR="${TMPDIR:-/tmp}/eda262-g07-sources"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)      DAYS="${2:?}"; shift 2 ;;
    --to)        TO="${2:?}"; shift 2 ;;
    --cache-dir) CACHE_DIR="${2:?}"; shift 2 ;;
    -h|--help)   sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for cmd in curl gzip duckdb; do
  command -v "${cmd}" >/dev/null || { echo "missing required command: ${cmd}" >&2; exit 1; }
done

if date --version >/dev/null 2>&1; then
  shift_day() { date -u -d "$1 $2 day" '+%Y-%m-%d'; }
else
  shift_day() { local n="$2"; [[ "${n}" == -* ]] || n="+${n}"; date -u -j -v"${n}"d -f '%Y-%m-%d' "$1" '+%Y-%m-%d'; }
fi

if [[ -z "${TO}" ]]; then
  TO="$(date -u '+%Y-%m-%d')"
  curl -fsIL --max-time 30 "${EPSS_URL}/epss_scores-${TO}.csv.gz" >/dev/null 2>&1 || TO="$(shift_day "${TO}" -1)"
fi

mkdir -p "${CACHE_DIR}/epss" "${CACHE_DIR}/out"
echo "==> EPSS: ${DAYS} day(s) ending ${TO} (cache: ${CACHE_DIR})"
FIRST="$(shift_day "${TO}" "-$(( DAYS - 1 ))")"
WINDOW_BYTES=0
d="${FIRST}"
while [[ ! "${d}" > "${TO}" ]]; do
  f="${CACHE_DIR}/epss/epss_scores-${d}.csv.gz"
  [[ -s "${f}" ]] || curl -fsSL --retry 3 --max-time 120 -o "${f}" "${EPSS_URL}/epss_scores-${d}.csv.gz"
  WINDOW_BYTES=$(( WINDOW_BYTES + $(wc -c < "${f}") ))
  d="$(shift_day "${d}" 1)"
done
echo "==> gzip bytes for the window: ${WINDOW_BYTES}"

echo "==> KEV catalog"
curl -fsSL --retry 3 --max-time 120 -o "${CACHE_DIR}/known_exploited_vulnerabilities.json" "${KEV_URL}"

sed -e "s#\${epss_glob}#${CACHE_DIR}/epss/epss_scores-*.csv.gz#g" \
    -e "s#\${kev_file}#${CACHE_DIR}/known_exploited_vulnerabilities.json#g" \
    -e "s#\${out_dir}#${CACHE_DIR}/out#g" \
    -e "s#\${first_day}#${FIRST}#g" \
    -e "s#\${latest_day}#${TO}#g" \
    "${HERE}/profile_sources.sql" | duckdb -box
