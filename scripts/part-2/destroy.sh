#!/usr/bin/env bash
#
# Tears down the Part 2 lake, restores the account's Lake Formation settings, and then
# VERIFIES that nothing was orphaned -- the rubric grades the destroy, so it is checked
# against AWS instead of trusting Terraform's exit code.
#
# Evidence: docs/evidence/part-2/destroy-check.json, stamped with the run_id of the lake it
# removes (read from run-manifest.json), so the teardown closes the same run as the rest.
#
# Usage: scripts/part-2/destroy.sh [--profile NAME] [--region REGION] [--workspace NAME]
#                                  [--include-backend] [--keep-lakeformation-settings]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION="us-east-1"
WORKSPACE="av2"
INCLUDE_BACKEND=0
RESTORE_LF=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)                     PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)                      REGION="${2:?--region needs a value}"; shift 2 ;;
    --workspace)                   WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
    --include-backend)             INCLUDE_BACKEND=1; shift ;;
    --keep-lakeformation-settings) RESTORE_LF=0; shift ;;
    -h|--help)                     sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform aws jq

export AWS_PROFILE_OVERRIDE="${PROFILE}"
export AWS_REGION_OVERRIDE="${REGION}"
[[ -z "${PROFILE}" ]] || export AWS_PROFILE="${PROFILE}"

terraform -chdir="${TF_DIR}" workspace select "${WORKSPACE}" || die "workspace '${WORKSPACE}' does not exist"

# Capture every name before the state is gone, so the orphan check has concrete targets.
BUCKETS="$(tf_output raw_bucket) $(tf_output trusted_bucket) $(tf_output refined_bucket) $(tf_output athena_results_bucket)"
DATABASES="$(tf_output raw_db) $(tf_output trusted_db) $(tf_output refined_db)"
PERSONAS_JSON="$(tf_output_json personas)"
WORKGROUPS="$(tf_output pipeline_workgroup) $(jq -r '[.[].workgroup] | join(" ")' <<< "${PERSONAS_JSON}")"
ROLE_NAMES="$(jq -r '[.[].role_arn | split("/") | last] | join(" ")' <<< "${PERSONAS_JSON}") $(tf_output lakeformation_data_access_role_arn | awk -F/ '{ print $NF }')"
LOCATIONS="$(tf_output_json registered_locations | jq -r 'join(" ")')"
PERSONA_ARNS="$(jq -r '[.[].role_arn] | join(" ")' <<< "${PERSONAS_JSON}")"

# Lake Formation grants held by the personas, across the whole catalog. Prints "null" when
# the call is refused (only a Lake Formation admin may list every grant), never a false 0.
lf_persona_grants() {
  local out n
  out="$(aws_cli lakeformation list-permissions --output json 2>/dev/null)" || { printf 'null'; return 0; }
  n="$(jq -s --arg arns "${PERSONA_ARNS}" '($arns | split(" ")) as $personas
    | [.[].PrincipalResourcePermissions[]?
       | select(.Principal.DataLakePrincipalIdentifier as $p | $personas | index($p))] | length' <<< "${out}" 2>/dev/null || true)"
  [[ "${n}" =~ ^[0-9]+$ ]] && printf '%s' "${n}" || printf 'null'
}

# Measured before the teardown, so the evidence explains any gap between what the apply
# created and what Terraform destroys: a resource the destroy's refresh can no longer read
# is dropped from the plan instead of destroyed. The counts say whether it was still in
# the state and still granted in Lake Formation at that moment.
STATE_RESOURCES="$(terraform -chdir="${TF_DIR}" state list | grep -cvE '(^|\.)data\.' || true)"
STATE_LF_GRANTS="$(terraform -chdir="${TF_DIR}" state list | grep -c 'aws_lakeformation_permissions\.' || true)"
LF_GRANTS_BEFORE="$(lf_persona_grants)"
log "Before the destroy: ${STATE_RESOURCES} resources in the state (${STATE_LF_GRANTS} Lake Formation grants), ${LF_GRANTS_BEFORE} persona grants in Lake Formation"

log "Destroying the parte-2 stack (workspace ${WORKSPACE})"
TF_VARS=(-var "aws_region=${REGION}")
[[ -z "${PROFILE}" ]] || TF_VARS+=(-var "aws_profile=${PROFILE}")
DESTROY_LOG="$(mktemp)"
terraform -chdir="${TF_DIR}" destroy -input=false -auto-approve "${TF_VARS[@]}" | tee "${DESTROY_LOG}"
# "Destroy complete! Resources: 74 destroyed." -- the count Terraform itself reports.
RESOURCES_DESTROYED="$(sed -n 's/.*Destroy complete! Resources: \([0-9][0-9]*\) destroyed.*/\1/p' "${DESTROY_LOG}" | tail -n 1)"
rm -f "${DESTROY_LOG}"

# Lake Formation drops a database's grants together with the database: measure what the
# personas still hold. Listing every grant needs a Lake Formation admin, and the destroy
# has just cleared the admins, so it is asked again once the settings are restored.
LF_GRANTS_AFTER="$(lf_persona_grants)"

# --- Lake Formation settings ---------------------------------------------------------
# Destroying aws_lakeformation_data_lake_settings CLEARS the account settings (no admins,
# no IAMAllowedPrincipals defaults) -- that is not how a fresh account looks. Put back
# what deploy.sh saved, or the AWS defaults if nothing was saved.
SETTINGS_BACKUP="${TF_DIR}/.lakeformation-settings.before.json"
if [[ "${RESTORE_LF}" -eq 1 ]]; then
  SETTINGS_FILE="$(mktemp)"
  if [[ -f "${SETTINGS_BACKUP}" ]]; then
    log "Restoring the Lake Formation settings saved before the first deploy"
    jq '.DataLakeSettings' "${SETTINGS_BACKUP}" > "${SETTINGS_FILE}"
  else
    log "No saved settings -- restoring the AWS defaults (IAMAllowedPrincipals on new databases/tables)"
    jq -n '{
      DataLakeAdmins: [],
      CreateDatabaseDefaultPermissions: [{Principal: {DataLakePrincipalIdentifier: "IAM_ALLOWED_PRINCIPALS"}, Permissions: ["ALL"]}],
      CreateTableDefaultPermissions:    [{Principal: {DataLakePrincipalIdentifier: "IAM_ALLOWED_PRINCIPALS"}, Permissions: ["ALL"]}]
    }' > "${SETTINGS_FILE}"
  fi
  aws_cli lakeformation put-data-lake-settings --data-lake-settings "file://${SETTINGS_FILE}" \
    || die "could not restore the Lake Formation settings -- see ${SETTINGS_FILE}"
  rm -f "${SETTINGS_FILE}" "${SETTINGS_BACKUP}"
  ok "Lake Formation settings restored"
fi
[[ "${LF_GRANTS_AFTER}" != "null" ]] || LF_GRANTS_AFTER="$(lf_persona_grants)"

# --- orphan check --------------------------------------------------------------------
log "Verifying no resources were orphaned"
ORPHANS=0
CHECKED=0
for b in ${BUCKETS}; do
  CHECKED=$(( CHECKED + 1 ))
  if aws_cli s3api head-bucket --bucket "${b}" >/dev/null 2>&1; then warn "bucket still exists: ${b}"; ORPHANS=1; fi
done
for db in ${DATABASES}; do
  CHECKED=$(( CHECKED + 1 ))
  if aws_cli glue get-database --name "${db}" >/dev/null 2>&1; then warn "Glue database still exists: ${db}"; ORPHANS=1; fi
done
for wg in ${WORKGROUPS}; do
  CHECKED=$(( CHECKED + 1 ))
  if aws_cli athena get-work-group --work-group "${wg}" >/dev/null 2>&1; then warn "Athena WorkGroup still exists: ${wg}"; ORPHANS=1; fi
done
for role in ${ROLE_NAMES}; do
  CHECKED=$(( CHECKED + 1 ))
  if aws_cli iam get-role --role-name "${role}" >/dev/null 2>&1; then warn "IAM role still exists: ${role}"; ORPHANS=1; fi
done
REGISTERED="$(aws_cli lakeformation list-resources --query 'ResourceInfoList[].ResourceArn' --output text 2>/dev/null || true)"
for location in ${LOCATIONS}; do
  CHECKED=$(( CHECKED + 1 ))
  if grep -qF "${location}" <<< "${REGISTERED}"; then warn "Lake Formation registration still exists: ${location}"; ORPHANS=1; fi
done
if [[ "${LF_GRANTS_AFTER}" != "null" ]]; then
  CHECKED=$(( CHECKED + 1 ))
  if [[ "${LF_GRANTS_AFTER}" -gt 0 ]]; then warn "Lake Formation grants still held by the personas: ${LF_GRANTS_AFTER}"; ORPHANS=1; fi
else
  warn "could not list Lake Formation grants after the destroy -- persona grants not checked"
fi

# The lake's run, when this teardown removes a lake built by run_all.sh; otherwise our own.
LAKE_RUN_ID="$(jq -r '.run_id // empty' "${RUN_MANIFEST}" 2>/dev/null || true)"
mkdir -p "${EVIDENCE_DIR}"
jq -n --arg run_id "${LAKE_RUN_ID:-${RUN_ID}}" --arg destroyed_at "$(now_utc_iso)" --arg region "${REGION}" \
  --arg workspace "${WORKSPACE}" --arg destroyed "${RESOURCES_DESTROYED}" \
  --argjson checked "${CHECKED}" --argjson orphans "${ORPHANS}" \
  --argjson state_resources "${STATE_RESOURCES:-null}" --argjson state_lf_grants "${STATE_LF_GRANTS:-null}" \
  --argjson lf_before "${LF_GRANTS_BEFORE}" --argjson lf_after "${LF_GRANTS_AFTER}" \
  '{
     run_id: $run_id,
     destroyed_at_utc: $destroyed_at,
     region: $region,
     workspace: $workspace,
     terraform_resources_in_state_before: $state_resources,
     terraform_lakeformation_grants_in_state_before: $state_lf_grants,
     terraform_resources_destroyed: (if $destroyed == "" then null else ($destroyed | tonumber) end),
     lakeformation_persona_grants_before: $lf_before,
     lakeformation_persona_grants_after: $lf_after,
     resources_checked_in_aws: $checked,
     orphaned: ($orphans != 0)
   }' > "${EVIDENCE_DIR}/destroy-check.json"
ok "evidence -> ${EVIDENCE_DIR}/destroy-check.json"

[[ "${ORPHANS}" -eq 0 ]] || die "teardown left orphaned resources -- investigate before submitting"
ok "No orphaned resources remain (${CHECKED} resources checked)"

if [[ "${INCLUDE_BACKEND}" -eq 1 ]]; then
  if [[ ! -f "${TF_DIR}/bootstrap/terraform.tfstate" ]]; then
    warn "parte-2/bootstrap did not create this backend (it was reused). Destroy it with the stack that owns it."
    exit 0
  fi
  warn "Destroying the backend deletes the Terraform state itself. This is irreversible."
  # Deliberately no --yes flag here: deleting the state must always be typed by a human.
  [[ -t 0 ]] || die "--include-backend needs an interactive terminal to confirm; run it in your own shell"
  read -r -p "Type 'destroy-backend' to confirm: " confirm || die "no confirmation read"
  [[ "${confirm}" == "destroy-backend" ]] || die "aborted"
  terraform -chdir="${TF_DIR}/bootstrap" destroy -input=false -auto-approve -var "aws_region=${REGION}"
  ok "Backend destroyed"
fi
