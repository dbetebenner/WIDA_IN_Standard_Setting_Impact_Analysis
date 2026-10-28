### 01_concordance_summary.R
###
### Summarises the WIDA October 2026 concordance workbook (Overall composite)
### into summary/concordance_summary.rds. No student data is read.
###
###   * PL cut ladders: the lowest new-scale score reaching each PL threshold
###     (2.0–6.0 by 0.1), by grade, under the current (2025–26) and new
###     (2026–27) proficiency-level tables.
###   * Old-versus-new cut deltas at the Indiana policy thresholds (4.3, 5.0).
###   * The new-PL equivalent of each current cut (what the new PL reads at
###     the score where the current PL first reaches 4.3 / 5.0), and vice versa.
###   * Vertical articulation checks: grade-to-grade dips in each cut series.
###
###   Rscript R/01_concordance_summary.R [--force]

this_dir <- tryCatch({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  if (length(file_arg)) dirname(normalizePath(file_arg)) else file.path(getwd(), "R")
}, error = function(e) file.path(getwd(), "R"))
PROJECT_ROOT <- normalizePath(file.path(this_dir, ".."))
source(file.path(this_dir, "00_helpers.R"))

XLSX_PATH  <- input_path("WIDA_CONCORDANCE_XLSX", default_concordance_xlsx(PROJECT_ROOT))
CACHE_PATH <- file.path(PROJECT_ROOT, "summary", "concordance_summary.rds")
FORCE <- any(commandArgs(trailingOnly = TRUE) %in% c("--force", "-f"))

if (!FORCE && file.exists(CACHE_PATH) && file.exists(XLSX_PATH) &&
    file.mtime(CACHE_PATH) > file.mtime(XLSX_PATH) &&
    file.mtime(CACHE_PATH) > file.mtime(file.path(this_dir, "00_helpers.R")) &&
    file.mtime(CACHE_PATH) > file.mtime(file.path(this_dir, "01_concordance_summary.R"))) {
  message("Cache is up to date (", CACHE_PATH, "). Use --force to rebuild.")
  quit(save = "no", status = 0)
}

message("Reading concordance: ", XLSX_PATH)
cc <- read_concordance(XLSX_PATH)
message("  ", nrow(cc), " rows, grades ", paste(range(as.integer(cc$GRADE)), collapse = "–"))

pl_steps <- sort(unique(c(diff(sort(unique(cc$PL_OLD))), diff(sort(unique(cc$PL_NEW))))))
if (any(abs(pl_steps - round(pl_steps, 1)) > 1e-9)) {
  warning("PL columns are not on a 0.1 grid; ladders may be approximate.")
}

## ---------------------------------------------------------------------------
## Ladders
## ---------------------------------------------------------------------------

ladder <- cut_ladder(cc, PL_GRID)

## Old-scale score at the current-standard cut (for reference against
## SGPstateData[["WIDA_IN"]] cuts).
ladder_old_scale <- cc[, .(THRESHOLD = PL_GRID,
                           CUT_SS_OLD = vapply(PL_GRID, function(t) {
                             hit <- SS_OLD[PL_OLD >= t - 1e-9]
                             if (length(hit)) min(hit) else NA_real_
                           }, numeric(1))), by = GRADE]

## ---------------------------------------------------------------------------
## Policy cuts and equivalents
## ---------------------------------------------------------------------------

POLICY_THRESHOLDS <- c(REVIEW_LOW_PL, EXIT_AUTO_PL)

policy_cuts <- dcast(ladder[THRESHOLD %in% POLICY_THRESHOLDS],
                     GRADE + THRESHOLD ~ STANDARD, value.var = "CUT_SS_NEW")
setnames(policy_cuts, c("OLD", "NEW"), c("CUT_OLD", "CUT_NEW"))
policy_cuts[, DELTA := CUT_NEW - CUT_OLD]
## New PL a student scoring exactly at the current cut would receive, and the
## current PL a student at the new cut would have received.
policy_cuts[, NEW_PL_AT_OLD_CUT := pl_at(cc, GRADE, CUT_OLD, "NEW")]
policy_cuts[, OLD_PL_AT_NEW_CUT := pl_at(cc, GRADE, CUT_NEW, "OLD")]
policy_cuts <- merge(policy_cuts,
                     ladder_old_scale[THRESHOLD %in% POLICY_THRESHOLDS],
                     by = c("GRADE", "THRESHOLD"), all.x = TRUE)
policy_cuts[, GRADE_LABEL := pretty_grade(GRADE)]
policy_cuts <- policy_cuts[order(THRESHOLD, as.integer(GRADE))]

## ---------------------------------------------------------------------------
## Vertical articulation: grade-to-grade decreases in each cut series
## ---------------------------------------------------------------------------

articulation <- ladder[THRESHOLD %in% c(2, 3, 4, POLICY_THRESHOLDS, 6)][
  order(STANDARD, THRESHOLD, as.integer(GRADE))][
  , .(GRADE, CUT_SS_NEW, STEP = c(NA_real_, diff(CUT_SS_NEW))), by = .(STANDARD, THRESHOLD)]
articulation[, DIP := !is.na(STEP) & STEP < 0]
articulation_summary <- articulation[, .(
  n_dips    = sum(DIP),
  dip_grades = paste(pretty_grade(GRADE[DIP]), collapse = ", "),
  max_dip   = if (any(DIP)) min(STEP[DIP]) else 0
), by = .(STANDARD, THRESHOLD)]

## ---------------------------------------------------------------------------
## Meta + write
## ---------------------------------------------------------------------------

meta <- list(
  source_file   = basename(XLSX_PATH),
  source_mtime  = file.mtime(XLSX_PATH),
  sheet         = "Overall",
  grades        = sort(unique(as.integer(cc$GRADE))),
  ss_new_range  = range(cc$SS_NEW),
  pl_grid       = PL_GRID,
  policy        = list(auto = EXIT_AUTO_PL, review_low = REVIEW_LOW_PL,
                       review_min_grade = REVIEW_MIN_GRADE),
  max_pl_old    = cc[, .(max_pl = max(PL_OLD)), by = GRADE],
  max_pl_new    = cc[, .(max_pl = max(PL_NEW)), by = GRADE],
  generated_at  = Sys.time()
)

out <- list(
  meta                 = meta,
  ladder               = ladder,
  ladder_old_scale     = ladder_old_scale,
  policy_cuts          = policy_cuts,
  articulation         = articulation,
  articulation_summary = articulation_summary
)

dir.create(dirname(CACHE_PATH), showWarnings = FALSE, recursive = TRUE)
saveRDS(out, CACHE_PATH)
message("Wrote cache: ", CACHE_PATH, " (", round(file.size(CACHE_PATH) / 1024, 1), " KB)")

options(width = 200)
message("\nPolicy cuts (new-scale SS) — current vs new standards:")
print(as.data.frame(policy_cuts[, .(THRESHOLD, GRADE_LABEL, CUT_OLD, CUT_NEW, DELTA,
                                    NEW_PL_AT_OLD_CUT, OLD_PL_AT_NEW_CUT, CUT_SS_OLD)]),
      row.names = FALSE)
message("\nGrade-to-grade dips in the cut series:")
print(as.data.frame(articulation_summary), row.names = FALSE)
