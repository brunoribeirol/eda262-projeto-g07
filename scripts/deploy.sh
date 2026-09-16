#!/usr/bin/env bash
#
# Provisions the Part 1 data lake: S3 layers + Glue Data Catalog + Athena WorkGroup.
# Selects (creating if needed) the Terraform workspace, then applies.
#
# Usage: scripts/deploy.sh [--profile NAME] [--region REGION] [--workspace NAME] [--plan-only]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"
WORKSPACE="av1"
PLAN_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)   PROFILE="${2:?--profile needs a value}";   shift 2 ;;
    --region)    REGION="${2:?--region needs a value}";     shift 2 ;;
    --workspace) WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
    --plan-only) PLAN_ONLY=1; shift ;;
    -h|--help)   sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws

[[ -f "${TF_DIR}/backend.hcl" ]] \
  || die "parte-1/backend.hcl not found. Run scripts/bootstrap.sh first."

if [[ -n "${PROFILE}" ]]; then
  export AWS_PROFILE="${PROFILE}"
fi

log "Initializing parte-1 against the remote backend"
terraform -chdir="${TF_DIR}" init -input=false -backend-config=backend.hcl

# `workspace select -or-create` needs Terraform >= 1.4; fall back for older CLIs.
log "Selecting workspace '${WORKSPACE}'"
terraform -chdir="${TF_DIR}" workspace select -or-create "${WORKSPACE}" 2>/dev/null \
  || terraform -chdir="${TF_DIR}" workspace new "${WORKSPACE}"

TF_VARS=(-var "aws_region=${REGION}")
if [[ -n "${PROFILE}" ]]; then
  TF_VARS+=(-var "aws_profile=${PROFILE}")
fi

if [[ "${PLAN_ONLY}" -eq 1 ]]; then
  log "Planning only (no changes applied)"
  terraform -chdir="${TF_DIR}" plan -input=false "${TF_VARS[@]}"
  exit 0
fi

log "Applying"
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve "${TF_VARS[@]}"

echo
ok "Workspace       : $(tf_output workspace)"
ok "Raw bucket      : $(tf_output raw_bucket)"
ok "Trusted bucket  : $(tf_output trusted_bucket)"
ok "Glue database   : $(tf_output glue_database)"
ok "Trusted table   : $(tf_output trusted_table)  [grain: $(tf_output trusted_table_grain)]"
ok "Athena WorkGroup: $(tf_output athena_workgroup)"

if [[ "$(tf_output is_delivery_workspace)" != "true" ]]; then
  warn "Workspace '${WORKSPACE}' is not the delivery workspace: resource names carry a suffix."
  warn "Deliver from workspace 'av1' so names match the course guide verbatim."
fi

cat <<NEXT

Next:
  scripts/ingest.sh ${PROFILE:+--profile ${PROFILE}}
  scripts/run_query.sh ${PROFILE:+--profile ${PROFILE}}
NEXT
