# ==============================================================================
# 05_process_weather.R
# ------------------------------------------------------------------------------
# INPUT:  Environment and Climate Change Canada daily climate CSVs, one file
#         per station, placed under inputs/raw_data/weather/ (see README.txt,
#         "Obtaining raw data").
# OUTPUT: inputs/intermediate/weather_all.csv     (raw daily records, all stations)
#         inputs/intermediate/weather_daily.csv   (one row per station-day)
#         inputs/intermediate/weather_monthly.csv (one row per station-month --
#                                                   this is the file
#                                                   06_process_panel.R reads)
# ==============================================================================

rm(list = ls())

# PROJECT_ROOT is read from an OS environment variable so it survives the
# rm(list=ls()) above -- if run_all.R (or another script earlier in this
# session) already set it, that value is used automatically. If not (running
# this script completely standalone), edit the fallback path below.
PROJECT_ROOT <- Sys.getenv("PROJECT_ROOT", unset = "~/replication")   # <-- EDIT THIS PATH IF RUNNING STANDALONE
source(file.path(path.expand(PROJECT_ROOT), "code", "00_config.R"))

library(tidyverse)
library(lubridate)

# ==============================================================================
# STEP 1: Load all per-station daily climate CSVs
# ==============================================================================

weather_all <- list.files(WEATHER_RAW_DIR, full.names = TRUE, pattern = "\\.csv$") %>%
  map_dfr(~ read_csv(.x, show_col_types = FALSE, col_types = cols(.default = "c")), .id = "file")

if (nrow(weather_all) == 0) {
  stop("No weather CSVs found in ", WEATHER_RAW_DIR,
       " -- see README.txt for where to obtain ECCC daily climate data.")
}

weather_all <- weather_all %>%
  mutate(filename = basename(file)) %>%
  select(-file)

cat("Loaded", n_distinct(weather_all$filename), "weather files\n")
cat("Total observations:", nrow(weather_all), "\n")

# ==============================================================================
# STEP 2: Clean and derive wind direction (following Borgschulte et al. 2024
# for wind-bin construction; wind variables are not used in the paper's final
# specifications but are kept here for completeness/robustness checks)
# ==============================================================================

weather_all <- weather_all %>%
  mutate(
    date = ymd(`Date/Time`),
    year_month = floor_date(date, "month"),
    across(
      c(`Mean Temp (°C)`, `Max Temp (°C)`, `Min Temp (°C)`,
        `Total Precip (mm)`, `Spd of Max Gust (km/h)`,
        `Dir of Max Gust (10s deg)`),
      as.numeric
    ),
    wind_direction_deg = `Dir of Max Gust (10s deg)` * 10,
    wind_speed_kmh = `Spd of Max Gust (km/h)`
  ) %>%
  mutate(
    wind_dir_360 = case_when(
      is.na(wind_direction_deg) ~ NA_real_,
      wind_direction_deg < 0    ~ wind_direction_deg + 360,
      wind_direction_deg >= 360 ~ wind_direction_deg - 360,
      TRUE ~ wind_direction_deg
    ),
    wind_bin_60 = case_when(
      is.na(wind_dir_360) ~ NA_character_,
      wind_dir_360 >= 0   & wind_dir_360 < 60  ~ "bin_0_60",
      wind_dir_360 >= 60  & wind_dir_360 < 120 ~ "bin_60_120",
      wind_dir_360 >= 120 & wind_dir_360 < 180 ~ "bin_120_180",
      wind_dir_360 >= 180 & wind_dir_360 < 240 ~ "bin_180_240",
      wind_dir_360 >= 240 & wind_dir_360 < 300 ~ "bin_240_300",
      wind_dir_360 >= 300 & wind_dir_360 < 360 ~ "bin_300_360",
      TRUE ~ NA_character_
    ),
    wind_cardinal = case_when(
      is.na(wind_dir_360) ~ NA_character_,
      wind_dir_360 >= 337.5 | wind_dir_360 < 22.5  ~ "North",
      wind_dir_360 >= 22.5  & wind_dir_360 < 67.5  ~ "Northeast",
      wind_dir_360 >= 67.5  & wind_dir_360 < 112.5 ~ "East",
      wind_dir_360 >= 112.5 & wind_dir_360 < 157.5 ~ "Southeast",
      wind_dir_360 >= 157.5 & wind_dir_360 < 202.5 ~ "South",
      wind_dir_360 >= 202.5 & wind_dir_360 < 247.5 ~ "Southwest",
      wind_dir_360 >= 247.5 & wind_dir_360 < 292.5 ~ "West",
      wind_dir_360 >= 292.5 & wind_dir_360 < 337.5 ~ "Northwest",
      TRUE ~ NA_character_
    )
  )

# ==============================================================================
# STEP 3: Daily aggregation
# ==============================================================================

weather_daily <- weather_all %>%
  group_by(`Station Name`, date, Year, Month, Day) %>%
  summarise(
    mean_temp    = mean(`Mean Temp (°C)`, na.rm = TRUE),
    max_temp     = max(`Max Temp (°C)`, na.rm = TRUE),
    min_temp     = min(`Min Temp (°C)`, na.rm = TRUE),
    total_precip = sum(`Total Precip (mm)`, na.rm = TRUE),
    max_wind_speed = max(wind_speed_kmh, na.rm = TRUE),
    mean_wind_dir_deg = {
      dirs <- na.omit(wind_dir_360)
      if (length(dirs) > 0) {
        rad <- dirs * pi / 180
        mean_rad <- atan2(sum(sin(rad)), sum(cos(rad)))
        mean_deg <- mean_rad * 180 / pi
        if (mean_deg < 0) mean_deg + 360 else mean_deg
      } else {
        NA_real_
      }
    },
    days_with_data = n(),
    .groups = "drop"
  )

# ==============================================================================
# STEP 4: Monthly aggregation (this is the file process_panel.R consumes)
# ==============================================================================

weather_monthly <- weather_daily %>%
  mutate(year_month = floor_date(date, "month")) %>%
  group_by(`Station Name`, year_month, Year, Month) %>%
  summarise(
    mean_temp    = mean(mean_temp, na.rm = TRUE),
    total_precip = sum(total_precip, na.rm = TRUE),
    mean_precip  = mean(total_precip, na.rm = TRUE),
    mean_wind_speed = mean(max_wind_speed, na.rm = TRUE),
    mean_wind_dir = {
      dirs <- na.omit(mean_wind_dir_deg)
      if (length(dirs) > 0) {
        rad <- dirs * pi / 180
        mean_rad <- atan2(sum(sin(rad)), sum(cos(rad)))
        mean_deg <- mean_rad * 180 / pi
        if (mean_deg < 0) mean_deg + 360 else mean_deg
      } else {
        NA_real_
      }
    },
    days_with_data = sum(!is.na(mean_temp)),
    .groups = "drop"
  )

# NOTE: wind_bin_60 / wind_cardinal are re-derived here from mean_wind_dir,
# rather than carried forward from weather_all/weather_daily. An earlier
# version of this script dropped them entirely (they weren't judged relevant
# to the paper's final specifications), without checking that
# 06_process_panel.R's weather_month step still expects both columns to be
# present on every row of weather_monthly.csv -- it uses them downstream to
# build the wind_0_60/wind_60_120/... dummy variables that do get merged
# into the final panel. Restored here so that dependency isn't silently
# broken.
weather_monthly <- weather_monthly %>%
  mutate(
    wind_bin_60 = case_when(
      is.na(mean_wind_dir) ~ NA_character_,
      mean_wind_dir >= 0   & mean_wind_dir < 60  ~ "bin_0_60",
      mean_wind_dir >= 60  & mean_wind_dir < 120 ~ "bin_60_120",
      mean_wind_dir >= 120 & mean_wind_dir < 180 ~ "bin_120_180",
      mean_wind_dir >= 180 & mean_wind_dir < 240 ~ "bin_180_240",
      mean_wind_dir >= 240 & mean_wind_dir < 300 ~ "bin_240_300",
      mean_wind_dir >= 300 & mean_wind_dir < 360 ~ "bin_300_360",
      TRUE ~ NA_character_
    ),
    wind_cardinal = case_when(
      is.na(mean_wind_dir) ~ NA_character_,
      mean_wind_dir >= 337.5 | mean_wind_dir < 22.5  ~ "North",
      mean_wind_dir >= 22.5  & mean_wind_dir < 67.5  ~ "Northeast",
      mean_wind_dir >= 67.5  & mean_wind_dir < 112.5 ~ "East",
      mean_wind_dir >= 112.5 & mean_wind_dir < 157.5 ~ "Southeast",
      mean_wind_dir >= 157.5 & mean_wind_dir < 202.5 ~ "South",
      mean_wind_dir >= 202.5 & mean_wind_dir < 247.5 ~ "Southwest",
      mean_wind_dir >= 247.5 & mean_wind_dir < 292.5 ~ "West",
      mean_wind_dir >= 292.5 & mean_wind_dir < 337.5 ~ "Northwest",
      TRUE ~ NA_character_
    )
  )

# ==============================================================================
# SAVE
# ==============================================================================

write_csv(weather_all,     file.path(INTERMED_DIR, "weather_all.csv"))
write_csv(weather_daily,   file.path(INTERMED_DIR, "weather_daily.csv"))
write_csv(weather_monthly, WEATHER_MONTHLY_CSV)

cat("Saved: weather_all.csv, weather_daily.csv, weather_monthly.csv in\n  ", INTERMED_DIR, "\n")

cat("\nCoverage check -- monthly wind direction available for",
    round(100 * mean(!is.na(weather_monthly$mean_wind_dir)), 1), "% of station-months\n")

message("05_process_weather.R complete.")
