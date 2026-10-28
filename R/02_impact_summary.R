### 02_impact_summary.R
###
### Classifies Indiana WIDA ACCESS composite scores under the current
### (2025–26) and new (2026–27) proficiency-level tables and writes an
### AGGREGATE-ONLY cache: summary/in_wida_impact_summary.rds.
###
### Student-level LONG files are read once, in memory, and never written out.
### No IDs, school or district identifiers leave this script; cells, bins and
### counts with 0 < N < 10 are masked.
###
###   2026       : new-scale scores; PL_OLD and PL_NEW are exact concordance
###                lookups (PL_OLD reproduces the reported PL for every student).
###   2024, 2025 : old-scale scores; the current-standard PL is the operational
###                ACHIEVEMENT_LEVEL_ORIGINAL. The new-standard PL is obtained by
###                converting each score OLD -> NEW with the production
###                widaACCESS_2026_scale_score_transformation(), rounding half up
###                to an integer new-scale score, and looking up PL_NEW.
###
###   Rscript R/02_impact_summary.R [--force]

this_dir <- tryCatch({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  if (length(file_arg)) dirname(normalizePath(file_arg)) else file.path(getwd(), "R")
}, error = function(e) file.path(getwd(), "R"))
PROJECT_ROOT <- normalizePath(file.path(this_dir, ".."))
source(file.path(this_dir, "00_helpers.R"))
options(width = 200, max.print = 10000)

XLSX_PATH  <- input_path("WIDA_CONCORDANCE_XLSX", default_concordance_xlsx(PROJECT_ROOT))
DATA_DIR   <- input_path("WIDA_IN_DATA_DIR", DEFAULT_WIDA_IN_DATA_DIR)
XFORM_PATH <- input_path("WIDA_SCALE_XFORM", DEFAULT_WIDA_SCALE_XFORM)
ILEARN_CSV <- input_path("ILEARN_EXIT_CSV", DEFAULT_ILEARN_EXIT_CSV)
YEARS      <- c("2024", "2025", "2026")
CURRENT_YEAR <- "2026"
CACHE_PATH <- file.path(PROJECT_ROOT, "summary", "in_wida_impact_summary.rds")
FORCE <- any(commandArgs(trailingOnly = TRUE) %in% c("--force", "-f"))

long_path <- function(y) file.path(DATA_DIR, sprintf("WIDA_IN_Data_LONG_%s.Rdata", y))
inputs <- c(XLSX_PATH, XFORM_PATH, vapply(YEARS, long_path, character(1)),
            file.path(this_dir, c("00_helpers.R", "02_impact_summary.R")))
missing <- inputs[!file.exists(inputs)]
if (length(missing)) stop("Missing inputs:\n  ", paste(missing, collapse = "\n  "))

if (!FORCE && file.exists(CACHE_PATH) &&
    all(file.mtime(CACHE_PATH) > file.mtime(inputs))) {
  message("Cache is up to date (", CACHE_PATH, "). Use --force to rebuild.")
  quit(save = "no", status = 0)
}

t0 <- Sys.time()
cc <- read_concordance(XLSX_PATH)
xform_env <- new.env()
sys.source(XFORM_PATH, envir = xform_env)
old_to_new <- function(grade, ss_old) {
  x <- xform_env$widaACCESS_2026_scale_score_transformation(
    grade = as.character(grade), scale_score = ss_old, direction = "OLD_to_NEW")
  floor(as.numeric(x) + 0.5)
}

## ---------------------------------------------------------------------------
## Load + classify (student-level data stays inside this block)
## ---------------------------------------------------------------------------

load_year <- function(y) {
  e <- new.env()
  load(long_path(y), envir = e)
  d <- as.data.table(get(ls(e)[1], envir = e))
  rm(e)
  d <- d[VALID_CASE == "VALID_CASE",
         intersect(c("GRADE", "SCALE_SCORE", "ACHIEVEMENT_LEVEL_ORIGINAL",
                     "SCALE_SCORE_OLD_SCALE"), names(d)), with = FALSE]
  d[, GRADE := as.character(as.integer(GRADE))]
  d[, YEAR := y]
  d
}

method_check <- NULL
long <- rbindlist(lapply(YEARS, function(y) {
  message("Loading ", y, " ...")
  d <- load_year(y)
  if (y == CURRENT_YEAR) {
    d[, SS_NEW := as.numeric(SCALE_SCORE)]
    d[, PL_REPORTED := round(as.numeric(ACHIEVEMENT_LEVEL_ORIGINAL), 1)]
    d[, PL_OLD := pl_at(cc, GRADE, SS_NEW, "OLD")]
    d[, PL_NEW := pl_at(cc, GRADE, SS_NEW, "NEW")]
    d[, PL_OLD_CHECK := PL_OLD]
    ## History-pathway check: apply the 2024/2025 method to the 2026 old-scale
    ## scores and compare against the exact new-scale lookup.
    if ("SCALE_SCORE_OLD_SCALE" %in% names(d)) {
      ss_hist <- old_to_new(d$GRADE, d$SCALE_SCORE_OLD_SCALE)
      pl_hist <- pl_at(cc, d$GRADE, ss_hist, "NEW")
      method_check <<- data.table(GRADE = d$GRADE, EXACT = d$PL_NEW, HIST = pl_hist)[
        , .(n = .N,
            pct_pl_exact  = 100 * mean(EXACT == HIST, na.rm = TRUE),
            pct_pl_within = 100 * mean(abs(EXACT - HIST) <= 0.1 + 1e-9, na.rm = TRUE),
            pct_exit_agree = 100 * mean(classify_exit(EXACT, GRADE) == classify_exit(HIST, GRADE), na.rm = TRUE),
            pct_auto_exact = 100 * mean(EXACT >= EXIT_AUTO_PL - 1e-9),
            pct_auto_hist  = 100 * mean(HIST >= EXIT_AUTO_PL - 1e-9, na.rm = TRUE)),
        by = GRADE]
    }
  } else {
    d[, SS_NEW := old_to_new(GRADE, SCALE_SCORE)]
    d[, PL_REPORTED := round(as.numeric(ACHIEVEMENT_LEVEL_ORIGINAL), 1)]
    d[, PL_OLD := PL_REPORTED]
    d[, PL_NEW := pl_at(cc, GRADE, SS_NEW, "NEW")]
    ## Round-trip: current-standard PL looked up at the converted score should
    ## reproduce the operational PL.
    d[, PL_OLD_CHECK := pl_at(cc, GRADE, SS_NEW, "OLD")]
  }
  d[, .(YEAR, GRADE, SS_NEW, PL_REPORTED, PL_OLD, PL_NEW, PL_OLD_CHECK)]
}))
message("  loaded ", format(nrow(long), big.mark = ","), " valid records in ",
        round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "s")
if (long[, anyNA(PL_NEW)]) stop("Unmatched new-scale scores: ", long[is.na(PL_NEW), .N])

long[, EXIT_OLD := classify_exit(PL_OLD, GRADE)]
long[, EXIT_NEW := classify_exit(PL_NEW, GRADE)]
long[, BAND := grade_band_of(GRADE)]

## ---------------------------------------------------------------------------
## Validation
## ---------------------------------------------------------------------------

validation <- long[, .(
  n               = .N,
  pct_pl_match    = 100 * mean(PL_OLD_CHECK == PL_REPORTED, na.rm = TRUE),
  pct_pl_within01 = 100 * mean(abs(PL_OLD_CHECK - PL_REPORTED) <= 0.1 + 1e-9, na.rm = TRUE),
  pct_exit_match  = 100 * mean(classify_exit(PL_OLD_CHECK, GRADE) == EXIT_OLD, na.rm = TRUE)
), by = .(YEAR, GRADE)][order(YEAR, as.integer(GRADE))]
validation_state <- long[, .(
  n               = .N,
  pct_pl_match    = 100 * mean(PL_OLD_CHECK == PL_REPORTED, na.rm = TRUE),
  pct_pl_within01 = 100 * mean(abs(PL_OLD_CHECK - PL_REPORTED) <= 0.1 + 1e-9, na.rm = TRUE),
  pct_exit_match  = 100 * mean(classify_exit(PL_OLD_CHECK, GRADE) == EXIT_OLD, na.rm = TRUE)
), by = YEAR][order(YEAR)]
if (!is.null(method_check)) method_check <- method_check[order(as.integer(GRADE))]

## ---------------------------------------------------------------------------
## Rates by year x grade x standard, statewide, and by band
## ---------------------------------------------------------------------------

rates_std <- function(by) {
  r <- rbind(exit_rates(long, "PL_OLD", by)[, STANDARD := "OLD"],
             exit_rates(long, "PL_NEW", by)[, STANDARD := "NEW"])
  setcolorder(r, c(by, "STANDARD"))
  r[]
}

rates <- rates_std(c("YEAR", "GRADE"))[order(YEAR, as.integer(GRADE), -rank(STANDARD))]
rates_band <- rates_std(c("YEAR", "BAND"))[order(YEAR, BAND)]
rates_state <- rates_std("YEAR")[order(YEAR)]
## Grades 3+ only (where the review band applies).
long_g3 <- long[as.integer(GRADE) >= REVIEW_MIN_GRADE]
rates_state_g3 <- rbind(exit_rates(long_g3, "PL_OLD", "YEAR")[, STANDARD := "OLD"],
                        exit_rates(long_g3, "PL_NEW", "YEAR")[, STANDARD := "NEW"])[order(YEAR)]

## Wide by grade for tables / dumbbells.
rates_wide <- dcast(rates, YEAR + GRADE ~ STANDARD,
                    value.var = c("n", "n_auto", "n_review", "pct_auto", "pct_review",
                                  "pct_region", "pct_ge43"))
rates_wide[, n := n_OLD][, c("n_OLD", "n_NEW") := NULL]
rates_wide[, `:=`(d_auto = pct_auto_NEW - pct_auto_OLD,
                  d_region = pct_region_NEW - pct_region_OLD,
                  d_ge43 = pct_ge43_NEW - pct_ge43_OLD)]
rates_wide <- rates_wide[order(YEAR, as.integer(GRADE))]

## ---------------------------------------------------------------------------
## Who changes status
## ---------------------------------------------------------------------------

transitions <- long[, .(
  n            = .N,
  lose_auto    = sum(EXIT_OLD == EXIT_LEVELS[3] & EXIT_NEW != EXIT_LEVELS[3]),
  gain_auto    = sum(EXIT_OLD != EXIT_LEVELS[3] & EXIT_NEW == EXIT_LEVELS[3]),
  lose_region  = sum(EXIT_OLD != EXIT_LEVELS[1] & EXIT_NEW == EXIT_LEVELS[1]),
  gain_region  = sum(EXIT_OLD == EXIT_LEVELS[1] & EXIT_NEW != EXIT_LEVELS[1]),
  same_status  = sum(EXIT_OLD == EXIT_NEW),
  mean_pl_shift = mean(PL_NEW - PL_OLD)
), by = .(YEAR, GRADE)][order(YEAR, as.integer(GRADE))]
mask_small_counts(transitions, c("lose_auto", "gain_auto", "lose_region", "gain_region"))

crosstab <- long[, .(n = .N), by = .(YEAR, GRADE, EXIT_OLD, EXIT_NEW)]
crosstab <- crosstab[CJ(YEAR = YEARS, GRADE = GRADES, EXIT_OLD = factor(EXIT_LEVELS, EXIT_LEVELS),
                        EXIT_NEW = factor(EXIT_LEVELS, EXIT_LEVELS)),
                     on = .(YEAR, GRADE, EXIT_OLD, EXIT_NEW)]
crosstab[is.na(n), n := 0L]
crosstab <- crosstab[!(as.integer(GRADE) < REVIEW_MIN_GRADE &
                         (EXIT_OLD == EXIT_LEVELS[2] | EXIT_NEW == EXIT_LEVELS[2]))]
mask_small_counts(crosstab, "n")

## Distribution of the PL shift (new PL minus current PL), 2026.
pl_shift <- long[YEAR == CURRENT_YEAR, .(n = .N),
                 by = .(GRADE, SHIFT = round(PL_NEW - PL_OLD, 1))][order(as.integer(GRADE), SHIFT)]
mask_small_counts(pl_shift, "n")

## ---------------------------------------------------------------------------
## 2026 score distributions (5-point bins on the new scale)
## ---------------------------------------------------------------------------

hist_2026 <- long[YEAR == CURRENT_YEAR,
                  .(n = .N), by = .(GRADE, BIN = HIST_BIN * floor(SS_NEW / HIST_BIN))]
hist_2026[, pct := 100 * n / sum(n), by = GRADE]
setorder(hist_2026, GRADE, BIN)
hist_2026 <- hist_2026[order(as.integer(GRADE), BIN)]
suppress_small(hist_2026, "n", mask_counts = TRUE)

## ---------------------------------------------------------------------------
## Single new-PL cut curves
## ---------------------------------------------------------------------------

## Share at/above each candidate new-PL cut, by year and grade (and statewide).
cut_curve_grade <- long[, .(CUT = CUT_GRID,
                            n = .N,
                            pct_new = vapply(CUT_GRID, function(t) 100 * mean(PL_NEW >= t - 1e-9), numeric(1)),
                            n_new   = vapply(CUT_GRID, function(t) sum(PL_NEW >= t - 1e-9), numeric(1))),
                        by = .(YEAR, GRADE)]
cut_curve_state <- long[, .(CUT = CUT_GRID,
                            n = .N,
                            pct_new = vapply(CUT_GRID, function(t) 100 * mean(PL_NEW >= t - 1e-9), numeric(1)),
                            n_new   = vapply(CUT_GRID, function(t) sum(PL_NEW >= t - 1e-9), numeric(1))),
                        by = YEAR]
cut_curve_state <- merge(cut_curve_state,
                         rates_state[STANDARD == "OLD", .(YEAR, pct_auto_old = pct_auto, n_auto_old = n_auto)],
                         by = "YEAR")
cut_curve_g3 <- long_g3[, .(CUT = CUT_GRID,
                            pct_new = vapply(CUT_GRID, function(t) 100 * mean(PL_NEW >= t - 1e-9), numeric(1))),
                        by = YEAR]
cut_curve_g3 <- merge(cut_curve_g3,
                      rates_state_g3[STANDARD == "OLD", .(YEAR, pct_ge43_old = pct_ge43, pct_auto_old = pct_auto)],
                      by = "YEAR")

## ---------------------------------------------------------------------------
## Rate-preserving new-PL cuts
## ---------------------------------------------------------------------------

## For a group, the new-PL cut on a 0.1 grid whose at-or-above share is closest
## to the current-standard share at `old_threshold`. Ties go to the lower cut.
SEARCH_GRID <- round(seq(1.0, 6.0, by = 0.1), 1)
match_cut <- function(pl_old, pl_new, old_threshold) {
  target <- mean(pl_old >= old_threshold - 1e-9)
  shares <- vapply(SEARCH_GRID, function(t) mean(pl_new >= t - 1e-9), numeric(1))
  k <- which.min(abs(shares - target))
  list(pct_old = 100 * target, cut = SEARCH_GRID[k], pct_at_cut = 100 * shares[k],
       capped = k == length(SEARCH_GRID) && shares[k] > target)
}

rate_cuts <- function(dt, by, threshold) {
  dt[, c(list(n = .N), match_cut(PL_OLD, PL_NEW, threshold)), by = by]
}

THRESHOLDS <- c(AUTO = EXIT_AUTO_PL, REVIEW = REVIEW_LOW_PL)
pooled <- copy(long)[, YEAR := "2024–2026"]
long_pool <- rbind(long, pooled)

grade_cuts <- rbindlist(lapply(names(THRESHOLDS), function(k) {
  src <- if (k == "REVIEW") long_pool[as.integer(GRADE) >= REVIEW_MIN_GRADE] else long_pool
  rate_cuts(src, c("YEAR", "GRADE"), THRESHOLDS[[k]])[, `:=`(RULE = k, THRESHOLD = THRESHOLDS[[k]])]
}))[order(RULE, YEAR, as.integer(GRADE))]

band_cuts <- rbindlist(lapply(names(THRESHOLDS), function(k) {
  src <- if (k == "REVIEW") long_pool[as.integer(GRADE) >= REVIEW_MIN_GRADE] else long_pool
  rbind(rate_cuts(src, c("YEAR", "BAND"), THRESHOLDS[[k]]),
        rate_cuts(src, "YEAR", THRESHOLDS[[k]])[, BAND := if (k == "REVIEW") "Grades 3–12" else "K–12"],
        use.names = TRUE)[, `:=`(RULE = k, THRESHOLD = THRESHOLDS[[k]])]
}))
band_cuts[, BAND := factor(as.character(BAND), levels = c(names(GRADE_BANDS), "K–12", "Grades 3–12"))]
band_cuts <- band_cuts[order(RULE, YEAR, BAND)]

## ---------------------------------------------------------------------------
## Policy options applied to 2026 (auto-exit share and exit region by grade)
## ---------------------------------------------------------------------------

apply_option <- function(dt, auto_cut, review_cut) {
  ## auto_cut / review_cut: named numeric vectors keyed by GRADE.
  a <- auto_cut[dt$GRADE]; r <- review_cut[dt$GRADE]
  auto <- dt$PL_NEW >= a - 1e-9
  review <- !auto & dt$PL_NEW >= r - 1e-9 & as.integer(dt$GRADE) >= REVIEW_MIN_GRADE
  data.table(GRADE = dt$GRADE, auto = auto, region = auto | review)
}
g26 <- long[YEAR == CURRENT_YEAR]
gc26 <- grade_cuts[YEAR == CURRENT_YEAR]
bc26 <- band_cuts[YEAR == CURRENT_YEAR]
by_grade <- function(v) setNames(rep(v, length(GRADES)), GRADES)
band_lookup <- function(rule) {
  b <- bc26[RULE == rule & BAND %in% names(GRADE_BANDS)]
  out <- setNames(rep(NA_real_, length(GRADES)), GRADES)
  for (i in seq_len(nrow(b))) out[GRADE_BANDS[[as.character(b$BAND[i])]]] <- b$cut[i]
  out
}
grade_lookup <- function(rule) {
  g <- gc26[RULE == rule]
  out <- setNames(rep(REVIEW_LOW_PL, length(GRADES)), GRADES)
  out[g$GRADE] <- g$cut
  out
}

option_defs <- list(
  CURRENT = NULL,
  A = list(auto = by_grade(EXIT_AUTO_PL), review = by_grade(REVIEW_LOW_PL)),
  B = list(auto = grade_lookup("AUTO"), review = grade_lookup("REVIEW")),
  C = list(auto = band_lookup("AUTO"), review = {
    x <- band_lookup("REVIEW"); x[is.na(x)] <- REVIEW_LOW_PL; x })
)
options_by_grade <- rbindlist(lapply(names(option_defs), function(o) {
  res <- if (o == "CURRENT") {
    data.table(GRADE = g26$GRADE, auto = g26$EXIT_OLD == EXIT_LEVELS[3],
               region = g26$EXIT_OLD != EXIT_LEVELS[1])
  } else apply_option(g26, option_defs[[o]]$auto, option_defs[[o]]$review)
  res[, .(n = .N, n_auto = sum(auto), pct_auto = 100 * mean(auto),
          n_region = sum(region), pct_region = 100 * mean(region)), by = GRADE][, OPTION := o]
}))[order(OPTION, as.integer(GRADE))]
option_cuts <- rbindlist(lapply(setdiff(names(option_defs), "CURRENT"), function(o)
  data.table(OPTION = o, GRADE = GRADES,
             AUTO_CUT = unname(option_defs[[o]]$auto[GRADES]),
             REVIEW_CUT = ifelse(as.integer(GRADES) >= REVIEW_MIN_GRADE,
                                 unname(option_defs[[o]]$review[GRADES]), NA_real_))))
options_state <- options_by_grade[, .(n = sum(n), n_auto = sum(n_auto),
                                      pct_auto = 100 * sum(n_auto) / sum(n),
                                      n_region = sum(n_region),
                                      pct_region = 100 * sum(n_region) / sum(n)), by = OPTION]

## ---------------------------------------------------------------------------
## ILEARN corroboration (already-aggregated sandbox output)
## ---------------------------------------------------------------------------

ilearn_youden <- if (file.exists(ILEARN_CSV)) {
  x <- fread(ILEARN_CSV)
  x[, GRADE := as.character(GRADE)]
  x[]
} else data.table()

## ---------------------------------------------------------------------------
## Meta + write
## ---------------------------------------------------------------------------

meta <- list(
  years          = YEARS,
  current_year   = CURRENT_YEAR,
  n_by_year      = long[, .N, by = YEAR],
  policy         = list(auto = EXIT_AUTO_PL, review_low = REVIEW_LOW_PL,
                        review_min_grade = REVIEW_MIN_GRADE),
  small_n        = SMALL_N,
  hist_bin       = HIST_BIN,
  cut_grid       = CUT_GRID,
  search_grid    = SEARCH_GRID,
  history_method = "OLD_to_NEW transform (median plateau collapse), rounded half up, PL_NEW lookup",
  concordance    = basename(XLSX_PATH),
  transform      = basename(XFORM_PATH),
  ilearn_source  = if (file.exists(ILEARN_CSV)) ILEARN_CSV else NA_character_,
  generated_at   = Sys.time()
)

out <- list(
  meta             = meta,
  validation       = validation,
  validation_state = validation_state,
  method_check     = method_check,
  rates            = rates,
  rates_wide       = rates_wide,
  rates_band       = rates_band,
  rates_state      = rates_state,
  rates_state_g3   = rates_state_g3,
  transitions      = transitions,
  crosstab         = crosstab,
  pl_shift         = pl_shift,
  hist_2026        = hist_2026,
  cut_curve_grade  = cut_curve_grade,
  cut_curve_state  = cut_curve_state,
  cut_curve_g3     = cut_curve_g3,
  grade_cuts       = grade_cuts,
  band_cuts        = band_cuts,
  option_cuts      = option_cuts,
  options_by_grade = options_by_grade,
  options_state    = options_state,
  ilearn_youden    = ilearn_youden
)

rm(long, long_g3, long_pool, pooled, g26)
dir.create(dirname(CACHE_PATH), showWarnings = FALSE, recursive = TRUE)
saveRDS(out, CACHE_PATH)
message("Wrote cache: ", CACHE_PATH, " (", round(file.size(CACHE_PATH) / 1024, 1), " KB)")

## Aggregate console digest
r <- function(x, d = 1) round(x, d)
message("\nValidation (statewide):")
print(as.data.frame(validation_state[, .(YEAR, n, pct_pl_match = r(pct_pl_match, 2),
                                         pct_pl_within01 = r(pct_pl_within01, 2),
                                         pct_exit_match = r(pct_exit_match, 2))]), row.names = FALSE)
message("\nStatewide rates:")
print(as.data.frame(rates_state[, .(YEAR, STANDARD, n, n_auto, pct_auto = r(pct_auto, 2),
                                    pct_region = r(pct_region, 2))]), row.names = FALSE)
message("\nGrades 3+:")
print(as.data.frame(rates_state_g3[, .(YEAR, STANDARD, n, pct_auto = r(pct_auto, 2),
                                       pct_ge43 = r(pct_ge43, 2), pct_region = r(pct_region, 2))]), row.names = FALSE)
message("\nOptions (2026, statewide):")
print(as.data.frame(options_state[, .(OPTION, n_auto, pct_auto = r(pct_auto, 2), n_region,
                                      pct_region = r(pct_region, 2))]), row.names = FALSE)
message("Done in ", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "s")
