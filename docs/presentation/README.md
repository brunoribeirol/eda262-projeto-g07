# Presentation — EDA262, group g07

| File | Part | Language | Purpose |
|---|---|---|---|
| `apresentacao-parte-2-g07.html` | 2 (AV2) | Portuguese | Source for the **Part 2 delivered PDF**. The filename is mandated by the course guide. |
| `presentation-part-2-g07.html` | 2 (AV2) | English | Portfolio version. Identical design and numbers. |
| `apresentacao-parte-1-g07.html` | 1 (AV1) | Portuguese | Source of the delivered AV1 PDF (tag `av1-entrega`). |
| `presentation-part-1-g07.html` | 1 (AV1) | English | Portfolio version of AV1. |
| `img/demo-*.png` | 1 (AV1) | — | Terminal screenshots of the AV1 run used on its slide 7. |

Within each part, the Portuguese and English decks share a **byte-identical stylesheet**, so a change
to one must be mirrored in the other. The Part 2 stylesheet is the Part 1 one plus three additions
(bar-chart side column, access matrix, terminal panels).

---

## Part 2 deck — structure

Nine slides for the five-minute hard cutoff (~33 s each). The HTML comment above every slide names
its presenter, so each member defends at least one decision (the guide's individual defense):

| # | Slide | Presenter | Guide item |
|---|---|---|---|
| 1 | Cover: the business question as the title | Bruno | Scenario |
| 2 | Why EPSS: Part 1 sat below the 10 MB billing floor; 80.9 MB in 30 days | Bruno | Scenario and question |
| 3 | Architecture: collect → raw → trusted → refined, 73 resources | Emanuel | Architecture |
| 4 | Partitioning (29×) and idempotency (391,915 → 391,915) | Igor · Leonardo | Decisions |
| 5 | Lake Formation: 3×3 matrix, 9 of 9 measured | Emanuel | Layers + access |
| 6 | The answer: Microsoft leads volume, Ivanti leads probability (0.82) | Victor | Question answered |
| 7 | Cost target met: 162,943 B, US$ 0.00004768, raw vs trusted vs refined | Vinícius | Measured cost |
| 8 | Demo: real terminal output of the 2026-10-20 run | Vinícius | Demo |
| 9 | Every decision with its number, product angle | Bruno | Decisions |

Every figure comes from the AWS run of **2026-10-20** recorded in `docs/evidence/part-2/` and in
`DECISOES.md` (decisions 11–24). Slide 8 shows the exact terminal lines of that run (only wrapped
to fit); the line that prints the Lake Formation administrator ARN is left out because it contains
the AWS account ID — the same reason the AV1 destroy capture was cropped.

**Precision on slide 6:** the ranking counts exploited CVEs *added in the last 12 months*; the
EPSS column averages *all* of each vendor's exploited CVEs (an old exploited CVE stays a risk while
unpatched systems exist). The chart note says so on the slide.

---

## Design constraints (from the course guide)

Non-negotiable, applied to both parts:

- Arial, one title per slide, ~5 bullets maximum
- Orange as accent only, used sparingly
- Square bullets
- No 3D, no shadows, no generic stock imagery
- Monochrome charts with the main series in orange

---

## Generating the PDFs

```bash
scripts/build_pdf.sh             # Part 2 decks (default): apresentacao-parte-2-g07.pdf + EN
scripts/build_pdf.sh --part 1    # re-render the AV1 decks
```

It picks up Chrome, Chromium or Edge automatically and checks one page per slide (9 for Part 2).
It does not run inside the Claude Code sandbox (Chrome needs to bind a local socket) — run it in
your own terminal.

**Printing manually from Chrome (Cmd+P):** set margins to *None* and **enable "Background
graphics"** — otherwise the orange bars and accent rules disappear. The page box is
13.333in × 7.5in (16:9).

---

## Delivery record

- **Part 1:** presented and submitted on 2026-10-05; delivered deck `apresentacao-parte-1-g07.pdf`
  at the signed tag `av1-entrega`.
- **Part 2:** due 2026-11-30 (Aula 30). Deck drafted on 2026-10-20 from the first AWS run.
- Talk tracks (`speaker-notes*.pt-BR.md`) are gitignored on purpose and live only locally.

## Before presenting Part 2

- [ ] Run the incremental loads until close to the date, then refresh the numbers that move with
      the data (slides 2, 4, 6, 7, 8) from `docs/evidence/part-2/` — or keep the 2026-10-20 run and
      say so on the slide, as AV1 did.
- [ ] Final cycle, in this order (the AWS criteria need the resources to exist, decision 24 needs a
      destroy to have happened):
      1. `scripts/part-2/destroy.sh` — tears down the long-running lake; fill decision 24 in
         `DECISOES.md` with its orphan check.
      2. `scripts/part-2/run_all.sh --days 30` — apply **from zero**, load, query, proofs, verifica:
         now **39 PASSA** (PDF rendered, no unmeasured number left).
      3. `scripts/part-2/destroy.sh` again — the recorded "destroy with 0 orphans" for the demo.
      Capture apply / query / verifica / destroy (screenshots or terminal text) for slide 8.
- [ ] Render with `scripts/build_pdf.sh` and confirm 9 pages each.
- [ ] Rehearse with a timer: five minutes is a hard cutoff; each member should be able to defend
      any decision in `DECISOES.md` (the professor picks one at random).
