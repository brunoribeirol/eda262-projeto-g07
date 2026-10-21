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
# Runs the command silently and prints the PASSA/FALHA verdict.
criterion() {
  local label="$1"; shift
  TOTAL=$(( TOTAL + 1 ))
  if "$@" >/dev/null 2>&1; then
    printf '%sPASSA%s  %s\n' "${GREEN}" "${RESET}" "${label}"
    PASSED=$(( PASSED + 1 ))
  else
    printf '%sFALHA%s  %s\n' "${RED}" "${RESET}" "${label}"
    FAILED=$(( FAILED + 1 ))
  fi
}

section() { printf '\n%s%s%s\n' "${BOLD}" "$1" "${RESET}"; }

aws_cli() {
  if [[ -n "${PROFILE}" ]]; then aws --profile "${PROFILE}" "$@"; else aws "$@"; fi
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
