#!/usr/bin/env bash
#
# Tears down the Part 1 lake, then optionally the backend itself.
# The rubric grades "destroy leaves no orphaned resources", so this script also
# verifies the teardown instead of trusting Terraform's exit code alone.
#
# Usage: scripts/destroy.sh [--profile NAME] [--region REGION] [--workspace NAME] [--include-backend]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"
WORKSPACE="av1"
INCLUDE_BACKEND=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)         PROFILE="${2:?--profile needs a value}";     shift 2 ;;
    --region)          REGION="${2:?--region needs a value}";       shift 2 ;;
    --workspace)       WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
    --include-backend) INCLUDE_BACKEND=1; shift ;;
    -h|--help)         sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws

if [[ -n "${PROFILE}" ]]; then
  export AWS_PROFILE="${PROFILE}"
fi
export AWS_PROFILE_OVERRIDE="${PROFILE}"
export AWS_REGION_OVERRIDE="${REGION}"

terraform -chdir="${TF_DIR}" workspace select "${WORKSPACE}" \
  || die "workspace '${WORKSPACE}' does not exist"

# Capture names before the state is gone, so the post-destroy check has something
# concrete to look for.
RAW_BUCKET="$(tf_output raw_bucket)"
TRUSTED_BUCKET="$(tf_output trusted_bucket)"
RESULTS_BUCKET="$(tf_output athena_results_bucket)"
GLUE_DB="$(tf_output glue_database)"
WORKGROUP="$(tf_output athena_workgroup)"

log "Destroying the parte-1 stack (workspace ${WORKSPACE})"
TF_VARS=(-var "aws_region=${REGION}")
if [[ -n "${PROFILE}" ]]; then
  TF_VARS+=(-var "aws_profile=${PROFILE}")
fi
terraform -chdir="${TF_DIR}" destroy -input=false -auto-approve "${TF_VARS[@]}"

log "Verifying no resources were orphaned"
ORPHANS=0
for bucket in "${RAW_BUCKET}" "${TRUSTED_BUCKET}" "${RESULTS_BUCKET}"; do
  if aws_cli s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    warn "bucket still exists: ${bucket}"; ORPHANS=1
  fi
done
if aws_cli glue get-database --name "${GLUE_DB}" >/dev/null 2>&1; then
  warn "Glue database still exists: ${GLUE_DB}"; ORPHANS=1
fi
if aws_cli athena get-work-group --work-group "${WORKGROUP}" >/dev/null 2>&1; then
  warn "Athena WorkGroup still exists: ${WORKGROUP}"; ORPHANS=1
fi

[[ "${ORPHANS}" -eq 0 ]] || die "teardown left orphaned resources -- investigate before submitting"
ok "No orphaned resources remain"

if [[ "${INCLUDE_BACKEND}" -eq 1 ]]; then
  warn "Destroying the backend deletes the Terraform state itself. This is irreversible."
  read -r -p "Type 'destroy-backend' to confirm: " confirm
  [[ "${confirm}" == "destroy-backend" ]] || die "aborted"
  terraform -chdir="${TF_DIR}/bootstrap" destroy -input=false -auto-approve -var "aws_region=${REGION}"
  ok "Backend destroyed"
fi
