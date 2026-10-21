#!/usr/bin/env bash
#
# Acceptance script -- EDA262 course project, group g07.
#
# Prints PASSA or FALHA per criterion and exits 0 only if every criterion passes.
# Criterion labels and the PASSA/FALHA verdicts are intentionally kept in Portuguese:
# they are the evaluator-facing contract defined by the course guide. Everything
# else in these files is English, like the rest of the codebase.
#
# The criteria of each part live next to this file (part-1.sh, part-2.sh). Part 2 is the
# default since AV2; --parte 1 re-checks the AV1 delivery exactly as it was graded.
#
# Usage:
#   verificacao/verifica.sh                  # Part 2: repository + AWS resources
#   verificacao/verifica.sh --repo-only      # static criteria only, no AWS
#   verificacao/verifica.sh --parte 1        # Part 1 (AV1) criteria
#   verificacao/verifica.sh --profile NAME   # specific AWS profile
#
# Requires: bash, grep, jq. AWS criteria additionally require an authenticated AWS CLI.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PARTE=2
REPO_ONLY=0
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parte)     PARTE="${2:?--parte requires 1 or 2}"; shift 2 ;;
    --repo-only) REPO_ONLY=1; shift ;;
    --profile)   PROFILE="${2:?--profile requires a value}"; shift 2 ;;
    -h|--help)   sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib.sh
source "${REPO_ROOT}/verificacao/lib.sh"

case "${PARTE}" in
  1) source "${REPO_ROOT}/verificacao/part-1.sh"; run_part_1 ;;
  2) source "${REPO_ROOT}/verificacao/part-2.sh"; run_part_2 ;;
  *) echo "--parte must be 1 or 2" >&2; exit 2 ;;
esac

print_summary_and_exit
