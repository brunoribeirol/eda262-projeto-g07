#!/usr/bin/env bash
#
# End-to-end Part 2 run: provisions the lake, loads it (backfill on the first run,
# incremental afterwards), answers the business question with its measured cost, proves
# idempotency and the Lake Formation access matrix, and runs the acceptance script.
# Produces every piece of evidence the rubric asks for, in docs/evidence/part-2/.
#
# It creates real AWS resources and asks for confirmation first. One full cycle costs
# cents: a few dozen Athena statements (most at the 10 MB billing minimum) plus storage.
#
# Usage: scripts/part-2/run_all.sh [--profile NAME] [--region REGION] [--days 30] [--yes] [--destroy-after]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"
DAYS=30
ASSUME_YES=0
DESTROY_AFTER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)        REGION="${2:?--region needs a value}"; shift 2 ;;
    --days)          DAYS="${2:?--days needs a value}"; shift 2 ;;
    --yes)           ASSUME_YES=1; shift ;;
    --destroy-after) DESTROY_AFTER=1; shift ;;
    -h|--help)       sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws jq curl gzip awk

PROFILE_ARGS=()
[[ -z "${PROFILE}" ]] || PROFILE_ARGS=(--profile "${PROFILE}")

if [[ "${ASSUME_YES}" -eq 0 ]]; then
  cat <<PROMPT
This will create real AWS resources in region ${REGION}${PROFILE:+ using profile ${PROFILE}}:
  - 4 S3 buckets, 3 Glue databases + 5 tables, 4 Athena WorkGroups
  - 4 IAM roles and the Lake Formation settings, registrations and grants
  - 1 S3 state bucket + 1 DynamoDB lock table (first run only)
It also replaces the account's Lake Formation settings (saved first, restored on destroy).

PROMPT
  # Without a terminal (CI, a `!` shell in an editor) `read` hits end-of-input and the
  # script would stop silently -- say why instead.
  [[ -t 0 ]] || die "no interactive terminal to confirm in: re-run with --yes to proceed"
  read -r -p "Proceed? [y/N] " reply || die "no answer read: re-run with --yes to proceed"
  [[ "${reply}" =~ ^[Yy]$ ]] || die "aborted"
fi

TOTAL_STEPS=7
[[ "${DESTROY_AFTER}" -eq 0 ]] || TOTAL_STEPS=8
step=0
announce() { step=$(( step + 1 )); printf '\n%s[%d/%d]%s %s\n' "${C_BOLD}" "${step}" "${TOTAL_STEPS}" "${C_RESET}" "$1"; }

announce "Remote backend"
if [[ -f "${TF_DIR}/backend.hcl" ]]; then
  ok "backend.hcl already present, skipping bootstrap"
else
  "${PART2_DIR}/bootstrap.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --region "${REGION}"
fi

announce "Provisioning the lake"
"${PART2_DIR}/deploy.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --region "${REGION}"

announce "Loading the lake"
use_profile "${PROFILE}"
if [[ -z "$(glue_partition_values "$(tf_output trusted_db)" epss_scores)" ]]; then
  "${PART2_DIR}/run_pipeline.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --days "${DAYS}"
else
  "${PART2_DIR}/run_pipeline.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --incremental
fi

announce "Business question and measured cost"
"${PART2_DIR}/run_query.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}

announce "Idempotency proof"
"${PART2_DIR}/check_idempotency.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}

announce "Lake Formation access matrix"
"${PART2_DIR}/check_access.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}

announce "Acceptance script"
set +e
"${REPO_ROOT}/verificacao/verifica.sh" --parte 2 ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} | tee "${EVIDENCE_DIR}/verifica-output.txt"
verify_status=${PIPESTATUS[0]}
set -e

if [[ "${DESTROY_AFTER}" -eq 1 ]]; then
  announce "Tearing down"
  "${PART2_DIR}/destroy.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --region "${REGION}"
fi

echo
if [[ "${verify_status}" -eq 0 ]]; then
  ok "All criteria passed. Evidence is in ${EVIDENCE_DIR}/"
else
  warn "Some criteria failed -- see the PASSA/FALHA list above."
fi
exit "${verify_status}"
