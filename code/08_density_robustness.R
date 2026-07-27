# ==============================================================================
# 08_density_robustness.R
# ------------------------------------------------------------------------------
# INPUT:  inputs/intermediate/panel_ind.csv (from 06_process_panel.R)
#         inputs/raw_data/smoke/smoke.gpkg  (from 02_process_smoke.R)
#         inputs/raw_data/geo/lcma000b21a_e.shp
# OUTPUT: outputs/tables/density_robustness_n2020.xlsx
#         (re-estimates the Table 3 industry spec with Medium+Heavy-only and
#         Heavy-only smoke-day instruments, for the density-robustness
#         paragraph in the Online Methods section)
#
# NOTE: this script's make_smoke15_density() helper already grid-completes
# (fills missing CMA-months to 0 smoke days) before demeaning, so it does not
# have the smoke_15_rel bug that was fixed in 06_process_panel.R -- that's
# also why, before the fix, this file's N did not match Table 3's N (see
# README.txt "Known issues and fixes").
# ==============================================================================

rm(list = ls())

# ---- Path setup --------------------------------------------------------------
# PROJECT_ROOT is read from an OS environment variable so it survives the
# rm(list=ls()) above -- if run_all.R (or another script earlier in this
# session) already set it, that value is used automatically. If not (running
# this script completely standalone), edit the fallback path below.
PROJECT_ROOT <- Sys.getenv("PROJECT_ROOT", unset = "~/replication")   # <-- EDIT THIS PATH IF RUNNING STANDALONE
source(file.path(path.expand(PROJECT_ROOT), "code", "00_config.R"))

library(tidyverse)
library(fixest)
library(modelsummary)
library(openxlsx)
library(glue)
library(sf)
library(lubridate)

# ---- Paths ----
DATA_PATH <- PANEL_IND_CSV
GPKG_PATH <- SMOKE_GPKG
CMA_PATH  <- CMA_SHP
OUTFILE   <- file.path(OUT_TABLES, "density_robustness_n2020.xlsx")

# ---- Load Data ----
# Same column-selection approach as the main tables script. This one also
# needs `ym` (for the 30-day exposure-window rebuild below) but doesn't need
# smoke_15_rel, union/pt/small_firm/public_sector, since we're only re-running
# the Table 3 industry spec, not Table 1 or Table 2.
needed_cols <- c(
  "cma_name", "year", "month", "ym", "finalwt",
  "y_log_earn", "y_actual_hrs_main", "y_condabs",
  "mean_temp", "total_precip", "pm25_15_rel",
  "ind_agriculture", "ind_forestry", "ind_fishing", "ind_mining",
  "ind_utilities", "ind_construction", "ind_wholesale", "ind_retail",
  "ind_transport", "ind_finance", "ind_realestate", "ind_professional",
  "ind_business_support", "ind_education", "ind_healthcare", "ind_info_culture",
  "ind_accommodation", "ind_other_services", "ind_public_admin"
)

panel_ind <- read_csv(DATA_PATH, col_select = all_of(needed_cols)) %>%
  filter(month %in% c(5, 6, 7, 8, 9, 10)) %>%
  mutate(
    y_log_hrs_p1    = log(y_actual_hrs_main + 1),
    ind_ag_combined = as.integer(ind_agriculture + ind_forestry + ind_fishing > 0)
  )

panel_n2020 <- panel_ind %>% filter(year != 2020)
rm(panel_ind)
gc()

# ---- Rebuild density-filtered smoke instruments (mirrors process_panel.R) ----

message("Loading smoke polygons for density robustness check...")

smoke_raw <- st_read(GPKG_PATH, quiet = TRUE) %>%
  mutate(date = as.Date(file_date)) %>%
  filter(month(date) %in% 5:10) %>%
  st_make_valid() %>%
  st_transform(3347)

cma_sf <- st_read(CMA_PATH, quiet = TRUE) %>%
  st_transform(3347)

nine_cmas <- unique(panel_n2020$cma_name)

cma_buf9 <- cma_sf %>%
  filter(CMANAME %in% nine_cmas) %>%
  st_buffer(25000)

mid_month_rob <- panel_n2020 %>%
  distinct(cma_name, ym) %>%
  arrange(cma_name, ym) %>%
  mutate(
    mid       = ym + days(14),
    win_start = mid - months(1),
    win_end   = mid
  )

make_smoke15_density <- function(smoke_subset, label) {
  message(glue("  Intersecting [{label}] smoke polygons..."))
  si <- st_intersects(cma_buf9, smoke_subset)
  smoke_cma <- tibble(
    cma_name = rep(cma_buf9$CMANAME, lengths(si)),
    date     = smoke_subset$date[unlist(si)]
  ) %>%
    distinct(cma_name, date)

  out <- smoke_cma %>%
    inner_join(mid_month_rob, by = "cma_name") %>%
    filter(date >= win_start & date <= win_end) %>%
    group_by(cma_name, ym) %>%
    summarise(smoke_15 = n_distinct(date), .groups = "drop")

  full_grid <- mid_month_rob %>% select(cma_name, ym)
  out <- full_grid %>%
    left_join(out, by = c("cma_name", "ym")) %>%
    mutate(smoke_15 = replace_na(smoke_15, 0L))

  out %>%
    group_by(cma_name) %>%
    mutate(smoke_15_rel = smoke_15 - mean(smoke_15, na.rm = TRUE)) %>%
    ungroup()
}

smoke_medh <- make_smoke15_density(
  smoke_raw %>% filter(Density %in% c("Medium", "Heavy")), "Medium + Heavy")
smoke_h <- make_smoke15_density(
  smoke_raw %>% filter(Density == "Heavy"), "Heavy only")

rm(smoke_raw, cma_sf, cma_buf9)
gc()

panel_n2020 <- panel_n2020 %>%
  left_join(smoke_medh %>% select(cma_name, ym, smoke_medh_rel = smoke_15_rel),
            by = c("cma_name", "ym")) %>%
  left_join(smoke_h %>% select(cma_name, ym, smoke_h_rel = smoke_15_rel),
            by = c("cma_name", "ym"))

rm(smoke_medh, smoke_h, mid_month_rob)
gc()

message("Density-filtered instruments merged. NA check: ",
        sum(is.na(panel_n2020$smoke_medh_rel)), " / ",
        sum(is.na(panel_n2020$smoke_h_rel)), " (medh / h)")

# ---- Helper Functions (same canonical versions as the main tables script) ----

scale_model <- function(model, factor = 10) {
  model$coefficients <- model$coefficients * factor
  ct <- coeftable(model)
  ct[, 1:2] <- ct[, 1:2] * factor
  model$coeftable <- ct
  return(model)
}

check_stars <- function(model, label) {
  ct <- coeftable(model)
  tibble(
    spec = label, term = rownames(ct),
    estimate = ct[, 1], std.error = ct[, 2],
    t_recomputed = ct[, 1] / ct[, 2]
  ) %>%
    mutate(implied_stars = case_when(
      abs(t_recomputed) > 2.576 ~ "***",
      abs(t_recomputed) > 1.96  ~ "**",
      abs(t_recomputed) > 1.645 ~ "*",
      TRUE ~ ""
    ))
}

wb <- createWorkbook()
diagnostics <- list()

write_sheet <- function(model, sheet_name) {
  addWorksheet(wb, sheet_name)
  tbl <- modelsummary(
    list(model),
    stars = c("*" = 0.1, "**" = 0.05, "***" = 0.01),
    gof_map = c("nobs", "r.squared"),
    statistic = "std.error", fmt = 3, output = "data.frame"
  )
  writeData(wb, sheet_name, tbl, rowNames = FALSE)
}

run_check_write <- function(formula, data, label) {
  m <- feols(formula, data = data, weights = ~ finalwt, cluster = ~ cma_name^year)
  s <- scale_model(m)
  write_sheet(s, label)
  diagnostics[[label]] <<- check_stars(s, label)
  s$residuals <- NULL; s$fitted.val <- NULL; s$model_matrix_info <- NULL
  rm(m, s); gc()
  saveWorkbook(wb, OUTFILE, overwrite = TRUE)
  invisible(NULL)
}

# ---- Industry spec, matching Table 3 exactly (17 categories) ----
# Only the instrument side changes across the two density thresholds below;
# the endogenous side (pm25_15_rel + interactions) and controls are identical
# to Table 3, so results are directly comparable to it.

ind_list <- c("ind_ag_combined", "ind_mining",
              "ind_utilities", "ind_construction", "ind_wholesale", "ind_retail",
              "ind_transport", "ind_finance", "ind_realestate", "ind_professional",
              "ind_business_support", "ind_education", "ind_healthcare", "ind_info_culture",
              "ind_accommodation", "ind_other_services", "ind_public_admin")
ind_rhs_ctrl <- paste(ind_list, collapse = " + ")
ind_iv_lhs   <- paste(c("pm25_15_rel", paste0("pm25_15_rel:", ind_list)), collapse = " + ")

ind_formula_instrument <- function(outcome, instrument) {
  ind_iv_rhs <- paste(c(instrument, paste0(instrument, ":", ind_list)), collapse = " + ")
  as.formula(glue("{outcome} ~ mean_temp + total_precip + {ind_rhs_ctrl} | ",
                   "cma_name^month + year | {ind_iv_lhs} ~ {ind_iv_rhs}"))
}

# ---- Instrument: Medium + Heavy smoke days ----

run_check_write(ind_formula_instrument("y_log_earn",    "smoke_medh_rel"),
                 panel_n2020, "MedHeavy_Earnings")
run_check_write(ind_formula_instrument("y_log_hrs_p1",  "smoke_medh_rel"),
                 panel_n2020, "MedHeavy_AvgHours")
run_check_write(ind_formula_instrument("y_condabs",     "smoke_medh_rel"),
                 panel_n2020, "MedHeavy_Absent")

# ---- Instrument: Heavy smoke days only ----

run_check_write(ind_formula_instrument("y_log_earn",    "smoke_h_rel"),
                 panel_n2020, "Heavy_Earnings")
run_check_write(ind_formula_instrument("y_log_hrs_p1",  "smoke_h_rel"),
                 panel_n2020, "Heavy_AvgHours")
run_check_write(ind_formula_instrument("y_condabs",     "smoke_h_rel"),
                 panel_n2020, "Heavy_Absent")

rm(panel_n2020)
gc()

# ---- Sanity-check sheet ----

diag_df <- bind_rows(diagnostics) %>%
  filter(str_detect(term, "fit_")) %>%
  mutate(flag = if_else(implied_stars == "" & abs(t_recomputed) < 1.645, "",
                         "check vs published stars"))

addWorksheet(wb, "SANITY_CHECK")
writeData(wb, "SANITY_CHECK", diag_df, rowNames = FALSE)
saveWorkbook(wb, OUTFILE, overwrite = TRUE)

message("Saved ", OUTFILE, " -- baseline (all-smoke) numbers are NOT repeated here; ",
        "they're identical to Table3_Earnings/AvgHours/Absent in tables_1_2_3.xlsx. ",
        "Compare this workbook's fit_pm25_15_rel baseline row against that one for the ",
        "'consistent across all three density thresholds' claim in the paper's footnote.")
