# Presentation — EDA262 Part 1 (AV1), group g07

| File | Language | Purpose |
|---|---|---|
| `apresentacao-parte-1-g07.html` | Portuguese | Source for the **delivered PDF**. The filename is mandated by the course guide. |
| `presentation-part-1-g07.html` | English | Portfolio version. Identical design and numbers. |
| `speaker-notes.pt-BR.md` | Portuguese | Talk track, timing budget and Q&A bank. |

**Why the speaker notes exist only in Portuguese:** they are a working tool for a talk delivered in
Portuguese — sentences written to be spoken aloud, with the anchor phrase per slide. An English
translation would be a document nobody uses. The slides themselves exist in both languages because
those are the artifact people look at.

Both decks share a byte-identical stylesheet, so a change to one must be mirrored in the other.

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

## Before presenting

- [ ] Fill in the group member names on slide 1 of **both** decks.
- [ ] Run the pipeline on AWS and confirm `docs/evidence/query-cost.json` reports
      `cost_usd = 0.00004768`. If the real figure differs, update slide 8, `DECISOES.md`
      and `DECISIONS.md`.
- [ ] Check slide 7 against `docs/evidence/business-question-result.csv` — the 12-month window is
      relative to `current_date`, so values can shift between runs.
- [ ] `verificacao/verifica.sh` with credentials → 25/25 PASSA, and keep the output.
- [ ] Record a fallback video of apply → ingest → query → destroy, in case the live demo fails.
- [ ] Rehearse with a timer at least once. Five minutes is a hard cutoff.
