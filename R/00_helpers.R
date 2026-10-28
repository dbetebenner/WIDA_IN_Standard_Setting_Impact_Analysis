### 00_helpers.R
### Shared constants, concordance parser, exit classification and formatting
### helpers for the Indiana WIDA ACCESS 2026–27 standard-setting impact deck.
### Sourced by 01/02 and the Quarto deck.

suppressPackageStartupMessages({
  library(data.table)
})

## ---------------------------------------------------------------------------
## Indiana exit policy (current IDOE rule)
## ---------------------------------------------------------------------------

## Overall composite PL at or above 5.0 exits in every grade, K–12.
EXIT_AUTO_PL <- 5.0
## PL 4.3–4.9 in grades 3+ is review-eligible (ILP committee decision).
REVIEW_LOW_PL <- 4.3
REVIEW_MIN_GRADE <- 3L

EXIT_LEVELS <- c("Retained (< review)", "Review-eligible (4.3-4.9)", "Auto-exit (>= 5.0)")
EXIT_LABELS <- c("Retained", "Review-eligible (4.3–4.9)", "Auto-exit (5.0+)")

GRADES <- as.character(0:12)
GRADE_BANDS <- list(
  "K–2"  = as.character(0:2),
  "3–5"  = as.character(3:5),
  "6–8"  = as.character(6:8),
  "9–12" = as.character(9:12)
)

## PL thresholds tabulated in the ladders (2.0 to 6.0 by 0.1).
PL_GRID <- round(seq(2.0, 6.0, by = 0.1), 1)
## Candidate single cuts on the new PL scale for the policy curves.
CUT_GRID <- round(seq(4.0, 6.0, by = 0.1), 1)

SMALL_N <- 10L
HIST_BIN <- 5L

STANDARD_LABELS <- c(
  OLD = "Current standards (2025–26 PLs)",
  NEW = "New standards (2026–27 PLs)"
)

## ---------------------------------------------------------------------------
## Input locations (env-var overridable)
## ---------------------------------------------------------------------------

script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  if (length(file_arg)) dirname(normalizePath(file_arg)) else getwd()
}

input_path <- function(var, default) {
  p <- Sys.getenv(var, "")
  if (nzchar(p)) p else default
}

default_concordance_xlsx <- function(project_root) {
  file.path(project_root, "Data",
            "WIDA ACCESS Concordance Table - Updated October 2026.xlsx")
}

DEFAULT_WIDA_IN_DATA_DIR <- "/Users/conet/GitHub/CenterForAssessment/WIDA_IN/master/Data"
DEFAULT_WIDA_SCALE_XFORM <- "/Users/conet/GitHub/DBetebenner/SGPstateData/master/Custom_Functions_Misc/WIDA/widaACCESS_2026_scale_score_transformation.R"
DEFAULT_ILEARN_EXIT_CSV  <- "/Users/conet/GitHub/SGP_Sandbox/IN_ILEARN_WIDA_ACCESS_analysis_2026/outputs/exit_grade_consistency.csv"

## ---------------------------------------------------------------------------
## Concordance
## ---------------------------------------------------------------------------

## Parse the "Overall" sheet of the WIDA October 2026 concordance workbook.
## The sheet holds 13 side-by-side five-column blocks (one per grade K–12):
##   Grade | 2025_26 SS | 2024_25 SS | 2025_26 & 2024_25 PL | 2026_2027 PL
## Row 1 is the header; each block has one row per new-scale score 100–600.
## Returns GRADE (character "0".."12"), SS_NEW, SS_OLD, PL_OLD, PL_NEW.
read_concordance <- function(path, sheet = "Overall") {
  if (!requireNamespace("readxl", quietly = TRUE)) stop("Package 'readxl' is required.")
  if (!file.exists(path)) stop("Concordance workbook not found: ", path)
  d <- as.data.frame(suppressMessages(
    readxl::read_excel(path, sheet = sheet, col_names = FALSE)))
  n_blocks <- ncol(d) %/% 5L
  if (n_blocks != 13L) stop("Expected 13 grade blocks in sheet '", sheet, "', found ", n_blocks)
  cc <- rbindlist(lapply(seq_len(n_blocks) - 1L, function(b) {
    x <- d[-1L, (b * 5L + 1L):(b * 5L + 5L)]
    names(x) <- c("GRADE", "SS_NEW", "SS_OLD", "PL_OLD", "PL_NEW")
    x
  }))
  for (k in names(cc)) set(cc, j = k, value = suppressWarnings(as.numeric(cc[[k]])))
  cc <- cc[!is.na(GRADE) & !is.na(SS_NEW)]
  cc[, GRADE := as.character(as.integer(GRADE))]
  cc[, `:=`(PL_OLD = round(PL_OLD, 1), PL_NEW = round(PL_NEW, 1))]
  setkey(cc, GRADE, SS_NEW)

  ## Structural checks: complete grid, monotone within grade.
  bad_grid <- cc[, .(ok = .N == 501L && min(SS_NEW) == 100 && max(SS_NEW) == 600), by = GRADE][ok == FALSE]
  if (nrow(bad_grid)) stop("Concordance grid incomplete for grades: ", paste(bad_grid$GRADE, collapse = ", "))
  mono <- cc[, .(ss = all(diff(SS_OLD) >= 0), po = all(diff(PL_OLD) >= 0),
                 pn = all(diff(PL_NEW) >= 0)), by = GRADE]
  if (!all(unlist(mono[, .(ss, po, pn)]))) stop("Concordance is not monotone within grade.")
  cc[]
}

## Lowest new-scale score at which a PL column reaches threshold t, by grade.
## NA when the threshold is never reached on the 100–600 grid.
cut_ladder <- function(cc, thresholds = PL_GRID) {
  out <- rbindlist(lapply(c("OLD", "NEW"), function(std) {
    col <- paste0("PL_", std)
    cc[, {
      pl <- get(col)
      .(THRESHOLD = thresholds,
        CUT_SS_NEW = vapply(thresholds, function(t) {
          hit <- SS_NEW[pl >= t - 1e-9]
          if (length(hit)) min(hit) else NA_real_
        }, numeric(1)))
    }, by = GRADE][, STANDARD := std]
  }))
  setcolorder(out, c("GRADE", "STANDARD", "THRESHOLD", "CUT_SS_NEW"))
  out[order(as.integer(GRADE), STANDARD, THRESHOLD)]
}

## PL on a given standard at a new-scale score (vectorised over grade + score).
pl_at <- function(cc, grade, ss_new, standard = c("NEW", "OLD")) {
  standard <- match.arg(standard)
  key <- data.table(GRADE = as.character(grade), SS_NEW = as.numeric(ss_new))
  cc[key, on = .(GRADE, SS_NEW), get(paste0("PL_", standard))]
}

## ---------------------------------------------------------------------------
## Exit classification (matches the WIDA_SCALE_SCORE_TRANSITION_2026 sandbox)
## ---------------------------------------------------------------------------

classify_exit <- function(pl, grade) {
  grade <- as.integer(grade)
  out <- rep(EXIT_LEVELS[1], length(pl))
  review <- !is.na(pl) & pl >= REVIEW_LOW_PL - 1e-9 & pl < EXIT_AUTO_PL - 1e-9 &
    grade >= REVIEW_MIN_GRADE
  out[review] <- EXIT_LEVELS[2]
  out[!is.na(pl) & pl >= EXIT_AUTO_PL - 1e-9] <- EXIT_LEVELS[3]
  out[is.na(pl)] <- NA_character_
  factor(out, levels = EXIT_LEVELS)
}

## Rates for one standard's PL column, by `by`. "Exit region" = review + auto.
## The 4.3+ share is reported for every grade (descriptive) but only counts as
## review-eligible in grades 3+.
exit_rates <- function(dt, pl_col, by) {
  dt[!is.na(get(pl_col)), {
    pl <- get(pl_col)
    cls <- classify_exit(pl, GRADE)
    .(n            = .N,
      n_auto       = sum(cls == EXIT_LEVELS[3]),
      n_review     = sum(cls == EXIT_LEVELS[2]),
      n_ge43       = sum(pl >= REVIEW_LOW_PL - 1e-9),
      pct_auto     = 100 * mean(cls == EXIT_LEVELS[3]),
      pct_review   = 100 * mean(cls == EXIT_LEVELS[2]),
      pct_region   = 100 * mean(cls != EXIT_LEVELS[1]),
      pct_ge43     = 100 * mean(pl >= REVIEW_LOW_PL - 1e-9))
  }, by = by]
}

## ---------------------------------------------------------------------------
## Labels
## ---------------------------------------------------------------------------

pretty_grade <- function(grade) {
  g <- as.character(grade)
  fifelse(g == "0", "K", g)
}

grade_factor <- function(grade) {
  factor(pretty_grade(grade), levels = pretty_grade(GRADES))
}

grade_band_of <- function(grade) {
  g <- as.character(grade)
  out <- rep(NA_character_, length(g))
  for (b in names(GRADE_BANDS)) out[g %in% GRADE_BANDS[[b]]] <- b
  factor(out, levels = names(GRADE_BANDS))
}

## ---------------------------------------------------------------------------
## Suppression
## ---------------------------------------------------------------------------

## Mask statistics in rows whose count is below SMALL_N. `n_cols` names the
## count columns that trigger masking; every other numeric column in those rows
## (and the triggering counts themselves when `mask_counts = TRUE`) becomes NA.
suppress_small <- function(dt, n_cols = "n", min_n = SMALL_N, mask_counts = FALSE) {
  if (!nrow(dt)) return(invisible(dt))
  small <- Reduce(`|`, lapply(n_cols, function(col) {
    if (!col %in% names(dt)) return(rep(FALSE, nrow(dt)))
    !is.na(dt[[col]]) & dt[[col]] > 0 & dt[[col]] < min_n
  }))
  if (!any(small)) return(invisible(dt))
  num_cols <- names(dt)[vapply(dt, is.numeric, logical(1))]
  mask_cols <- if (mask_counts) num_cols else setdiff(num_cols, n_cols)
  for (col in mask_cols) set(dt, i = which(small), j = col, value = NA_real_)
  invisible(dt)
}

## Mask individual small counts (e.g. lose/gain cells) without touching the row.
mask_small_counts <- function(dt, cols, min_n = SMALL_N) {
  for (col in intersect(cols, names(dt))) {
    v <- dt[[col]]
    set(dt, i = which(!is.na(v) & v > 0 & v < min_n), j = col, value = NA_real_)
  }
  invisible(dt)
}

## ---------------------------------------------------------------------------
## Formatting
## ---------------------------------------------------------------------------

fmt_count <- function(n) {
  vapply(n, function(x) {
    if (is.na(x)) return("&lt;10")
    formatC(as.numeric(x), format = "d", big.mark = ",")
  }, character(1))
}

fmt_pct <- function(p, digits = 1) {
  vapply(p, function(x) {
    if (is.na(x)) return("&mdash;")
    paste0(formatC(round(x, digits), format = "f", digits = digits), "%")
  }, character(1))
}

fmt_pl <- function(p) {
  vapply(p, function(x) {
    if (is.na(x)) return("&mdash;")
    formatC(x, format = "f", digits = 1)
  }, character(1))
}

fmt_signed <- function(x, digits = 1, suffix = "") {
  vapply(x, function(v) {
    if (is.na(v)) return("&mdash;")
    s <- formatC(abs(round(v, digits)), format = "f", digits = digits, big.mark = ",")
    sign <- if (round(v, digits) > 0) "+" else if (round(v, digits) < 0) "&minus;" else ""
    paste0(sign, s, suffix)
  }, character(1))
}

## Plain-text variants for ggplot labels (no HTML entities).
txt_pct <- function(p, digits = 1) {
  ifelse(is.na(p), "", paste0(formatC(round(p, digits), format = "f", digits = digits), "%"))
}
