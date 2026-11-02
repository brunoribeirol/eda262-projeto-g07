#!/usr/bin/env bash
# Shared plumbing for verificacao/verifica.sh. Sourced, never executed directly.
# Criterion labels and PASSA/FALHA stay in Portuguese (evaluator-facing contract);
# everything else is English.

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; GRAY=$'\033[90m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; GRAY=''; BOLD=''; RESET=''
fi

TOTAL=0; PASSED=0; FAILED=0

# criterion "<label>" <command...>
# Runs the command silently and prints the PASSA/FALHA verdict. A check that measures
# something may leave the measurement in CRITERION_DETAIL; it is printed under the verdict,
# so the output shows the number, not just the label.
CRITERION_DETAIL=""
criterion() {
  local label="$1"; shift
  TOTAL=$(( TOTAL + 1 ))
  CRITERION_DETAIL=""
  if "$@" >/dev/null 2>&1; then
    printf '%sPASSA%s  %s\n' "${GREEN}" "${RESET}" "${label}"
    PASSED=$(( PASSED + 1 ))
  else
    printf '%sFALHA%s  %s\n' "${RED}" "${RESET}" "${label}"
    FAILED=$(( FAILED + 1 ))
  fi
  [[ -z "${CRITERION_DETAIL}" ]] || printf '%s       %s%s\n' "${GRAY}" "${CRITERION_DETAIL}" "${RESET}"
}

section() { printf '\n%s%s%s\n' "${BOLD}" "$1" "${RESET}"; }

# Every AWS call names the region explicitly. The runner's default region (profile config,
# AWS_REGION, AWS_DEFAULT_REGION) never decides where the lake is looked for.
aws_cli() {
  if [[ -n "${PROFILE}" ]]; then
    aws --profile "${PROFILE}" --region "${REGION}" "$@"
  else
    aws --region "${REGION}" "$@"
  fi
}

# declared_region FILE -> the default of `variable "aws_region"` in a Terraform file:
# the region the stack is declared to deploy to, unless --region says otherwise.
declared_region() {
  awk '/^variable "aws_region"/ { in_var = 1 }
       in_var && /default[[:space:]]*=/ { gsub(/.*=[[:space:]]*"|".*/, ""); print; exit }
       in_var && /^}/ { in_var = 0 }' "$1" 2>/dev/null
}

# --- Athena, for criteria that measure in the account ------------------------------------

# Scratch space for downloaded results; removed on exit.
VERIFY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/eda262-g07-verifica.XXXXXX")"
trap 'rm -rf "${VERIFY_TMP}"' EXIT

# athena_execute SQL WORKGROUP DATABASE [PARAM...] -> prints the execution id; returns 0 only
# if the statement SUCCEEDED. The failure reason goes to a FILE: callers capture the id with
# $(...), a subshell, where a variable assignment would be lost.
ATHENA_REASON_FILE="${VERIFY_TMP}/athena-reason"
athena_execute() {
  local sql="$1" workgroup="$2" database="$3"; shift 3
  local args=(--query-string "${sql}" --work-group "${workgroup}" --query-execution-context "Database=${database}")
  [[ $# -eq 0 ]] || args+=(--execution-parameters "$@")
  local id state attempt=0
  : > "${ATHENA_REASON_FILE}"
  id="$(aws_cli athena start-query-execution "${args[@]}" --query QueryExecutionId --output text 2>"${ATHENA_REASON_FILE}")" \
    || { printf 'not-started'; return 1; }
  while (( attempt < 300 )); do
    state="$(aws_cli athena get-query-execution --query-execution-id "${id}" \
               --query QueryExecution.Status.State --output text)" || return 1
    case "${state}" in
      SUCCEEDED) printf '%s' "${id}"; return 0 ;;
      FAILED|CANCELLED)
        aws_cli athena get-query-execution --query-execution-id "${id}" \
          --query QueryExecution.Status.StateChangeReason --output text > "${ATHENA_REASON_FILE}" 2>&1 || true
        printf '%s' "${id}"; return 1 ;;
      *) sleep 1; attempt=$(( attempt + 1 )) ;;
    esac
  done
  printf '%s' "${id}"
  return 1
}

athena_reason() { cat "${ATHENA_REASON_FILE}" 2>/dev/null || true; }

athena_scanned_bytes() {
  aws_cli athena get-query-execution --query-execution-id "$1" \
    --query QueryExecution.Statistics.DataScannedInBytes --output text
}

# Result rows (header dropped) as TSV; NULL becomes an empty field.
athena_rows() {
  aws_cli athena get-query-results --query-execution-id "$1" --output json \
    | jq -r '.ResultSet.Rows[1:][] | [.Data[].VarCharValue // ""] | @tsv'
}

athena_result_to() {
  local location
  location="$(aws_cli athena get-query-execution --query-execution-id "$1" \
                --query QueryExecution.ResultConfiguration.OutputLocation --output text)" || return 1
  aws_cli s3 cp "${location}" "$2" --only-show-errors
}

# Counts a failed prerequisite as one FALHA and explains how to skip the AWS block.
aws_credentials_or_fail() {
  if aws_cli sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi
  printf '%sFALHA%s  Credenciais AWS validas (necessarias para os criterios de AWS)\n' "${RED}" "${RESET}"
  printf '%s       use --repo-only para verificar apenas o repositorio%s\n' "${GRAY}" "${RESET}"
  TOTAL=$(( TOTAL + 1 )); FAILED=$(( FAILED + 1 ))
  return 1
}

print_summary_and_exit() {
  printf '\n%s%s%s\n' "${BOLD}" "$(printf '%.0s-' {1..60})" "${RESET}"
  printf 'Resultado: %s%d PASSA%s / %s%d FALHA%s  (total: %d criterios)\n' \
    "${GREEN}" "${PASSED}" "${RESET}" "${RED}" "${FAILED}" "${RESET}" "${TOTAL}"

  if [[ "${FAILED}" -eq 0 ]]; then
    printf '%sTodos os criterios foram atendidos.%s\n' "${GREEN}" "${RESET}"
    exit 0
  fi
  printf '%s%d criterio(s) nao atendido(s).%s\n' "${RED}" "${FAILED}" "${RESET}"
  exit 1
}
