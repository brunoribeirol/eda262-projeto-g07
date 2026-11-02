#!/usr/bin/env bash
#
# End-to-end Part 2 run: provisions the lake, loads it (backfill on the first run,
# incremental afterwards), answers the business question with its measured cost, proves
# idempotency and the Lake Formation access matrix, and runs the acceptance script.
# Produces every piece of evidence the rubric asks for, in docs/evidence/part-2/.
#
# ONE run, ONE set of evidence: the per-run evidence files of any earlier run are removed
# first, every file this run writes carries its run_id, and run-manifest.json records the
# run (id, git commit, window, verifica result). verifica.sh fails if the evidence mixes
# runs, or if DECISOES.md and the decks cite numbers from another run.
#
# It creates real AWS resources and asks for confirmation first. One full cycle costs
# cents: a few dozen Athena statements (most at the 10 MB billing minimum) plus storage.
#
# Usage: scripts/part-2/run_all.sh [--profile NAME] [--region REGION] [--days 30] [--to yyyy-MM-dd]
#                                  [--yes] [--destroy-after]
#   --to   last EPSS day of the backfill. Pin it for a reference run, so the window is a
#          declared fact of the run instead of whatever "the last 30 days" meant that day.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"
DAYS=30
TO=""
ASSUME_YES=0
DESTROY_AFTER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)        REGION="${2:?--region needs a value}"; shift 2 ;;
    --days)          DAYS="${2:?--days needs a value}"; shift 2 ;;
    --to)            TO="${2:?--to needs a value}"; shift 2 ;;
    --yes)           ASSUME_YES=1; shift ;;
    --destroy-after) DESTROY_AFTER=1; shift ;;
    -h|--help)       sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws jq curl gzip awk git
[[ -z "${TO}" ]] || require_date "${TO}"

PROFILE_ARGS=()
[[ -z "${PROFILE}" ]] || PROFILE_ARGS=(--profile "${PROFILE}")
TO_ARGS=()
[[ -z "${TO}" ]] || TO_ARGS=(--to "${TO}")

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

# --- run identity ----------------------------------------------------------------------
# lib.sh minted RUN_ID and exported it, so every script below stamps the same id.
log "Run ${RUN_ID}: clearing the previous run's evidence (load-history.jsonl is kept)"
mkdir -p "${EVIDENCE_DIR}"
for f in ${PER_RUN_EVIDENCE}; do rm -f "${EVIDENCE_DIR}/${f}"; done

GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=false
[[ -z "$(git -C "${REPO_ROOT}" status --porcelain -- parte-2 scripts verificacao 2>/dev/null)" ]] || GIT_DIRTY=true
[[ "${GIT_DIRTY}" == "false" ]] || warn "uncommitted changes in parte-2/, scripts/ or verificacao/: the manifest will say so"

jq -n --arg run_id "${RUN_ID}" --arg started "$(now_utc_iso)" --arg commit "${GIT_COMMIT}" \
  --argjson dirty "${GIT_DIRTY}" --arg region "${REGION}" --argjson days "${DAYS}" --arg to "${TO}" \
  '{
     run_id: $run_id,
     status: "running",
     started_at_utc: $started,
     git: {commit: $commit, uncommitted_changes: $dirty},
     region: $region,
     requested: {backfill_days: $days, backfill_to: (if $to == "" then "latest published day" else $to end)}
   }' > "${RUN_MANIFEST}"

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
  "${PART2_DIR}/run_pipeline.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --days "${DAYS}" ${TO_ARGS[@]+"${TO_ARGS[@]}"}
else
  "${PART2_DIR}/run_pipeline.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --incremental ${TO_ARGS[@]+"${TO_ARGS[@]}"}
fi

announce "Business question and measured cost"
"${PART2_DIR}/run_query.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}

announce "Idempotency proof"
"${PART2_DIR}/check_idempotency.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}

announce "Lake Formation access matrix"
"${PART2_DIR}/check_access.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}

# At this point DECISOES.md and the decks still cite the previous run, so the "single run,
# cited" criterion fails by construction. Once they cite this one, verify_run.sh re-runs the
# acceptance and replaces this result.
announce "Acceptance script"
verify_status=0
run_acceptance --region "${REGION}" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} || verify_status=$?

manifest_update \
  --arg finished "$(now_utc_iso)" --slurpfile cost "${EVIDENCE_DIR}/query-cost.json" \
  '. + {
     status: "completed",
     finished_at_utc: $finished,
     window: $cost[0].window,
     kev_catalog_date: $cost[0].kev_catalog_date
   }'

if [[ "${DESTROY_AFTER}" -eq 1 ]]; then
  announce "Tearing down"
  "${PART2_DIR}/destroy.sh" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --region "${REGION}"
fi

echo
log "Run ${RUN_ID} -- manifest: ${RUN_MANIFEST}"
log "Cite this run in DECISOES.md and the decks: scripts/part-2/check_evidence_sync.sh lists what is missing"
[[ "${DESTROY_AFTER}" -eq 1 ]] \
  || log "Then, with the lake still up: scripts/part-2/verify_run.sh ${PROFILE:+--profile ${PROFILE}} (final acceptance)"
if [[ "${verify_status}" -eq 0 ]]; then
  ok "All criteria passed. Evidence is in ${EVIDENCE_DIR}/"
else
  warn "Some criteria failed -- see the PASSA/FALHA list above."
fi
exit "${verify_status}"
