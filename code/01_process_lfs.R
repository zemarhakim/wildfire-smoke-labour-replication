# ==============================================================================
# 01_process_lfs.R
# ------------------------------------------------------------------------------
# INPUT:  Statistics Canada LFS PUMF monthly microdata files (.sav), 2015-2025,
#         obtained separately (see README.txt, "Obtaining raw data") and placed
#         under inputs/raw_data/lfs/ following the folder layout below.
# OUTPUT: inputs/intermediate/lfs_15_25.csv
#         (one row per LFS respondent-month, 2015-01 through 2025-08)
# ==============================================================================

rm(list = ls())

# ---- Path setup --------------------------------------------------------------
# Finds the replication folder automatically (no editing needed): looks for
# the folder containing code/00_config.R, starting from PROJECT_ROOT (if set
# and valid), then this script's own location, then the working directory.
.find_root <- function() {
  starts <- c(Sys.getenv("PROJECT_ROOT"),
              tryCatch(dirname(sys.frame(1)$ofile), error = function(e) ""),
              dirname(gsub("~+~", " ", sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)), fixed = TRUE)),
              getwd())
  for (s in starts[nzchar(starts)]) {
    d <- normalizePath(path.expand(s), mustWork = FALSE)
    repeat {
      if (file.exists(file.path(d, "code", "00_config.R"))) return(d)
      if (dirname(d) == d) break
      d <- dirname(d)
    }
  }
  stop("Can't find the replication folder. Either setwd() into it, or run ",
       "Sys.setenv(PROJECT_ROOT = '/path/to/replication') first.")
}
Sys.setenv(PROJECT_ROOT = .find_root())
rm(.find_root)
source(file.path(Sys.getenv("PROJECT_ROOT"), "code", "00_config.R"))

library(haven)
library(tidyverse)
library(janitor)

# ==============================================================================
# STEP 1: Combine monthly .sav files into a single CSV
# ------------------------------------------------------------------------------
# Expected folder layout under LFS_RAW_DIR (inputs/raw_data/lfs/):
#   micro<year>_rebased2025/micro<year>_<month>/LFS_<MonthName>_<year>.sav
#   (for 2025: micro2025/micro2025_<month>/LFS_<MonthName>_2025.sav)
# This mirrors the folder structure Statistics Canada's PUMF distribution uses.
# ==============================================================================

read_lfs_data <- function() {
  all_data <- list()
  years <- 2015:2025

  for (year in years) {
    max_month <- ifelse(year == 2025, 8, 12)   # 2025 data available through August

    for (month in 1:max_month) {
      if (year == 2025) {
        folder_name <- sprintf("micro2025/micro%d_%02d", year, month)
      } else {
        folder_name <- sprintf("micro%d_rebased2025/micro%d_%02d", year, year, month)
      }

      file_name <- sprintf("LFS_%s_%d.sav", month.name[month], year)
      full_path <- file.path(LFS_RAW_DIR, folder_name, file_name)

      if (file.exists(full_path)) {
        cat("Reading:", full_path, "\n")
        all_data[[length(all_data) + 1]] <- read_sav(full_path)
      } else {
        cat("Not found (skipped):", full_path, "\n")
      }
    }
  }

  bind_rows(all_data)
}

lfs_combined <- read_lfs_data()

write.csv(lfs_combined, LFS_COMBINED_CSV, row.names = FALSE)

cat("\nSaved:", LFS_COMBINED_CSV, "\n")
cat("Total rows:", nrow(lfs_combined), "\n")
cat("Total columns:", ncol(lfs_combined), "\n")

# ==============================================================================
# OPTIONAL DIAGNOSTICS
# ------------------------------------------------------------------------------
# Not required to produce lfs_15_25.csv or any downstream file. These are quick
# sanity checks on sample composition; safe to skip.
# ==============================================================================

lfs <- read.csv(LFS_COMBINED_CSV) %>% clean_names()

cat("\n---- Optional diagnostics (sample composition checks) ----\n")

# Sample sizes by CMA and survey year
lfs %>%
  group_by(cma, survyear) %>%
  summarise(
    n = n(),
    employed = sum(lfsstat %in% c(1, 2), na.rm = TRUE),
    unemployed = sum(lfsstat == 3, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  pivot_wider(names_from = survyear, values_from = c(n, employed, unemployed)) %>%
  print()

# Immigrant sample sizes by CMA
lfs %>%
  filter(!is.na(immig)) %>%
  group_by(cma, immig) %>%
  summarise(n = n(), .groups = "drop") %>%
  pivot_wider(names_from = immig, values_from = n) %>%
  print()

# Industry distribution and mean hours (outdoor-exposure proxy check)
lfs %>%
  filter(lfsstat %in% c(1, 2)) %>%
  group_by(naics_21) %>%
  summarise(
    n = n(),
    pct = n() / nrow(.) * 100,
    mean_hours = mean(atothrs, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(n)) %>%
  print()

# Union coverage by CMA
lfs %>%
  filter(lfsstat %in% c(1, 2)) %>%
  group_by(cma, union) %>%
  summarise(n = n(), .groups = "drop") %>%
  group_by(cma) %>%
  mutate(pct = n / sum(n) * 100) %>%
  print()

message("01_process_lfs.R complete.")
