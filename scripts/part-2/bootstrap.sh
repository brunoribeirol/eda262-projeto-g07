#!/usr/bin/env bash
#
# Creates the Terraform remote backend (S3 state bucket + DynamoDB lock table) and writes
# parte-2/backend.hcl. Run once per AWS account, before deploy.sh.
#
# Part 1 and Part 2 use the same backend names (one per account; the state KEY differs).
# If the backend already exists -- e.g. created by parte-1/bootstrap -- it is reused
# instead of failing on "bucket already exists".
#
# Usage: scripts/part-2/bootstrap.sh [--profile NAME] [--region REGION]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"
NAME_PREFIX="eda262-g07"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)  REGION="${2:?--region needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws

# No Terraform outputs exist yet, so the region comes from the command line.
export AWS_PROFILE_OVERRIDE="${PROFILE}"
export AWS_REGION_OVERRIDE="${REGION}"
[[ -z "${PROFILE}" ]] || export AWS_PROFILE="${PROFILE}"

log "Verifying AWS credentials"
ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)" \
  || die "could not authenticate to AWS. Configure credentials (aws configure${PROFILE:+ --profile ${PROFILE}})."
ok "Authenticated to AWS account ${ACCOUNT_ID} in ${REGION}"

BOOTSTRAP_DIR="${TF_DIR}/bootstrap"
BACKEND_FILE="${TF_DIR}/backend.hcl"
STATE_BUCKET="${NAME_PREFIX}-tfstate-${ACCOUNT_ID}"
LOCK_TABLE="${NAME_PREFIX}-tflock"

if [[ ! -f "${BOOTSTRAP_DIR}/terraform.tfstate" ]] \
   && aws_cli s3api head-bucket --bucket "${STATE_BUCKET}" >/dev/null 2>&1; then
  aws_cli dynamodb describe-table --table-name "${LOCK_TABLE}" >/dev/null 2>&1 \
    || die "state bucket ${STATE_BUCKET} exists but lock table ${LOCK_TABLE} does not -- fix the backend by hand"
  warn "backend already exists in this account (created outside parte-2/bootstrap) -- reusing it"
  cat > "${BACKEND_FILE}" <<HCL
bucket         = "${STATE_BUCKET}"
key            = "eda262-g07/parte-2/terraform.tfstate"
region         = "${REGION}"
dynamodb_table = "${LOCK_TABLE}"
encrypt        = true
HCL
else
  log "Initializing the bootstrap stack (local state)"
  terraform -chdir="${BOOTSTRAP_DIR}" init -input=false
  log "Applying the bootstrap stack"
  terraform -chdir="${BOOTSTRAP_DIR}" apply -input=false -auto-approve -var "aws_region=${REGION}"
  terraform -chdir="${BOOTSTRAP_DIR}" output -raw backend_hcl > "${BACKEND_FILE}"
fi

ok "State bucket : ${STATE_BUCKET}"
ok "Lock table   : ${LOCK_TABLE}"
ok "Backend file : ${BACKEND_FILE} (gitignored -- it embeds the account ID)"

cat <<NEXT

Next:
  scripts/part-2/deploy.sh ${PROFILE:+--profile ${PROFILE} }--region ${REGION}
NEXT
