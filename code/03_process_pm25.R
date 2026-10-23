# ==============================================================================
# 03_process_pm25.R
# ------------------------------------------------------------------------------
# INPUT:  none required locally -- downloads hourly PM2.5 station data
#         (2015-2025) from Environment and Climate Change Canada's National
#         Air Pollution Surveillance (NAPS) program.
# OUTPUT: inputs/intermediate/pm25.csv
#         (long format: one row per station-city, date, and hour)
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

library(readr)
library(purrr)
library(dplyr)
library(stringr)
library(tidyr)

# ==============================================================================
# STEP 1: Download hourly PM2.5 CSVs, 2015-2025
# ------------------------------------------------------------------------------
# The paper's sample is 2015-2025, so only those years are downloaded here
# (the NAPS archive itself goes back to 1995 if a longer window is ever needed
# -- just extend `years` below).
# ==============================================================================

years <- 2015:2025

make_url <- function(year) {
  sprintf(
    "https://data-donnees.az.ec.gc.ca/api/file?path=%%2Fair%%2Fmonitor%%2Fnational-air-pollution-surveillance-naps-program%%2FData-Donnees%%2F%d%%2FContinuousData-DonneesContinu%%2FHourlyData-DonneesHoraires%%2FPM25_%d.csv",
    year, year
  )
}

read_pm25 <- function(year) {
  dest <- file.path(PM25_RAW_DIR, paste0("PM25_", year, ".csv"))

  if (file.exists(dest)) {
    message("Already downloaded: ", basename(dest))
  } else {
    message("Downloading ", year, " ...")
    tryCatch(
      download.file(make_url(year), dest, mode = "wb", quiet = TRUE),
      error = function(e) message("  Failed for ", year, ": ", e$message)
    )
  }

  if (!file.exists(dest)) return(NULL)

  # NAPS files have a variable number of metadata rows before the real header;
  # find the row that actually starts the data table.
  all_lines   <- readLines(dest, n = 50)
  header_line <- which(str_detect(all_lines, "^Pollutant.*,Method|^Pollutant.*,NAPS"))
  if (length(header_line) == 0) {
    message("  Could not find header for ", year, " -- defaulting to line 1.")
    header_line <- 1
  }

  read_csv(dest, skip = header_line - 1, col_types = cols(.default = col_character()))
}

pm25_list <- map(years, read_pm25)
names(pm25_list) <- paste0("pm25_", years)
pm25_list <- pm25_list[!map_lgl(pm25_list, is.null)]

if (length(pm25_list) == 0) {
  stop("No PM2.5 files were downloaded or found in ", PM25_RAW_DIR,
       " -- check network access or place NAPS PM25_<year>.csv files there manually.")
}

# ==============================================================================
# STEP 2: Canonicalize column names across years
# ------------------------------------------------------------------------------
# NAPS column naming/formatting has changed over the years (bilingual headers,
# spacing, capitalization). This forces every year onto the same 32-column
# canonical structure before combining.
# ==============================================================================

hour_cols <- paste0("h", sprintf("%02d", 1:24))
canonical <- c("pollutant", "method", "napsid", "city", "p_t",
               "latitude", "longitude", "date", hour_cols)

clean_one <- function(df) {
  nm <- names(df)
  nm <- gsub("//.*$", "", nm)             # drop French half of bilingual headers
  nm <- trimws(nm)
  nm <- gsub("[[:space:]]+", "_", nm)
  nm <- gsub("[^A-Za-z0-9_]", "_", nm)
  nm <- tolower(nm)
  nm <- gsub("_+", "_", nm)
  names(df) <- nm

  names(df) <- dplyr::recode(
    names(df),
    "method_code"        = "method",
    "naps_id"            = "napsid",
    "napssid"            = "napsid",
    "province_territory" = "p_t",
    "city_ville"         = "city",
    "date_date"          = "date"
  )

  missing <- setdiff(canonical, names(df))
  if (length(missing)) df[missing] <- NA_character_
  df <- df[, canonical, drop = FALSE]
  mutate(df, across(everything(), as.character))
}

pm25_dfs_clean <- map(pm25_list, clean_one)
pm25_all <- bind_rows(pm25_dfs_clean)

stopifnot(ncol(pm25_all) == length(canonical))
stopifnot(sum(map_int(pm25_dfs_clean, nrow)) == nrow(pm25_all))

# ==============================================================================
# STEP 3: Reshape to long format and save
# ==============================================================================

pm25_long <- pm25_all %>%
  pivot_longer(cols = all_of(hour_cols), names_to = "hour", values_to = "value")

write_csv(pm25_long, PM25_LONG_CSV)

message("Saved: ", PM25_LONG_CSV)
message("03_process_pm25.R complete.")
