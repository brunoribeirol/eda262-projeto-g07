#!/usr/bin/env bash
#
# Proves the per-layer access policy is enforced by Lake Formation: assumes every persona
# role and tries to read every layer through Athena, then compares each outcome with the
# matrix Terraform declared (output access_matrix).
#
# A denial only counts as proof if the very same probe succeeds for some other persona --
# otherwise a typo in the probe would look like a working permission. All personas share
# the same IAM shape, so a difference in outcome can only come from Lake Formation.
#
# Evidence: docs/evidence/part-2/access-matrix.json
#
# Usage: scripts/part-2/check_access.sh [--profile NAME]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd aws jq terraform
use_profile "${PROFILE}"

RAW_DB="$(tf_output raw_db)"
TRUSTED_DB="$(tf_output trusted_db)"
REFINED_DB="$(tf_output refined_db)"
PERSONAS_JSON="$(tf_output_json personas)"
MATRIX_JSON="$(tf_output_json access_matrix)"

KEV_DATE="$(latest_partition "${TRUSTED_DB}" kev_vulnerabilities)"
REFINED_DATE="$(latest_partition "${REFINED_DB}" vendor_exposure_daily)"

# One cheap probe per layer, always pruned to a single partition.
probe_db() {
  case "$1" in
    raw)     printf '%s' "${RAW_DB}" ;;
    trusted) printf '%s' "${TRUSTED_DB}" ;;
    refined) printf '%s' "${REFINED_DB}" ;;
  esac
}
probe_sql() {
  case "$1" in
    raw)     printf 'SELECT count(*) AS n FROM "%s"."kev_records" WHERE catalog_date = '"'"'%s'"'" "${RAW_DB}" "${KEV_DATE}" ;;
    trusted) printf 'SELECT count(*) AS n FROM "%s"."kev_vulnerabilities" WHERE catalog_date = '"'"'%s'"'" "${TRUSTED_DB}" "${KEV_DATE}" ;;
    refined) printf 'SELECT count(*) AS n FROM "%s"."vendor_exposure_daily" WHERE snapshot_date = '"'"'%s'"'" "${REFINED_DB}" "${REFINED_DATE}" ;;
  esac
}

# Athena surfaces a Lake Formation denial in a few shapes depending on what is hidden:
# the data ("Insufficient Lake Formation permission(s)") or even the metadata (not found).
is_permission_error() {
  grep -qiE 'lake ?formation|insufficient|permission|not authorized|access ?denied|does not exist|not found' <<< "$1"
}

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT
RESULTS="${WORK_DIR}/results.jsonl"
: > "${RESULTS}"

PERSONA_LIST="$(jq -r 'keys[]' <<< "${PERSONAS_JSON}")"
LAYERS="raw trusted refined"

while IFS= read -r persona; do
  role_arn="$(jq -r --arg p "${persona}" '.[$p].role_arn' <<< "${PERSONAS_JSON}")"
  workgroup="$(jq -r --arg p "${persona}" '.[$p].workgroup' <<< "${PERSONAS_JSON}")"
  log "Persona ${persona} (${workgroup})"

  creds="$(assume_role_credentials "${role_arn}")" || die "could not assume ${role_arn}"
  read -r key secret token <<< "${creds}"

  for layer in ${LAYERS}; do
    expected="$(jq -r --arg p "${persona}" --arg l "${layer}" '.[$p][$l]' <<< "${MATRIX_JSON}")"
    sql="$(probe_sql "${layer}")"
    db="$(probe_db "${layer}")"

    # Run as the persona: its own temporary credentials, no profile, nothing inherited.
    outcome="$(
      export AWS_ACCESS_KEY_ID="${key}" AWS_SECRET_ACCESS_KEY="${secret}" AWS_SESSION_TOKEN="${token}"
      unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_PROFILE_OVERRIDE
      if execution_id="$(athena_run "${sql}" "${workgroup}" "${db}")"; then
        printf 'granted\t%s\t' "${execution_id}"
      else
        printf 'denied\t%s\t%s' "${execution_id}" "$(athena_last_error | tr '\n\t' '  ')"
      fi
    )"
    IFS=$'\t' read -r actual execution_id reason <<< "${outcome}"

    if [[ "${actual}" == "denied" ]] && ! is_permission_error "${reason}"; then
      actual="error"   # failed for a reason that is not a permission -- not proof of anything
    fi
    expected_word="denied"; [[ "${expected}" == "true" ]] && expected_word="granted"

    if [[ "${actual}" == "${expected_word}" ]]; then
      ok "  ${layer}: ${actual} (expected ${expected_word})"
    else
      warn "  ${layer}: ${actual} (expected ${expected_word}) ${reason}"
    fi

    jq -nc --arg persona "${persona}" --arg layer "${layer}" --arg expected "${expected_word}" \
      --arg actual "${actual}" --arg execution_id "${execution_id}" --arg reason "${reason}" \
      '{persona: $persona, layer: $layer, expected: $expected, actual: $actual,
        match: ($expected == $actual), execution_id: $execution_id, reason: $reason}' >> "${RESULTS}"
  done
done <<< "${PERSONA_LIST}"

# Every layer's probe must have succeeded at least once, or its denials prove nothing.
UNPROVEN_LAYERS="$(jq -s -r '[group_by(.layer)[] | select(all(.actual != "granted")) | .[0].layer] | join(" ")' "${RESULTS}")"

mkdir -p "${EVIDENCE_DIR}"
jq -s \
  --arg checked_at "$(now_utc_iso)" --arg kev "${KEV_DATE}" --arg refined "${REFINED_DATE}" \
  --arg unproven "${UNPROVEN_LAYERS}" \
  '{
     checked_at_utc: $checked_at,
     enforced_by: "AWS Lake Formation (identical IAM policy for every persona)",
     probes: {raw: ("kev_records@" + $kev), trusted: ("kev_vulnerabilities@" + $kev), refined: ("vendor_exposure_daily@" + $refined)},
     checks: length,
     matches: (map(select(.match)) | length),
     all_match: (all(.match) and ($unproven == "")),
     layers_without_a_successful_probe: ($unproven | split(" ") | map(select(length > 0))),
     results: .
   }' "${RESULTS}" > "${EVIDENCE_DIR}/access-matrix.json"

echo
printf '%sAccess matrix (Lake Formation)%s\n' "${C_BOLD}" "${C_RESET}"
printf '  %-16s %-10s %-10s %-10s\n' "persona" "raw" "trusted" "refined"
jq -r '.results | group_by(.persona)[] | [.[0].persona,
        (map({(.layer): (.actual + (if .match then "" else "!" end))}) | add | .raw, .trusted, .refined)] | @tsv' \
  "${EVIDENCE_DIR}/access-matrix.json" \
  | awk -F'\t' '{ printf "  %-16s %-10s %-10s %-10s\n", $1, $2, $3, $4 }'
echo
ok "evidence -> ${EVIDENCE_DIR}/access-matrix.json"

[[ -z "${UNPROVEN_LAYERS}" ]] || die "no persona could read: ${UNPROVEN_LAYERS} -- the probe itself may be broken"
[[ "$(jq -r '.all_match' "${EVIDENCE_DIR}/access-matrix.json")" == "true" ]] \
  || die "access does not match the declared matrix (entries marked with !)"
ok "every persona reads exactly the layers it was granted"
