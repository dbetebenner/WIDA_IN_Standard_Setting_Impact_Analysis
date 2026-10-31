# WIDA_IN_Standard_Setting_Impact_Analysis

Part of Damian Betebenner's talks: <https://dbetebenner.github.io/talks/>

Presentation for the Indiana Department of Education (Office of English Learners &
Multilingual Education) on how WIDA's 2026&ndash;27 proficiency levels change English
learner exit eligibility in Indiana.

The deck answers three questions:

1. Do the new standards dramatically change the rate at which students exit, overall and
   by grade?
2. If so, what new-PL cuts would keep today's exit percentages?
3. Is a single cut for all grades tenable on the new vertical scale?

It also tests the hypothesis that the grade 4&ndash;5 cuts had to rise for the composite
scale to stay vertical.

The rendered deck is `docs/index.html` (self-contained), served by GitHub Pages from
`main` → `/docs` at
<https://dbetebenner.github.io/WIDA_IN_Standard_Setting_Impact_Analysis/>.

## Method in one paragraph

WIDA's October 2026 concordance gives, for every grade and every new-scale composite score
(100&ndash;600), the proficiency level under the current standards (2025&ndash;26 PLs) and
under the new standards (2026&ndash;27 PLs). For 2026, Indiana's reported PL matches the
concordance's current-standard PL for every student, so the comparison is exact: the same
scores, classified two ways. For 2024 and 2025, scores are first converted to the new
scale with `widaACCESS_2026_scale_score_transformation()` (rounded half up), the reported
PL is used as the current-standard PL, and the new PL is looked up. Indiana's exit rule is
applied to both: auto-exit at PL 5.0 or higher (K&ndash;12), and a review band at
4.3&ndash;4.9 for grades 3 and up. Rate-preserving cuts are the new-PL value, on a 0.1
grid, whose at-or-above share is closest to the current-standard share. They are computed
by grade, by grade band, and statewide, for each year and pooled over 2024&ndash;2026.

## Pipeline

```
R/00_helpers.R               constants, concordance reader, exit classification, suppression, formatters
R/01_concordance_summary.R   -> summary/concordance_summary.rds   (cut ladders, cut deltas, articulation)
R/02_impact_summary.R        -> summary/in_wida_impact_summary.rds (aggregate impact tables, cuts, options)
WIDA_IN_Standard_Setting_Impact.qmd   reads only the two .rds caches
```

Build:

```sh
make            # caches (if missing) + render to docs/index.html
make force      # rebuild caches from source data, then render
./render.sh [--force]   # same, without make
```

Quarto may need to run outside a restricted sandbox (it calls `sysctl`).

### Inputs (environment variables, with defaults in `R/00_helpers.R`)

| Variable | What it points to |
|---|---|
| `WIDA_CONCORDANCE_XLSX` | WIDA's concordance workbook (`Data/*.xlsx`, not committed) |
| `WIDA_IN_DATA_DIR` | Directory holding `WIDA_IN_Data_LONG_{2024,2025,2026}.Rdata` |
| `WIDA_SCALE_XFORM` | Source of `widaACCESS_2026_scale_score_transformation()` |
| `ILEARN_EXIT_CSV` | Aggregate ILEARN exit-consistency table (`exit_grade_consistency.csv`) |

## Decisions recorded in the deck

- Policy modelled: 5.0 auto-exit K&ndash;12 plus the 4.3&ndash;4.9 review band for grades
  3&ndash;12 (IDOE's current rule).
- Historical robustness: 2024 and 2025 are re-scored under the new standards.
- Options presented: A (keep 5.0 / 4.3 on the new PLs), B (grade-specific rate-preserving
  cuts), C (grade-band cuts).
- The presentation date is a placeholder: `date: 2026-11-01`, displayed as
  "Indiana Department of Education &middot; November 2026". Update it in the YAML header
  when the meeting is scheduled.

## Containment

- The student-level LONG files are read only by `R/02_impact_summary.R`, at run time. The
  caches and the deck hold **aggregates only**; no student IDs or rows are written.
- Counts from 1 to 9 are suppressed (shown as "&lt;10"); histogram bins with fewer than 10
  students are dropped.
- `*.Rdata`, the WIDA workbook (`Data/*.xlsx`), the `summary/*.rds` caches, and Quarto
  build directories are git-ignored. Rebuilding the deck therefore needs the source
  data; `make` regenerates the caches.
- The ILEARN input is the aggregate `outputs/exit_grade_consistency.csv` only; its
  student-level `cache/` is never read.
- The published deck's appendix reproduces WIDA's new-scale PL cut ladders; this was
  reviewed and kept deliberately (October 2026).

## Visual style

The deck uses the shared dataimago deck extension, vendored at `_extensions/dataimago/deck/`
from `NCIEA_Presentation_Template` (format `dataimago/deck-revealjs`). The extension
supplies the theme, the click-to-enlarge figure lightbox, the title-slide QR placement, and
the fonts (Josefin Sans, Noto Sans, Noto Sans Mono and Noto Sans Math, as local woff2 files
embedded in the rendered HTML, with no font CDN). The deck's own additions (timeline,
callout row, results tables) stay inline in the YAML header. The title-slide QR,
`assets/qr-deck.svg`, encodes the published deck URL.

Every figure carries `fig-alt` text describing what the chart shows. Figures use a
background of `#F6F6F5`, halfway between white and the slide background
(`rgb(237, 237, 235)`).
