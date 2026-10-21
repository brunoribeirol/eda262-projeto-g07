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
    -h|--help)   sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

log "Applying"
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve "${TF_VARS[@]}"

echo
ok "Workspace          : $(tf_output workspace)"
ok "Buckets            : $(tf_output raw_bucket), $(tf_output trusted_bucket), $(tf_output refined_bucket)"
ok "Glue databases     : $(tf_output raw_db), $(tf_output trusted_db), $(tf_output refined_db)"
ok "Pipeline WorkGroup : $(tf_output pipeline_workgroup)"
ok "Lake Formation admin (pipeline): $(tf_output lakeformation_admin)"
tf_output_json personas | jq -r 'to_entries[] | "  OK persona \(.key): \(.value.workgroup) reads \(.value.layers | join(", "))"'

if [[ "$(tf_output is_delivery_workspace)" != "true" ]]; then
  warn "Workspace '${WORKSPACE}' is not the delivery workspace: resource names carry a suffix."
  warn "Deliver from workspace 'av2' so names match the course guide verbatim."
fi

cat <<NEXT

Next:
  scripts/part-2/run_pipeline.sh ${PROFILE:+--profile ${PROFILE} }--days 30   # first load (backfill)
  scripts/part-2/run_query.sh ${PROFILE:+--profile ${PROFILE}}
NEXT
