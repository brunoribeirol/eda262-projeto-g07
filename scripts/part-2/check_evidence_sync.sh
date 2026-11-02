#!/usr/bin/env bash
#
# Checks that the committed evidence comes from ONE run and that the documents cite THAT
# run. This is the AV1 lesson: the slides, the evidence files and DECISOES.md had drifted
# to three different executions, with execution ids and times that no longer matched.
#
#   1. every per-run evidence file carries the run_id recorded in run-manifest.json
#   2. each result CSV still hashes to what query-cost.json recorded when it was downloaded
#   3. DECISOES.md, DECISIONS.md and both Part 2 decks quote the run's own numbers -- run id,
#      execution id, bytes scanned, engine time, rows, window, resources applied and
#      destroyed -- each written the way that document writes numbers (pt-BR 162.943,
#      English 162,943, terminal output 162943, pt-BR dates 20/10/2026)
#   4. the answer slide (slide 6) shows the result CSV's rows, in its order, with its counts,
#      averages and sample sizes; the decision 25 table shows epss-sample-stability.csv
#   5. the demo slide quotes the result of the acceptance run (verifica-output.txt)
#   6. nothing left over from an older run: no PENDENTE/PENDING marker, no old 10 MB target
#
# Offline: reads only docs/evidence/part-2/ and the documents. Prints every value that is
# missing and exits non-zero if any is. verificacao/verifica.sh runs it as one criterion;
# after a reference run, run it by hand to see exactly which numbers still need updating.
#
# Usage: scripts/part-2/check_evidence_sync.sh [--quiet] [--require-destroy]
#   --require-destroy   the teardown must be recorded too (delivery check, lake already gone)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUIET=0
REQUIRE_DESTROY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)           QUIET=1; shift ;;
    --require-destroy) REQUIRE_DESTROY=1; shift ;;
    -h|--help)         sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd jq awk

say() { [[ "${QUIET}" -eq 1 ]] || printf '%s\n' "$*"; }
PROBLEMS=0
TAB=$'\t'
problem() { PROBLEMS=$(( PROBLEMS + 1 )); say "  ${C_RED}MISSING${C_RESET}  $*"; }
fine()    { say "  ${C_GREEN}OK${C_RESET}       $*"; }

# Documents, by key. pt-BR groups thousands with "." and writes decimals with ","; English
# the other way round.
doc_path() {
  case "$1" in
    D) printf '%s' "${REPO_ROOT}/DECISOES.md" ;;
    E) printf '%s' "${REPO_ROOT}/DECISIONS.md" ;;
    P) printf '%s' "${REPO_ROOT}/docs/presentation/apresentacao-parte-2-g07.html" ;;
    N) printf '%s' "${REPO_ROOT}/docs/presentation/presentation-part-2-g07.html" ;;
  esac
}
doc_sep() { case "$1" in D|P) printf '.' ;; *) printf ',' ;; esac; }
doc_decimal() { case "$1" in D|P) printf ',' ;; *) printf '.' ;; esac; }

# group_thousands 162943 . -> 162.943
group_thousands() {
  local n="$1" sep="$2" out=""
  while (( ${#n} > 3 )); do
    out="${sep}${n: -3}${out}"
    n="${n:0:${#n}-3}"
  done
  printf '%s%s' "${n}" "${out}"
}

# --- 1. one run -------------------------------------------------------------------------
say "${C_BOLD}Evidence from a single run${C_RESET}"
[[ -f "${RUN_MANIFEST}" ]] || { problem "run-manifest.json -- produce the evidence with scripts/part-2/run_all.sh"; exit 1; }
MANIFEST_RUN="$(jq -r '.run_id // empty' "${RUN_MANIFEST}")"
[[ -n "${MANIFEST_RUN}" ]] || { problem "run_id in run-manifest.json"; exit 1; }
say "  run ${MANIFEST_RUN} ($(jq -r '.status' "${RUN_MANIFEST}"), commit $(jq -r '.git.commit[0:12]' "${RUN_MANIFEST}"))"

# Written by every full run; verifica-output.txt and destroy-check.json come at the end.
REQUIRED="apply-check.json kev-ingest.json epss-ingest.json refined-build.json query-cost.json
cost-comparison.json idempotency-check.json idempotency-epss-reload.json idempotency-refined-rebuild.json
access-matrix.json business-question-result.csv grain-check-result.csv epss-sample-stability.csv"
for f in ${REQUIRED}; do
  [[ -f "${EVIDENCE_DIR}/${f}" ]] || problem "${f} -- not produced by run ${MANIFEST_RUN}"
done
if [[ -f "${EVIDENCE_DIR}/apply-check.json" ]] \
   && [[ "$(jq -r '.from_scratch' "${EVIDENCE_DIR}/apply-check.json")" != "true" ]]; then
  problem "apply-check.json: the run's apply did not start from an empty lake (destroy before run_all.sh)"
fi
if [[ -f "${EVIDENCE_DIR}/destroy-check.json" ]]; then
  [[ "$(jq -r '.orphaned' "${EVIDENCE_DIR}/destroy-check.json")" == "false" ]] \
    || problem "destroy-check.json: the teardown left orphaned resources"
elif [[ "${REQUIRE_DESTROY}" -eq 1 ]]; then
  problem "destroy-check.json -- the teardown of run ${MANIFEST_RUN} is not recorded (scripts/part-2/destroy.sh)"
fi

for f in ${PER_RUN_EVIDENCE}; do
  [[ "${f}" == *.json && "${f}" != "run-manifest.json" && -f "${EVIDENCE_DIR}/${f}" ]] || continue
  run="$(jq -r '.run_id // "none"' "${EVIDENCE_DIR}/${f}")"
  if [[ "${run}" == "${MANIFEST_RUN}" ]]; then fine "${f}"; else problem "${f} belongs to run ${run}, not ${MANIFEST_RUN}"; fi
done

if [[ -f "${EVIDENCE_DIR}/query-cost.json" ]]; then
  while IFS=$'\t' read -r name recorded; do
    [[ -n "${name}" ]] || continue
    if [[ ! -f "${EVIDENCE_DIR}/${name}" ]]; then
      problem "${name} (hash recorded, file absent)"
    elif [[ "$(file_sha256 "${EVIDENCE_DIR}/${name}")" == "${recorded}" ]]; then
      fine "${name} (sha256 matches query-cost.json)"
    else
      problem "${name} changed after run ${MANIFEST_RUN} downloaded it (sha256 differs)"
    fi
  done <<< "$(jq -r '(.result_files_sha256 // {}) | to_entries[] | [.key, .value] | @tsv' "${EVIDENCE_DIR}/query-cost.json")"
fi

if [[ -f "${EVIDENCE_DIR}/verifica-output.txt" ]]; then
  if grep -qF "${MANIFEST_RUN}" "${EVIDENCE_DIR}/verifica-output.txt"; then
    fine "verifica-output.txt"
  else
    problem "verifica-output.txt was not produced against run ${MANIFEST_RUN}"
  fi
fi

# --- 2. documents cite the run -----------------------------------------------------------
# label | evidence file | jq path | format | documents | pt template | en template
#   format: id       = verbatim (ids, ISO dates)
#           int      = grouped the way each document groups numbers
#           term     = verbatim integer, as the terminal printed it (demo slide)
#           ddmm     = ISO date written 21/09          (pt-BR deck)
#           ddmmyyyy = ISO date written 20/10/2026     (pt-BR deck)
#   templates: the phrase the value sits in, "@" standing for it -- needed for small numbers
#              (74 resources) that would otherwise match anywhere. Empty = the bare value.
ITEMS="run id|run-manifest.json|.run_id|id|DEPN||
refined execution id|query-cost.json|.execution_id|id|DE||
refined bytes scanned|query-cost.json|.data_scanned_bytes|int|DEPN||
refined engine time (ms)|query-cost.json|.engine_execution_ms|int|DE||
cost target for the window (bytes)|query-cost.json|.cost_target.max_scanned_bytes|int|DEPN||
window first day|query-cost.json|.window.first_day|id|DEPN||
window last day|query-cost.json|.window.last_day|id|DEPN||
window first day (pt-BR deck)|query-cost.json|.window.first_day|ddmm|P||
window last day (pt-BR deck)|query-cost.json|.window.last_day|ddmmyyyy|P||
KEV catalog date|query-cost.json|.kev_catalog_date|id|DE||
trusted bytes scanned|cost-comparison.json|.business_question.trusted.data_scanned_bytes|int|DE||
raw bytes scanned|cost-comparison.json|.business_question.raw.data_scanned_bytes|int|DE||
raw bytes scanned (demo)|cost-comparison.json|.business_question.raw.data_scanned_bytes|term|PN||
pruning: 1 day (bytes)|cost-comparison.json|.partition_pruning.one_day.data_scanned_bytes|int|DEPN||
pruning: whole window (bytes)|cost-comparison.json|.partition_pruning.whole_window.data_scanned_bytes|int|DEPN||
EPSS rows in the window|epss-ingest.json|.totals.trusted_rows|int|DEPN||
backfill INSERT bytes scanned|epss-ingest.json|.totals.insert_scanned_bytes|int|DE||
rows after re-loading a day|idempotency-check.json|.trusted_epss_scores.after.rows|int|DEPN||
resources created by the apply|apply-check.json|.resources_added|term|DEPN|@ recursos|@ resources
apply from scratch (demo)|apply-check.json|.resources_added|term|PN|Resources: @ added|Resources: @ added
resources destroyed|destroy-check.json|.terraform_resources_destroyed|term|DEPN|Resources: @ destroyed|Resources: @ destroyed"

# format_value FORMAT VALUE DOC
format_value() {
  case "$1" in
    int)      group_thousands "$2" "$(doc_sep "$3")" ;;
    ddmm)     printf '%s/%s' "${2:8:2}" "${2:5:2}" ;;
    ddmmyyyy) printf '%s/%s/%s' "${2:8:2}" "${2:5:2}" "${2:0:4}" ;;
    *)        printf '%s' "$2" ;;
  esac
}

say ""
say "${C_BOLD}Documents citing run ${MANIFEST_RUN}${C_RESET}"
while IFS='|' read -r label file path kind docs pt_template en_template; do
  [[ -n "${label}" ]] || continue
  if [[ ! -f "${EVIDENCE_DIR}/${file}" ]]; then
    # The teardown is recorded after the acceptance run; until then it cannot be cited.
    if [[ "${file}" == "destroy-check.json" ]]; then
      say "  -        ${label}: pending -- destroy.sh writes it after the acceptance; then cite '${pt_template//@/N}' in all four documents"
      continue
    fi
    problem "${label}: ${file} is missing"
    continue
  fi
  value="$(jq -r "${path} // empty" "${EVIDENCE_DIR}/${file}")"
  [[ -n "${value}" ]] || { problem "${label}: no ${path} in ${file}"; continue; }

  missing=""
  shown=""
  for (( i = 0; i < ${#docs}; i++ )); do
    doc="${docs:${i}:1}"
    needle="$(format_value "${kind}" "${value}" "${doc}")"
    case "${doc}" in D|P) template="${pt_template}" ;; *) template="${en_template}" ;; esac
    [[ -z "${template}" ]] || needle="${template//@/${needle}}"
    [[ "${shown}" == *"${needle}"* ]] || shown="${shown:+${shown} / }${needle}"
    grep -qF -- "${needle}" "$(doc_path "${doc}")" 2>/dev/null || missing="${missing} $(basename "$(doc_path "${doc}")")"
  done
  if [[ -z "${missing}" ]]; then fine "${label} = ${shown}"; else problem "${label} = ${shown} not in:${missing}"; fi
done <<< "${ITEMS}"

# --- 3. the answer slide and the sample-size table ---------------------------------------

# csv_tsv FILE -> the CSV as Athena wrote it (quoted fields, NULL = empty), as TSV with header.
csv_tsv() {
  awk '
    { sub(/\r$/, ""); out = ""; field = ""; inq = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (inq) {
          if (c == "\"") { if (substr($0, i + 1, 1) == "\"") { field = field c; i++ } else inq = 0 }
          else field = field c
        } else if (c == "\"") inq = 1
        else if (c == ",") { out = out field "\t"; field = "" }
        else field = field c
      }
      print out field }' "$1"
}

# chart_rows DOC -> "vendor<TAB>count<TAB>average<TAB>n" for each bar of the answer chart
# (the only chart whose bars carry an average and its sample size).
chart_rows() {
  local tab=$'\t'
  sed -n -E "s/.*class=\"bar-label\">([^<]*)<.*class=\"bar-val[^\"]*\">([^<]*)<.*class=\"bar-extra[^\"]*\">([^<]*)<span class=\"soft\">\(([0-9]+)\)<\/span>.*/\1${tab}\2${tab}\3${tab}\4/p" "$(doc_path "$1")" \
    | sed -e 's/&amp;/\&/g' -e 's/&mdash;/—/g' -e "s/ *${tab}/${tab}/g"
}

# expected_rows SEP -> the same four fields from the result CSV, in its order, average rounded
# to 2 places with SEP as decimal mark ("—" where the sample is too small), plus vendor_rank.
expected_rows() {
  csv_tsv "${EVIDENCE_DIR}/business-question-result.csv" | awk -F'\t' -v sep="$1" '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    { avg = $(col["epss_avg_latest"])
      if (avg == "") avg = "—"; else { avg = sprintf("%.2f", avg); sub(/\./, sep, avg) }
      print $(col["vendor_project"]) "\t" $(col["kev_cves_last_12m"]) "\t" avg "\t" $(col["epss_scored_cves"]) "\t" $(col["vendor_rank"]) }'
}

say ""
say "${C_BOLD}Answer slide (slide 6) against business-question-result.csv${C_RESET}"
if [[ -f "${EVIDENCE_DIR}/business-question-result.csv" ]]; then
  for doc in P N; do
    shown_rows="$(chart_rows "${doc}")"
    deck="$(basename "$(doc_path "${doc}")")"
    [[ -n "${shown_rows}" ]] || { problem "${deck}: no answer chart found"; continue; }
    shown_count="$(printf '%s\n' "${shown_rows}" | wc -l | tr -d ' ')"
    expected="$(expected_rows "$(doc_decimal "${doc}")")"
    bad=0
    for (( i = 1; i <= shown_count; i++ )); do
      got="$(printf '%s\n' "${shown_rows}" | sed -n "${i}p")"
      want="$(printf '%s\n' "${expected}" | sed -n "${i}p" | cut -f1-4)"
      if [[ "${got}" != "${want}" ]]; then
        bad=1
        problem "${deck} row ${i}: shows '${got//${TAB}/ | }', CSV has '${want//${TAB}/ | }'"
      fi
    done
    # Ties are kept: the chart may stop only where the rank changes.
    last_rank="$(printf '%s\n' "${expected}" | sed -n "${shown_count}p" | cut -f5)"
    next_rank="$(printf '%s\n' "${expected}" | sed -n "$(( shown_count + 1 ))p" | cut -f5)"
    if [[ -n "${next_rank}" && "${next_rank}" == "${last_rank}" ]]; then
      bad=1
      problem "${deck}: the chart stops inside a tie at rank ${last_rank} -- show the whole tie"
    fi
    [[ "${bad}" -eq 1 ]] || fine "${deck}: ${shown_count} vendors, counts, averages and n match"
  done
fi

say ""
say "${C_BOLD}Decision 25 table against epss-sample-stability.csv${C_RESET}"
if [[ -f "${EVIDENCE_DIR}/epss-sample-stability.csv" ]]; then
  # doc | row label | CSV column | decimals (- = integer)
  ROWS="D|Fabricantes|vendors|-
D|Maior variação|max_abs_change|2
D|p90 da variação (aproximado)|p90_abs_change|2
E|Vendors|vendors|-
E|Largest change|max_abs_change|2
E|p90 of the change (approximate)|p90_abs_change|2"
  while IFS='|' read -r doc label column places; do
    values="$(csv_tsv "${EVIDENCE_DIR}/epss-sample-stability.csv" | awk -F'\t' -v c="${column}" -v p="${places}" -v sep="$(doc_decimal "${doc}")" '
      NR == 1 { for (i = 1; i <= NF; i++) if ($i == c) k = i; next }
      { v = $k; if (p != "-") { v = sprintf("%." p "f", v); sub(/\./, sep, v) }; out = out v "|" }
      END { print out }')"
    want="|${label// /}|${values}"
    # The row as decision 25 writes it, bold and spacing dropped.
    got="$(awk -v l="| ${label} |" '/^## 25\./ { on = 1; next } on && /^## / { exit } on && index($0, l) == 1 { print; exit }' "$(doc_path "${doc}")" | tr -d '* ')"
    if [[ "${got}" == "${want}" ]]; then fine "$(basename "$(doc_path "${doc}")"): ${label} ${values}"
    else problem "$(basename "$(doc_path "${doc}")") decision 25 '${label}': has '${got:-no such row}', CSV gives '${want}'"; fi
  done <<< "${ROWS}"
fi

# --- 4. the acceptance result the demo slide quotes ------------------------------------
say ""
say "${C_BOLD}Acceptance result on the demo slide${C_RESET}"
ACCEPTED="$(sed $'s/\033\\[[0-9;]*m//g' "${EVIDENCE_DIR}/verifica-output.txt" 2>/dev/null | grep '^Resultado:' | tail -n 1 | tr -s ' ' || true)"
if [[ -z "${ACCEPTED}" ]]; then
  # Absent, or verifica is writing it right now (this script runs inside verifica.sh).
  say "  -        no finished verifica-output.txt yet"
else
  WANTED="${ACCEPTED}"
  if [[ "$(jq -r '.verifica.exit_status // 1' "${RUN_MANIFEST}")" != "0" ]]; then
    # The recorded acceptance failed -- run_all.sh's always does, since it runs before the
    # documents cite the run. The deck must already show the result verify_run.sh has to reach.
    total="$(sed -n 's/.*(total: \([0-9][0-9]*\) criterios).*/\1/p' <<< "${ACCEPTED}")"
    WANTED="Resultado: ${total} PASSA / 0 FALHA (total: ${total} criterios)"
    if [[ "${REQUIRE_DESTROY}" -eq 1 ]]; then
      problem "the recorded acceptance did not pass ('${ACCEPTED}') -- run scripts/part-2/verify_run.sh before the destroy"
    else
      say "  -        recorded acceptance: '${ACCEPTED}' -- pending scripts/part-2/verify_run.sh"
    fi
  fi
  for doc in P N; do
    if sed 's/<[^>]*>//g' "$(doc_path "${doc}")" | tr -s ' ' | grep -qF -- "${WANTED}"; then
      fine "$(basename "$(doc_path "${doc}")"): ${WANTED}"
    else
      problem "$(basename "$(doc_path "${doc}")") does not quote '${WANTED}'"
    fi
  done
fi

# --- 5. leftovers from older runs ------------------------------------------------------
say ""
say "${C_BOLD}Leftovers from older runs${C_RESET}"
# doc | text that must not appear | why
LEFTOVERS="D|PENDENTE|number still to be measured
E|PENDING|number still to be measured
P|PENDENTE|number still to be measured
N|PENDING|number still to be measured
P|10485760|the old 10 MB cost target
N|10485760|the old 10 MB cost target"
clean=1
while IFS='|' read -r doc text why; do
  lines="$(grep -nF -- "${text}" "$(doc_path "${doc}")" 2>/dev/null | cut -d: -f1 | tr '\n' ' ' || true)"
  [[ -z "${lines}" ]] || { clean=0; problem "$(basename "$(doc_path "${doc}")") line(s) ${lines}still say '${text}' (${why})"; }
done <<< "${LEFTOVERS}"
[[ "${clean}" -eq 0 ]] || fine "no PENDENTE/PENDING marker, no old cost target"

say ""
if [[ "${PROBLEMS}" -eq 0 ]]; then
  say "${C_GREEN}Evidence and documents agree on run ${MANIFEST_RUN}.${C_RESET}"
  exit 0
fi
say "${C_RED}${PROBLEMS} item(s) out of sync with run ${MANIFEST_RUN}.${C_RESET}"
exit 1
