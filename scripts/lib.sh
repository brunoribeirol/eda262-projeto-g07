#!/usr/bin/env bash
# Shared helpers for the EDA262 g07 operational scripts.
# Sourced, never executed directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/parte-1"
EVIDENCE_DIR="${REPO_ROOT}/docs/evidence"

# Colors only when attached to a terminal, so redirected logs stay clean.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

log()  { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok()   { printf '%s  OK%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%s WARN%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

require_cmd() {
  local missing=0
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || { warn "missing required command: ${cmd}"; missing=1; }
  done
  [[ "${missing}" -eq 0 ]] || die "install the missing dependencies and re-run"
}

# Read a Terraform output from the parte-1 stack, failing with a useful message
# instead of an empty string when the stack has not been applied yet.
tf_output() {
  local name="$1" value
  value="$(terraform -chdir="${TF_DIR}" output -raw "${name}" 2>/dev/null)" || true
  [[ -n "${value}" ]] || die "Terraform output '${name}' is empty. Has 'terraform apply' run in the selected workspace?"
  printf '%s' "${value}"
}

# AWS CLI wrapper honouring the profile/region resolved from Terraform or the environment.
aws_cli() {
  local args=()
  [[ -n "${AWS_PROFILE_OVERRIDE:-}" ]] && args+=(--profile "${AWS_PROFILE_OVERRIDE}")
  [[ -n "${AWS_REGION_OVERRIDE:-}" ]] && args+=(--region "${AWS_REGION_OVERRIDE}")
  aws "${args[@]}" "$@"
}
