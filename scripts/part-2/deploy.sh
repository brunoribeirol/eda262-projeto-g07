#!/usr/bin/env bash
#
# Provisions the Part 2 lake: raw/trusted/refined buckets and Glue databases, Parquet
# tables, the pipeline + persona Athena WorkGroups, and the Lake Formation governance.
#
# Before the FIRST apply it saves the account's current Lake Formation settings to
# parte-2/.lakeformation-settings.before.json (gitignored). Terraform replaces those
# account-wide settings; destroy.sh puts the saved copy back, so the account is left
# exactly as it was found.
#
# Evidence: docs/evidence/part-2/apply-check.json -- what this apply created, changed and
# destroyed, as Terraform itself reports it, and whether a plan right after it is empty (no
# perpetual diff). On a reference run (lake destroyed first) it is the "apply from scratch"
# the demo slide shows.
#
# Usage: scripts/part-2/deploy.sh [--profile NAME] [--region REGION] [--workspace NAME] [--plan-only]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"
WORKSPACE="av2"
PLAN_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)   PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)    REGION="${2:?--region needs a value}"; shift 2 ;;
    --workspace) WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
    --plan-only) PLAN_ONLY=1; shift ;;
    -h|--help)   sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws jq
[[ -f "${TF_DIR}/backend.hcl" ]] || die "parte-2/backend.hcl not found. Run scripts/part-2/bootstrap.sh first."

export AWS_PROFILE_OVERRIDE="${PROFILE}"
export AWS_REGION_OVERRIDE="${REGION}"
[[ -z "${PROFILE}" ]] || export AWS_PROFILE="${PROFILE}"

log "Initializing parte-2 against the remote backend"
terraform -chdir="${TF_DIR}" init -input=false -backend-config=backend.hcl

log "Selecting workspace '${WORKSPACE}'"
terraform -chdir="${TF_DIR}" workspace select -or-create "${WORKSPACE}" 2>/dev/null \
  || terraform -chdir="${TF_DIR}" workspace new "${WORKSPACE}"

TF_VARS=(-var "aws_region=${REGION}")
[[ -z "${PROFILE}" ]] || TF_VARS+=(-var "aws_profile=${PROFILE}")

if [[ "${PLAN_ONLY}" -eq 1 ]]; then
  log "Planning only (no changes applied)"
  terraform -chdir="${TF_DIR}" plan -input=false "${TF_VARS[@]}"
  exit 0
fi

SETTINGS_BACKUP="${TF_DIR}/.lakeformation-settings.before.json"
if [[ ! -f "${SETTINGS_BACKUP}" ]] \
   && ! terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -q 'aws_lakeformation_data_lake_settings'; then
  log "Saving the account's Lake Formation settings before Terraform replaces them"
  aws_cli lakeformation get-data-lake-settings --output json > "${SETTINGS_BACKUP}" \
    || die "could not read the Lake Formation settings (lakeformation:GetDataLakeSettings)"
  ok "saved -> ${SETTINGS_BACKUP}"
fi

# Managed resources already in the state: 0 means this apply starts from scratch. A re-run
# after a partial apply would also report "N added, 0 changed, 0 destroyed", so the counts
# alone cannot tell.
STATE_BEFORE="$(terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -cvE '(^|[.])data[.]' || true)"
STATE_BEFORE="${STATE_BEFORE:-0}"

log "Applying"
APPLY_LOG="$(mktemp)"
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve "${TF_VARS[@]}" | tee "${APPLY_LOG}"
# "Apply complete! Resources: 74 added, 0 changed, 0 destroyed." -- Terraform's own count.
APPLY_COUNTS="$(sed -n 's/.*Apply complete! Resources: \([0-9][0-9]*\) added, \([0-9][0-9]*\) changed, \([0-9][0-9]*\) destroyed.*/\1 \2 \3/p' "${APPLY_LOG}" | tail -n 1)"
rm -f "${APPLY_LOG}"
[[ -n "${APPLY_COUNTS}" ]] || die "terraform apply did not report 'Apply complete!'"
read -r ADDED CHANGED DESTROYED <<< "${APPLY_COUNTS}"

# Plan again right after the apply: exit code 0 means the code and the account agree, 2 means
# some resource would change on every apply (a perpetual diff, i.e. drift by design). Recorded,
# not fatal, so the run still produces its evidence; verifica.sh turns it into a criterion.
log "Planning again: an apply must leave nothing to change"
PLAN_LOG="$(mktemp)"
PLAN_EXIT=0
terraform -chdir="${TF_DIR}" plan -input=false -detailed-exitcode "${TF_VARS[@]}" > "${PLAN_LOG}" 2>&1 \
  || PLAN_EXIT=$?
PLAN_SUMMARY="$(grep -E '^(Plan:|No changes\.)' "${PLAN_LOG}" | tail -n 1 || true)"
case "${PLAN_EXIT}" in
  0) ok "Plan after apply   : ${PLAN_SUMMARY:-No changes.}" ;;
  2) warn "Plan after apply   : ${PLAN_SUMMARY} -- these resources drift on every apply:"
     grep -E '^  # .* (will|must) be' "${PLAN_LOG}" >&2 || true ;;
  *) cat "${PLAN_LOG}" >&2; rm -f "${PLAN_LOG}"; die "terraform plan failed right after the apply" ;;
esac
rm -f "${PLAN_LOG}"

mkdir -p "${EVIDENCE_DIR}"
jq -n --arg run_id "${RUN_ID}" --arg applied_at "$(now_utc_iso)" --arg region "${REGION}" \
  --arg workspace "${WORKSPACE}" --argjson added "${ADDED}" --argjson changed "${CHANGED}" \
  --argjson destroyed "${DESTROYED}" --argjson before "${STATE_BEFORE}" \
  --argjson plan_exit "${PLAN_EXIT}" --arg plan_summary "${PLAN_SUMMARY}" \
  '{
     run_id: $run_id,
     applied_at_utc: $applied_at,
     region: $region,
     workspace: $workspace,
     resources_added: $added,
     resources_changed: $changed,
     resources_destroyed: $destroyed,
     resources_in_state_before: $before,
     from_scratch: ($before == 0 and $added > 0),
     plan_after_apply_clean: ($plan_exit == 0),
     plan_after_apply: $plan_summary
   }' > "${EVIDENCE_DIR}/apply-check.json"

echo
ok "Workspace          : $(tf_output workspace)"
ok "Buckets            : $(tf_output raw_bucket), $(tf_output trusted_bucket), $(tf_output refined_bucket)"
ok "Glue databases     : $(tf_output raw_db), $(tf_output trusted_db), $(tf_output refined_db)"
ok "Pipeline WorkGroup : $(tf_output pipeline_workgroup)"
ok "Lake Formation admin (pipeline): $(tf_output lakeformation_admin)"
tf_output_json personas | jq -r 'to_entries[] | "  OK persona \(.key): \(.value.workgroup) reads \(.value.layers | join(", "))"'
ok "Evidence           : ${EVIDENCE_DIR}/apply-check.json (${ADDED} added, ${CHANGED} changed, ${DESTROYED} destroyed)"

if [[ "$(tf_output is_delivery_workspace)" != "true" ]]; then
  warn "Workspace '${WORKSPACE}' is not the delivery workspace: resource names carry a suffix."
  warn "Deliver from workspace 'av2' so names match the course guide verbatim."
fi

cat <<NEXT

Next:
  scripts/part-2/run_pipeline.sh ${PROFILE:+--profile ${PROFILE} }--days 30   # first load (backfill)
  scripts/part-2/run_query.sh ${PROFILE:+--profile ${PROFILE}}
NEXT
