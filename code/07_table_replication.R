# ==============================================================================
# 07_table_replication.R
# ------------------------------------------------------------------------------
# INPUT:  inputs/intermediate/panel_ind.csv (from 06_process_panel.R)
# OUTPUT: outputs/tables/tables_1_2_3.xlsx  (Tables 1, 2, 3 as published)
#         outputs/figures/fig2_industry.pdf / .png (Figure 2 as published)
# ==============================================================================

rm(list = ls())

# ---- Path setup --------------------------------------------------------------
# PROJECT_ROOT is read from an OS environment variable so it survives the
# rm(list=ls()) above -- if run_all.R (or another script earlier in this
# session) already set it, that value is used automatically. If not (running
# this script completely standalone), edit the fallback path below.
PROJECT_ROOT <- Sys.getenv("PROJECT_ROOT", unset = "~/replication")  # <-- EDIT THIS PATH IF RUNNING STANDALONE
source(file.path(path.expand(PROJECT_ROOT), "code", "00_config.R"))

library(tidyverse)
library(fixest)
library(modelsummary)
library(openxlsx)
library(glue)

# ---- Paths ----
DATA_PATH <- PANEL_IND_CSV
OUTFILE   <- file.path(OUT_TABLES, "estimates.xlsx")
fig_dir   <- OUT_FIGURES
dir.create(fig_dir, showWarnings = FALSE)

# ---- Load Data ----
# panel_ind.csv has ~208 columns; the full pipeline (Tables 1-3 + Figure 2)
# only touches 36 of them. col_select means readr never parses the other
# ~170 into memory at all -- this is the single biggest lever on RAM given
# how wide the raw file is.
needed_cols <- c(
  "cma_name", "year", "month", "finalwt",
  "y_emp", "y_lfp", "y_log_earn", "y_actual_hrs_main", "y_condabs",
  "mean_temp", "total_precip", "pm25_15_rel", "smoke_15_rel",
  "union", "pt", "small_firm", "public_sector",
  "ind_agriculture", "ind_forestry", "ind_fishing", "ind_mining",
  "ind_utilities", "ind_construction", "ind_wholesale", "ind_retail",
  "ind_transport", "ind_finance", "ind_realestate", "ind_professional",
  "ind_business_support", "ind_education", "ind_healthcare", "ind_info_culture",
  "ind_accommodation", "ind_other_services", "ind_public_admin"
)

panel_ind <- read_csv(DATA_PATH, col_select = all_of(needed_cols)) %>%
  filter(month %in% c(5, 6, 7, 8, 9, 10)) %>%
  mutate(
    y_log_hrs_p1           = log(y_actual_hrs_main + 1),
    # Forestry and Fishing are both very small-n and imprecisely estimated
    # on their own; folded into Agriculture. Mining stays separate -- it's
    # precisely estimated on its own, no small-n reason to merge it.
    ind_ag_combined        = as.integer(ind_agriculture + ind_forestry + ind_fishing > 0),
    ind_primary            = as.integer(ind_forestry + ind_fishing + ind_mining + ind_agriculture > 0),
    ind_consumer_services  = as.integer(ind_retail + ind_accommodation > 0)
  )

panel_n2020 <- panel_ind %>% filter(year != 2020)
rm(panel_ind)   # nothing below uses the incl.-2020 sample
gc()

# ---- Helper Functions ----
# (single canonical definitions, used throughout)

scale_model <- function(model, factor = 10) {
  model$coefficients <- model$coefficients * factor   # keeps coef() in sync with coeftable
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

extract_coefs <- function(model, keep_pattern = "fit_pm25_15_rel:ind") {
  ct <- as.data.frame(coeftable(model))
  ct$term <- rownames(ct)
  ct <- ct[grepl(keep_pattern, ct$term, fixed = FALSE), ]
  colnames(ct)[1:4] <- c("estimate", "se", "tstat", "pval")
  ct$ci_lo <- ct$estimate - 1.96 * ct$se
  ct$ci_hi <- ct$estimate + 1.96 * ct$se
  rownames(ct) <- NULL
  return(ct)
}

wb <- createWorkbook()
diagnostics       <- list()   # small tibbles, one per model -- safe to keep whole run
fig2_industries    <- list()  # accumulates industry-interaction rows for the figure
fig2_manufacturing <- list()  # accumulates the manufacturing/baseline row for the figure

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

# Fits, writes the Excel sheet, records diagnostics, discards the model.
# Used for every non-industry regression (Table 1, Table 2).
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

# Fits ONE industry-interaction model and uses it for everything that needs
# it: the Table 3 Excel sheet AND the Figure 2 plotting data. This replaces
# what used to be two separate fits of the identical regression (one for the
# table, one re-fit from scratch for the figure).
run_check_write_industry <- function(formula, data, table_label, outcome_label) {
  m <- feols(formula, data = data, weights = ~ finalwt, cluster = ~ cma_name^year)
  s <- scale_model(m)

  write_sheet(s, table_label)
  diagnostics[[table_label]] <<- check_stars(s, table_label)

  fig2_industries[[outcome_label]] <<- extract_coefs(s) %>%
    mutate(outcome = outcome_label)
  fig2_manufacturing[[outcome_label]] <<- extract_coefs(s, keep_pattern = "^fit_pm25_15_rel$") %>%
    mutate(outcome = outcome_label, industry = "Manufacturing (ref.)")

  s$residuals <- NULL; s$fitted.val <- NULL; s$model_matrix_info <- NULL
  rm(m, s); gc()
  saveWorkbook(wb, OUTFILE, overwrite = TRUE)
  invisible(NULL)
}

# ---- Baseline IV ----
# 2020 excluded, hours in log(hours+1). Table2_Earnings / Table2_AvgHours /
# Table2_Absent also supply the "population average" reference line for
# Figure 2 later -- no separate fit needed for that.

baseline_formula <- function(outcome) {
  as.formula(glue("{outcome} ~ mean_temp + total_precip | ",
                   "cma_name^month + year | pm25_15_rel ~ smoke_15_rel"))
}
 
run_check_write(baseline_formula("y_emp"),        panel_n2020, "Baseline_Employment")
run_check_write(baseline_formula("y_lfp"),        panel_n2020, "Baseline_LFP")
run_check_write(baseline_formula("y_log_earn"),   panel_n2020, "Baseline_Earnings")
run_check_write(baseline_formula("y_log_hrs_p1"), panel_n2020, "Baseline_AvgHours")
run_check_write(baseline_formula("y_condabs"),    panel_n2020, "Baseline_Absent")
 
# ---- Pre/Post-COVID Split ----
# 2020 excluded. Same baseline specification as above.
 
panel_pre  <- panel_n2020 %>% filter(year < 2020)
panel_post <- panel_n2020 %>% filter(year > 2020)
 
run_check_write(baseline_formula("y_log_hrs_p1"), panel_pre,  "Pre_AvgHours")
run_check_write(baseline_formula("y_condabs"),    panel_pre,  "Pre_Absent")
run_check_write(baseline_formula("y_log_earn"),   panel_pre,  "Pre_Earnings")
run_check_write(baseline_formula("y_log_hrs_p1"), panel_post, "Post_AvgHours")
run_check_write(baseline_formula("y_condabs"),    panel_post, "Post_Absent")
run_check_write(baseline_formula("y_log_earn"),   panel_post, "Post_Earnings")
 
rm(panel_pre, panel_post)
gc()

# ---- Industry Interactions ----
# Manufacturing omitted, 2020 excluded. 17 industry categories (Agriculture/
# Forestry/Fishing combined; Mining separate). 

ind_list <- c("ind_ag_combined", "ind_mining",
              "ind_utilities", "ind_construction", "ind_wholesale", "ind_retail",
              "ind_transport", "ind_finance", "ind_realestate", "ind_professional",
              "ind_business_support", "ind_education", "ind_healthcare", "ind_info_culture",
              "ind_accommodation", "ind_other_services", "ind_public_admin")
ind_rhs_ctrl <- paste(ind_list, collapse = " + ")
ind_iv_lhs <- paste(c("pm25_15_rel", paste0("pm25_15_rel:", ind_list)), collapse = " + ")
ind_iv_rhs <- paste(c("smoke_15_rel", paste0("smoke_15_rel:", ind_list)), collapse = " + ")
ind_formula <- function(outcome) {
  as.formula(glue("{outcome} ~ mean_temp + total_precip + {ind_rhs_ctrl} | ",
                   "cma_name^month + year | {ind_iv_lhs} ~ {ind_iv_rhs}"))
}

run_check_write_industry(ind_formula("y_log_earn"),   panel_n2020, "Industry_Earnings", "Log Earnings")
run_check_write_industry(ind_formula("y_log_hrs_p1"), panel_n2020, "Industry_AvgHours", "Actual Hours Worked")
run_check_write_industry(ind_formula("y_condabs"),    panel_n2020, "Industry_Absent",   "Conditional Absence")

rm(panel_n2020)
gc()

# ---- Final: Sanity-Check Sheet ----
# (small tibbles only)

diag_df <- bind_rows(diagnostics) %>%
  filter(str_detect(term, "fit_pm25_15_rel")) %>%
  mutate(flag = if_else(implied_stars == "" & abs(t_recomputed) < 1.645, "",
                         "check vs published stars"))

addWorksheet(wb, "SANITY_CHECK")
writeData(wb, "SANITY_CHECK", diag_df, rowNames = FALSE)
saveWorkbook(wb, OUTFILE, overwrite = TRUE)

message("Saved ", OUTFILE, " -- N2020 sample only, hours in log(hours+1), ",
        "Agriculture/Forestry/Fishing combined. Committed production spec for Tables 1-3.")


