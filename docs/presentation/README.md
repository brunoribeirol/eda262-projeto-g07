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

Eight slides for the five-minute hard cutoff (~37 s each). The HTML comment above every slide names
its presenter, so each member defends at least one decision (the guide's individual defense):

| # | Slide | Presenter | Guide item |
|---|---|---|---|
| 1 | Cover: the business question as the title | Bruno | Scenario |
| 2 | Why EPSS: Part 1 sat below the 10 MB billing floor; 84.9 MB in 30 days | Bruno | Scenario and question |
| 3 | Architecture: collect → raw → trusted → refined, 74 resources | Emanuel | Architecture |
| 4 | Lake Formation: 3×3 matrix, 9 of 9 measured; 9 of 9 direct S3 reads denied | Emanuel | Layers + access |
| 5 | Partitioning (29×) and idempotency (411,908 → 411,908) | Igor · Leonardo | Decisions |
| 6 | The answer: Microsoft leads volume, Ivanti leads probability in the top 10 (0.81 vs Apple 0.14) | Victor | Question answered |
| 7 | Cost target in bytes: 167,244 B against 491,520 B, raw vs trusted vs refined | Vinícius | Measured cost |
| 8 | Demo: real terminal output of the reference run (apply, backfill, query on three layers, acceptance + destroy) | Vinícius | Demo |

Every figure comes from the reference run **`20261126T150713Z`** recorded in
`docs/evidence/part-2/` and in `DECISOES.md` (decisions 11–26); `scripts/part-2/check_evidence_sync.sh`
compares the numbers it tracks on both decks with that evidence. Slide 8 shows the exact terminal lines of that run (only wrapped
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
- **Part 2:** delivered and presented on 2026-12-02 (moved from 2026-11-30, Aula 30, by the
  professor in class on 2026-11-17). Every number on the deck comes from the reference run `20261126T150713Z`, which
  closed with `verify_run.sh` 48/0 and `destroy.sh` 74 destroyed, 0 orphans.
- Talk tracks (`speaker-notes*.pt-BR.md`) are gitignored on purpose and live only locally.

## Before presenting Part 2

- [x] Reference run, in this order: destroy -> `run_all.sh --yes --days 30 --to 2026-11-24` (apply
      from zero) -> documents updated -> `verify_run.sh` 48/0 -> `destroy.sh` 0 orphans
      (2026-11-26; the window stops before EPSS's level shift of 2026-11-25, decision 26). Re-running `run_all.sh` replaces every per-run evidence file
      with a new run id, so it is only done again on purpose, followed by the same document pass.
- [x] Render with `scripts/build_pdf.sh` and confirm 8 pages each.
- [ ] Rehearse with a timer: five minutes is a hard cutoff; each member should be able to defend
      any decision in `DECISOES.md` (the professor picks one at random).
