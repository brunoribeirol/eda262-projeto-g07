#!/usr/bin/env bash
#
# Creates the Terraform remote backend (S3 state bucket + DynamoDB lock table) and
# writes parte-1/backend.hcl from its outputs.
#
# Run once per AWS account, before deploy.sh. Safe to re-run: Terraform reconciles.
#
# Usage: scripts/bootstrap.sh [--profile NAME] [--region REGION]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)  REGION="${2:?--region needs a value}";   shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws

export AWS_PROFILE_OVERRIDE="${PROFILE}"
export AWS_REGION_OVERRIDE="${REGION}"
if [[ -n "${PROFILE}" ]]; then
  export AWS_PROFILE="${PROFILE}"
fi

log "Verifying AWS credentials"
ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)" \
  || die "could not authenticate to AWS. Configure credentials (aws configure --profile ${PROFILE:-default})."
ok "Authenticated to AWS account ${ACCOUNT_ID} in ${REGION}"

BOOTSTRAP_DIR="${TF_DIR}/bootstrap"

log "Initializing the bootstrap stack (local state)"
terraform -chdir="${BOOTSTRAP_DIR}" init -input=false

log "Applying the bootstrap stack"
terraform -chdir="${BOOTSTRAP_DIR}" apply -input=false -auto-approve \
  -var "aws_region=${REGION}"

BACKEND_FILE="${TF_DIR}/backend.hcl"
terraform -chdir="${BOOTSTRAP_DIR}" output -raw backend_hcl > "${BACKEND_FILE}"

ok "State bucket : $(terraform -chdir="${BOOTSTRAP_DIR}" output -raw state_bucket)"
ok "Lock table   : $(terraform -chdir="${BOOTSTRAP_DIR}" output -raw lock_table)"
ok "Backend file : ${BACKEND_FILE} (gitignored -- it embeds the account ID)"

cat <<NEXT

Next:
  scripts/deploy.sh ${PROFILE:+--profile ${PROFILE}} --region ${REGION}
NEXT
