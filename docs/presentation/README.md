# Presentation — EDA262 Part 1 (AV1), group g07

| File | Language | Purpose |
|---|---|---|
| `apresentacao-parte-1-g07.html` | Portuguese | Source for the **delivered PDF**. The filename is mandated by the course guide. |
| `presentation-part-1-g07.html` | English | Portfolio version. Identical design and numbers. |
| `img/demo-*.png` | — | Terminal screenshots of the real run used as demo evidence on slide 7. |

The Portuguese deck is the one that becomes the delivered PDF; the English deck exists for
portfolio use. Both decks share a byte-identical stylesheet, so a change to one must be mirrored in the other.

---

## Structure

Eight slides, built around the four items the course guide requires (scenario, architecture,
demo, decisions with numbers) and a five-minute hard cutoff:

| # | Slide | Guide item |
|---|---|---|
| 1 | Cover: the business question as the title | Scenario |
| 2 | Why KEV: 393,026 published CVEs (NVD) vs 1,713 exploited (0.4%) | Scenario and question |
| 3 | Architecture: collect → keep (raw) → organize (trusted + Glue) → ask (Athena) | Architecture |
| 4 | Grain (0 duplicates) and quality (18 → 0 dirty rows) | Decisions |
| 5 | The answer: volume is not risk (Oracle 43% ransomware-linked) | Question answered |
| 6 | Cost per query: USD 0.00004768, Parquet would save USD 0.00 | Measured cost |
| 7 | Demo: apply, query with cost, verifica.sh 25/25, destroy with 0 orphans | Demo |
| 8 | Every decision with its number, product angle, Part 2 (EPSS) | Decisions |

Slides 2, 4, 5, 6 and 8 cite the official run of 2026-09-17 recorded in `docs/evidence/`.
Slide 7 shows a second, from-scratch run on 2026-10-04 (catalog 2026.10.04, 1,734 records): the
ranking shifted slightly with the feed, and the measured cost came out identical.

### Demo screenshots

The screenshots in `img/` are the raw terminal captures of the 2026-10-04 run. Slide 7 crops each
one with CSS (`background-size`/`background-position` on a fixed `aspect-ratio`), so the source
files stay untouched and the crop can be adjusted without re-capturing. The full destroy capture
was deliberately left out because it prints the AWS account ID.

---

## Design constraints (from the course guide)

Non-negotiable, and already applied:

- Arial, one title per slide, ~5 bullets maximum
- Orange as accent only, used sparingly
- Square bullets
- No 3D, no shadows, no generic stock imagery
- Monochrome charts with the main series in orange

---

## Generating the PDF

The delivered file must be named `apresentacao-parte-1-g07.pdf`.

```bash
scripts/build_pdf.sh          # renders both decks
```

It picks up Chrome, Chromium or Edge automatically and checks that the output has one page per slide.
Doing it by hand instead:

```bash
cd "$(git rev-parse --show-toplevel)"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
  --no-pdf-header-footer --print-to-pdf="apresentacao-parte-1-g07.pdf" \
  "file://$PWD/docs/presentation/apresentacao-parte-1-g07.html"
```

For the English version, swap the input file and name the output `presentation-part-1-g07.pdf`.

**Printing manually from Chrome (Cmd+P):** set margins to *None* and **enable "Background
graphics"** — otherwise the orange bars and accent rules disappear.

The page box is 13.333in × 7.5in (16:9), so each slide renders as exactly one PDF page.

---

## Delivery record

- **Presented and submitted:** 2026-10-05 (Part 1 / AV1).
- **Delivered deck:** `apresentacao-parte-1-g07.pdf` at the signed tag `av1-entrega`.
- The talk track (`speaker-notes.pt-BR.md`) is gitignored on purpose and lives only locally.

## Before presenting (reuse for Part 2)

- [ ] Render both decks with `scripts/build_pdf.sh` and confirm 8 pages each.
- [ ] Confirm `docs/evidence/` still holds the official 2026-09-17 run (`git status` clean) — the
      slides cite those figures. Re-running `run_query.sh` overwrites them.
- [ ] Rehearse with a timer at least once. Five minutes is a hard cutoff; the talk track budgets
      ~260s.
