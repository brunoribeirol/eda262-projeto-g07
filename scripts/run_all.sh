#!/usr/bin/env bash
#
# End-to-end run: provisions the lake, ingests, measures the query cost, renders the
# decks and verifies the result. This is what produces every piece of evidence the
# rubric asks for.
#
# It creates real AWS resources. The total cost of one full cycle is a few cents of
# S3/DynamoDB storage plus USD 0.00004768 per Athena query, but it asks for
# confirmation before the first apply anyway.
#
# Usage: scripts/run_all.sh [--profile NAME] [--region REGION] [--yes] [--destroy-after]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"
ASSUME_YES=0
DESTROY_AFTER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)        REGION="${2:?--region needs a value}"; shift 2 ;;
    --yes)           ASSUME_YES=1; shift ;;
    --destroy-after) DESTROY_AFTER=1; shift ;;
    -h|--help)       sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws jq curl

PROFILE_ARGS=()
if [[ -n "${PROFILE}" ]]; then
  PROFILE_ARGS=(--profile "${PROFILE}")
fi

if [[ "${ASSUME_YES}" -eq 0 ]]; then
  cat <<PROMPT
This will create real AWS resources in region ${REGION}${PROFILE:+ using profile ${PROFILE}}:
  - 3 S3 buckets, 1 Glue database + table, 1 Athena WorkGroup
  - 1 S3 state bucket + 1 DynamoDB lock table (first run only)

PROMPT
  read -r -p "Proceed? [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]] || die "aborted"
fi

step=0
announce() { step=$(( step + 1 )); printf '\n%s[%d/%d]%s %s\n' "${C_BOLD}" "${step}" "6" "${C_RESET}" "$1"; }

# 1 -- backend. Skipped when backend.hcl already exists, so re-runs stay cheap.
announce "Remote backend"
if [[ -f "${TF_DIR}/backend.hcl" ]]; then
  ok "backend.hcl already present, skipping bootstrap"
else
  "${SCRIPT_DIR}/bootstrap.sh" "${PROFILE_ARGS[@]}" --region "${REGION}"
fi

announce "Provisioning the data lake"
"${SCRIPT_DIR}/deploy.sh" "${PROFILE_ARGS[@]}" --region "${REGION}"

announce "Ingesting the CISA KEV catalog"
"${SCRIPT_DIR}/ingest.sh" "${PROFILE_ARGS[@]}"

announce "Running the business question and measuring cost"
"${SCRIPT_DIR}/run_query.sh" "${PROFILE_ARGS[@]}"

announce "Rendering the slide decks to PDF"
"${SCRIPT_DIR}/build_pdf.sh" || warn "PDF rendering failed -- print the decks manually, see docs/presentation/README.md"

announce "Verifying every rubric criterion"
set +e
"${REPO_ROOT}/verificacao/verifica.sh" "${PROFILE_ARGS[@]}"
verify_status=$?
set -e

echo
if [[ "${verify_status}" -eq 0 ]]; then
  ok "All criteria passed. Evidence is in docs/evidence/."
else
  warn "Some criteria failed -- see the PASSA/FALHA list above."
fi

if [[ "${DESTROY_AFTER}" -eq 1 ]]; then
  announce "Tearing down"
  "${SCRIPT_DIR}/destroy.sh" "${PROFILE_ARGS[@]}" --region "${REGION}"
fi

cat <<NEXT

Evidence produced:
  docs/evidence/ingest-metrics.json
  docs/evidence/business-question-result.csv
  docs/evidence/query-cost.json
  docs/evidence/grain-check-result.csv
  apresentacao-parte-1-g07.pdf

NEXT

exit "${verify_status}"
