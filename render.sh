#!/usr/bin/env bash
#
# Build the Indiana WIDA ACCESS standard-setting impact deck end-to-end.
#
#   1. Summarise the WIDA October 2026 concordance workbook (no student data).
#   2. Summarise Indiana exit-band rates under old and new standards
#      (reads the WIDA_IN LONG files; writes aggregates only).
#   3. Render the self-contained reveal.js HTML.
#
# Usage:
#   ./render.sh                 # incremental: rebuild caches only if inputs changed
#   ./render.sh --force         # force cache rebuild, then render
#
# Input locations may be overridden with environment variables:
#   WIDA_CONCORDANCE_XLSX   path to the WIDA concordance workbook
#   WIDA_IN_DATA_DIR        directory holding WIDA_IN_Data_LONG_<year>.Rdata
#   WIDA_SCALE_XFORM        path to widaACCESS_2026_scale_score_transformation.R
#   ILEARN_EXIT_CSV         path to the ILEARN x WIDA exit_grade_consistency.csv
#
set -euo pipefail

cd "$(dirname "$0")"

FORCE=""
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
  FORCE="--force"
fi

echo "==> [1/3] Summarising the concordance workbook"
Rscript R/01_concordance_summary.R ${FORCE}

echo "==> [2/3] Summarising exit impact (aggregates only)"
Rscript R/02_impact_summary.R ${FORCE}

echo "==> [3/3] Rendering deck"
quarto render WIDA_IN_Standard_Setting_Impact.qmd --to revealjs
mkdir -p docs
mv -f index.html docs/index.html
rm -rf index_files            # self-contained deck; supporting dir not needed

echo "==> Done: docs/index.html"
