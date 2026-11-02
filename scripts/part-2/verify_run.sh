#!/usr/bin/env bash
#
# Final acceptance of a reference run: re-runs verificacao/verifica.sh against the run in
# docs/evidence/part-2/ and records it as that run's result (verifica-output.txt and the
# .verifica summary in run-manifest.json).
#
# run_all.sh runs the acceptance once, at the end of the run -- before DECISOES.md and the
# decks cite the new numbers, so the "single run, cited" criterion fails by construction.
# Update the documents until scripts/part-2/check_evidence_sync.sh is clean, then run this
# while the lake is still up (sections 4 and 5 of verifica.sh measure in the account), and
# only then destroy.
#
# Usage: scripts/part-2/verify_run.sh [--profile NAME] [--region REGION]
#   --region   defaults to the region recorded in run-manifest.json

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE=""
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)  REGION="${2:?--region needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd jq aws
[[ -f "${RUN_MANIFEST}" ]] || die "no run-manifest.json: produce the run with scripts/part-2/run_all.sh first"
MANIFEST_RUN="$(jq -r '.run_id // empty' "${RUN_MANIFEST}")"
[[ -n "${MANIFEST_RUN}" ]] || die "run-manifest.json has no run_id"
[[ -n "${REGION}" ]] || REGION="$(jq -r '.region // empty' "${RUN_MANIFEST}")"
[[ -n "${REGION}" ]] || die "no --region and none recorded in run-manifest.json"

PROFILE_ARGS=()
[[ -z "${PROFILE}" ]] || PROFILE_ARGS=(--profile "${PROFILE}")

log "Final acceptance of run ${MANIFEST_RUN} (${REGION})"
status=0
run_acceptance --region "${REGION}" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} || status=$?

echo
if [[ "${status}" -eq 0 ]]; then
  ok "Run ${MANIFEST_RUN} accepted: $(jq -r '.verifica.summary' "${RUN_MANIFEST}")"
  log "Next: scripts/part-2/destroy.sh ${PROFILE:+--profile ${PROFILE} }--region ${REGION} (writes destroy-check.json)"
else
  warn "Not accepted -- fix the FALHA criteria above and run this again before destroying the lake."
fi
exit "${status}"
