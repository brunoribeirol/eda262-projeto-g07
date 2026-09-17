#!/usr/bin/env bash
#
# Renders the slide decks to PDF via headless Chrome.
#
# The Portuguese deck becomes apresentacao-parte-1-g07.pdf at the repository root --
# that exact filename is the one the course guide requires for delivery.
#
# Usage: scripts/build_pdf.sh [--en-only|--pt-only]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECK_DIR="${REPO_ROOT}/docs/presentation"
BUILD_PT=1
BUILD_EN=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pt-only) BUILD_EN=0; shift ;;
    --en-only) BUILD_PT=0; shift ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Chrome ships under different paths depending on the machine; take the first that exists.
CHROME=""
for candidate in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  "$(command -v google-chrome 2>/dev/null)" \
  "$(command -v chromium 2>/dev/null)"
do
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then CHROME="${candidate}"; break; fi
done

[[ -n "${CHROME}" ]] || die "no Chrome/Chromium/Edge binary found -- open the .html and print to PDF manually (margins: none, background graphics: on)"

PROFILE_DIR="$(mktemp -d)"
# shellcheck disable=SC2064  # PROFILE_DIR must expand now, not at trap time
trap "rm -rf '${PROFILE_DIR}'" EXIT

render() {
  local src="$1" out="$2" label="$3"

  [[ -f "${src}" ]] || die "deck not found: ${src}"
  log "Rendering ${label}"

  # Each render gets its OWN profile directory. Reusing one across sequential
  # Chrome invocations makes the second instance find the first profile's lock
  # and block indefinitely on ProcessSingleton -- it hangs rather than failing.
  local profile
  profile="$(mktemp -d "${PROFILE_DIR}/chrome-XXXXXX")"

  # --virtual-time-budget lets webfonts and layout settle before the snapshot.
  # The timeout is a backstop: a wedged Chrome must not stall the pipeline.
  "${CHROME}" \
    --headless \
    --disable-gpu \
    --no-first-run \
    --no-default-browser-check \
    --user-data-dir="${profile}" \
    --no-pdf-header-footer \
    --virtual-time-budget=5000 \
    --print-to-pdf="${out}" \
    "file://${src}" >/dev/null 2>&1 &

  local chrome_pid=$!
  local waited=0
  while kill -0 "${chrome_pid}" 2>/dev/null; do
    if (( waited >= 90 )); then
      kill -9 "${chrome_pid}" 2>/dev/null || true
      die "Chrome hung rendering ${label} (90s). Open ${src} and print manually (margins: none, background graphics: on)."
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  wait "${chrome_pid}" 2>/dev/null || true

  [[ -s "${out}" ]] || die "Chrome produced no PDF for ${label}. Open ${src} and print manually (margins: none, background graphics: on)."

  # A 10-slide deck must render as 10 pages; a mismatch means the page box broke.
  local pages
  pages="$(grep -ac '/Type[[:space:]]*/Page[^s]' "${out}" 2>/dev/null || echo 0)"
  local size_kb=$(( $(wc -c < "${out}") / 1024 ))

  ok "${label}: ${out} (${size_kb} KB, ~${pages} pages)"
  if [[ "${pages}" != "10" ]]; then
    warn "expected 10 pages, detected ~${pages}. Open the PDF and confirm one slide per page."
  fi
}

if [[ "${BUILD_PT}" -eq 1 ]]; then
  render "${DECK_DIR}/apresentacao-parte-1-g07.html" \
         "${REPO_ROOT}/apresentacao-parte-1-g07.pdf" \
         "Portuguese deck (delivered)"
fi

if [[ "${BUILD_EN}" -eq 1 ]]; then
  render "${DECK_DIR}/presentation-part-1-g07.html" \
         "${REPO_ROOT}/presentation-part-1-g07.pdf" \
         "English deck"
fi

echo
ok "Check that the orange accents rendered. If they are missing, Chrome dropped the"
ok "background graphics -- print manually with that option enabled."
