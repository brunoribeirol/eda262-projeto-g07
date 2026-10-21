#!/usr/bin/env bash
# Shared helpers for the Part 2 operational scripts. Sourced, never executed directly.
#
# Builds on scripts/lib.sh (logging, tf_output, aws_cli) and adds what Part 2 needs:
# running parameterized Athena statements, partition overwrite, cost math and portable
# date arithmetic (BSD date on macOS, GNU date on Linux -- the evaluator may use either).

PART2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${PART2_DIR}/../.." && pwd)/parte-2"
EVIDENCE_DIR="$(cd "${PART2_DIR}/../.." && pwd)/docs/evidence/part-2"
export TF_DIR EVIDENCE_DIR

# shellcheck source=../lib.sh
source "${PART2_DIR}/../lib.sh"

SQL_DIR="${TF_DIR}/sql"

# Athena bills a 10 MB minimum per query, at USD 5.00 per TB scanned in us-east-1.
readonly ATHENA_MIN_BILLED_BYTES=10485760
readonly BYTES_PER_TB=1099511627776
PRICE_PER_TB="${PRICE_PER_TB:-5.00}"

# --- arguments & session --------------------------------------------------------

# Every Part 2 script accepts --profile; this applies it the same way everywhere.
use_profile() {
  local profile="$1"
  if [[ -n "${profile}" ]]; then
    export AWS_PROFILE="${profile}"
  fi
  export AWS_PROFILE_OVERRIDE="${profile}"
  AWS_REGION_OVERRIDE="$(tf_output aws_region)"
  export AWS_REGION_OVERRIDE
}

tf_output_json() {
  local name="$1" value
  value="$(terraform -chdir="${TF_DIR}" output -json "${name}" 2>/dev/null)" || true
  [[ -n "${value}" && "${value}" != "null" ]] \
    || die "Terraform output '${name}' is empty. Has 'terraform apply' run in the selected workspace?"
  printf '%s' "${value}"
}

# S3 URI of a catalog table, by its key in local.tables (e.g. trusted_epss_scores).
table_location() {
  tf_output_json tables | jq -er --arg k "$1" '.[$k].location' \
    || die "unknown table key: $1"
}

now_utc_sql() { date -u '+%Y-%m-%d %H:%M:%S'; }
now_utc_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- dates ----------------------------------------------------------------------

if date --version >/dev/null 2>&1; then
  date_shift() { date -u -d "$1 $2 day" '+%Y-%m-%d'; }               # GNU
else
  date_shift() {                                                       # BSD / macOS
    local n="$2"
    [[ "${n}" == -* ]] || n="+${n}"
    date -u -j -v"${n}"d -f '%Y-%m-%d' "$1" '+%Y-%m-%d'
  }
fi

# A date is valid only if it is ISO-8601 AND survives a round trip (rejects 2026-02-30).
# Every date is validated before it reaches SQL, which is also what keeps rendered
# statements free of injection: only [0-9-] can ever be substituted.
require_date() {
  local d="$1"
  [[ "${d}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "not a yyyy-MM-dd date: '${d}'"
  [[ "$(date_shift "${d}" 0 2>/dev/null)" == "${d}" ]] || die "not a real calendar date: '${d}'"
}

# Prints every day from $1 to $2 inclusive.
date_range() {
  local d="$1"
  while [[ ! "${d}" > "$2" ]]; do
    printf '%s\n' "${d}"
    d="$(date_shift "${d}" 1)"
  done
}

# --- SQL ------------------------------------------------------------------------

# render_sql FILE key=value... -> SQL with every ${key} replaced. Fails if a placeholder
# is left unrendered, so a typo can never reach Athena as literal text.
render_sql() {
  local file="$1"; shift
  [[ -f "${file}" ]] || die "SQL template not found: ${file}"
  local sql pair key value
  sql="$(<"${file}")"
  for pair in "$@"; do
    key="${pair%%=*}"; value="${pair#*=}"
    sql="${sql//\$\{${key}\}/${value}}"
  done
  if grep -q '\${' <<< "${sql}"; then
    die "unrendered placeholder in ${file}: $(grep -o '\${[a-z_]*}' <<< "${sql}" | sort -u | tr '\n' ' ')"
  fi
  printf '%s' "${sql}"
}

named_query_sql() {
  local id
  id="$(tf_output_json named_query_ids | jq -er --arg k "$1" '.[$k]')" || die "unknown named query: $1"
  aws_cli athena get-named-query --named-query-id "${id}" --query 'NamedQuery.QueryString' --output text \
    || die "could not fetch named query $1 (${id})"
}

# --- Athena ---------------------------------------------------------------------

# athena_run SQL WORKGROUP DATABASE [PARAM...]
# Runs a statement to completion. On success prints the execution id and returns 0.
# On failure prints the execution id, records the reason (read it with athena_last_error)
# and returns 1, so callers that EXPECT a failure (the access check) can inspect it.
#
# The reason goes to a FILE, not a variable: athena_run is always called inside $(...),
# which runs in a subshell, and a variable set there dies with it. `$$` is the same in
# every subshell of a script, so they all share this one file.
ATHENA_ERROR_FILE="${TMPDIR:-/tmp}/eda262-g07-athena-error.$$"
athena_last_error() { cat "${ATHENA_ERROR_FILE}" 2>/dev/null || true; }

athena_run() {
  local sql="$1" workgroup="$2" database="$3"; shift 3
  local args=(--query-string "${sql}" --work-group "${workgroup}" --query-execution-context "Database=${database}")
  if [[ $# -gt 0 ]]; then
    args+=(--execution-parameters "$@")
  fi

  local execution_id state attempt=0
  : > "${ATHENA_ERROR_FILE}"
  execution_id="$(aws_cli athena start-query-execution "${args[@]}" --query 'QueryExecutionId' --output text 2>&1)" || {
    printf '%s' "${execution_id}" > "${ATHENA_ERROR_FILE}"
    printf '%s' "not-started"
    return 1
  }

  # INSERTs over a 30-day batch take tens of seconds; 15 minutes is a hard stop.
  while (( attempt < 900 )); do
    state="$(aws_cli athena get-query-execution --query-execution-id "${execution_id}" \
               --query 'QueryExecution.Status.State' --output text)"
    case "${state}" in
      SUCCEEDED) printf '%s' "${execution_id}"; return 0 ;;
      FAILED|CANCELLED)
        aws_cli athena get-query-execution --query-execution-id "${execution_id}" \
          --query 'QueryExecution.Status.StateChangeReason' --output text > "${ATHENA_ERROR_FILE}" 2>&1 || true
        printf '%s' "${execution_id}"
        return 1
        ;;
      *) sleep 1; attempt=$(( attempt + 1 )) ;;
    esac
  done
  printf 'timed out after 900s (last state: %s)' "${state}" > "${ATHENA_ERROR_FILE}"
  printf '%s' "${execution_id}"
  return 1
}

# Same as athena_run, but any failure is fatal.
athena_must() {
  local label="$1"; shift
  local execution_id
  log "${label}" >&2
  execution_id="$(athena_run "$@")" || die "${label} failed (${execution_id}): $(athena_last_error)"
  printf '%s' "${execution_id}"
}

athena_stats() {
  aws_cli athena get-query-execution --query-execution-id "$1" --output json \
    | jq '{
        execution_id: .QueryExecution.QueryExecutionId,
        data_scanned_bytes: (.QueryExecution.Statistics.DataScannedInBytes // 0),
        engine_execution_ms: (.QueryExecution.Statistics.EngineExecutionTimeInMillis // 0),
        total_execution_ms: (.QueryExecution.Statistics.TotalExecutionTimeInMillis // 0),
        output_location: .QueryExecution.ResultConfiguration.OutputLocation
      }'
}

# Downloads the result CSV Athena wrote for an execution.
athena_result_csv() {
  local execution_id="$1" destination="$2" location
  location="$(aws_cli athena get-query-execution --query-execution-id "${execution_id}" \
                --query 'QueryExecution.ResultConfiguration.OutputLocation' --output text)"
  aws_cli s3 cp "${location}" "${destination}" --only-show-errors \
    || die "could not download the result of ${execution_id}"
}

# Prints the result rows (no header) as TSV, for small gate queries.
athena_rows_tsv() {
  aws_cli athena get-query-results --query-execution-id "$1" --output json \
    | jq -r '.ResultSet.Rows[1:][] | [.Data[].VarCharValue // ""] | @tsv'
}

# cost_usd BYTES_SCANNED -> billed USD, applying Athena's 10 MB minimum.
cost_usd() {
  awk -v b="$1" -v min="${ATHENA_MIN_BILLED_BYTES}" -v tb="${BYTES_PER_TB}" -v p="${PRICE_PER_TB}" \
    'BEGIN { if (b < min) b = min; printf "%.8f", (b / tb) * p }'
}

billed_bytes() {
  awk -v b="$1" -v min="${ATHENA_MIN_BILLED_BYTES}" 'BEGIN { printf "%d", (b < min ? min : b) }'
}

# --- partitions -----------------------------------------------------------------

# Partition overwrite: remove every object under a partition prefix before rewriting it.
# This is what makes the append-only INSERT INTO idempotent.
clear_partition() {
  local table_uri="$1" key="$2" value="$3"
  aws_cli s3 rm "${table_uri}${key}=${value}/" --recursive --only-show-errors \
    || die "could not clear partition ${table_uri}${key}=${value}/"
}

count_partition_objects() {
  local table_uri="$1" key="$2" value="$3"
  aws_cli s3 ls "${table_uri}${key}=${value}/" --recursive 2>/dev/null | wc -l | tr -d ' '
}

# Partition values registered in Glue for a table, sorted ascending.
glue_partition_values() {
  local database="$1" table="$2"
  aws_cli glue get-partitions --database-name "${database}" --table-name "${table}" \
    --query 'Partitions[].Values[0]' --output json | jq -r '.[]' | sort
}

latest_partition() {
  local value
  value="$(glue_partition_values "$1" "$2" | tail -n 1)"
  [[ -n "${value}" ]] || die "table $1.$2 has no partitions yet -- run scripts/part-2/run_pipeline.sh first"
  printf '%s' "${value}"
}

# --- assumed roles --------------------------------------------------------------

# Prints "KEY SECRET TOKEN" for a role. Retries: a role created seconds ago may not be
# assumable yet (IAM is eventually consistent).
assume_role_credentials() {
  local role_arn="$1" attempt out
  for attempt in 1 2 3 4 5 6; do
    if out="$(aws_cli sts assume-role --role-arn "${role_arn}" --role-session-name "eda262-g07-check" \
                --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null)"; then
      printf '%s' "${out}"
      return 0
    fi
    sleep $(( attempt * 2 ))
  done
  return 1
}
