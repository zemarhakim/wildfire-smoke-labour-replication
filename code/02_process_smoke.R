# ==============================================================================
# 02_process_smoke.R
# ------------------------------------------------------------------------------
# INPUT:  none required locally -- downloads daily NOAA HMS smoke plume
#         shapefiles (2015-2024) directly from NOAA's public archive.
# OUTPUT: inputs/raw_data/smoke/smoke.gpkg
#         (all daily smoke polygons, 2015-2024, combined into one GeoPackage
#         layer with a `file_date` column; this is what 06_process_panel.R and
#         08_density_robustness.R both read)
# ==============================================================================

rm(list = ls())

# PROJECT_ROOT is read from an OS environment variable so it survives the
# rm(list=ls()) above -- if run_all.R (or another script earlier in this
# session) already set it, that value is used automatically. If not (running
# this script completely standalone), edit the fallback path below.
PROJECT_ROOT <- Sys.getenv("PROJECT_ROOT", unset = "~/replication")   # <-- EDIT THIS PATH IF RUNNING STANDALONE
source(file.path(path.expand(PROJECT_ROOT), "code", "00_config.R"))

library(httr)
library(glue)
library(lubridate)
library(fs)
library(sf)
library(dplyr)
library(purrr)
library(stringr)

# ==============================================================================
# STEP 1: Download daily HMS smoke shapefiles (zipped), 2015-2024
# ------------------------------------------------------------------------------
# Source: https://satepsanone.nesdis.noaa.gov/pub/FIRE/web/HMS/Smoke_Polygons/Shapefile
# Skips files already downloaded, so this is safe to re-run/resume.
# ==============================================================================

base_url <- "https://satepsanone.nesdis.noaa.gov/pub/FIRE/web/HMS/Smoke_Polygons/Shapefile"
zip_dir  <- file.path(SMOKE_RAW_DIR, "hms_smoke_shapefiles")
dir_create(zip_dir)

for (year in 2015:2024) {
  for (month in 1:12) {
    days_in_mo <- days_in_month(ymd(glue("{year}-{month}-01")))

    for (day in 1:days_in_mo) {
      month_str <- sprintf("%02d", month)
      day_str   <- sprintf("%02d", day)
      file_name <- glue("hms_smoke{year}{month_str}{day_str}.zip")
      url  <- glue("{base_url}/{year}/{month_str}/{file_name}")
      dest <- file.path(zip_dir, file_name)

      if (file_exists(dest)) {
        message("Skipping (already exists): ", file_name)
        next
      }

      resp <- try(GET(url, write_disk(dest, overwrite = TRUE), timeout(30)), silent = TRUE)

      if (inherits(resp, "try-error") || resp$status_code != 200) {
        message("Failed: ", url)
        if (file_exists(dest)) file_delete(dest)
      } else {
        message("Downloaded: ", file_name)
      }

      Sys.sleep(0.2)   # polite delay between requests
    }
  }
}

message("All available daily HMS smoke files downloaded to: ", zip_dir)

# ==============================================================================
# STEP 2: Unzip and combine into a single GeoPackage
# ==============================================================================

unzip_dir <- file.path(zip_dir, "unzipped")
dir_create(unzip_dir)

zips <- dir_ls(zip_dir, regexp = "\\.zip$", recurse = FALSE)
message("Unzipping ", length(zips), " files...")

for (z in zips) {
  date_tag   <- str_extract(basename(z), "\\d{8}")
  out_subdir <- file.path(unzip_dir, date_tag)

  if (dir_exists(out_subdir) && length(dir_ls(out_subdir, regexp = "\\.shp$")) > 0) {
    message("Skipping (already unzipped): ", basename(z))
    next
  }

  dir_create(out_subdir)
  unzip(z, exdir = out_subdir)
  message("Unzipped: ", basename(z))
}

shps <- dir_ls(unzip_dir, regexp = "\\.shp$", recurse = TRUE)
message("Loading ", length(shps), " shapefiles...")

smoke_list <- map(shps, \(x) {
  date_tag <- str_extract(basename(x), "\\d{8}")
  d <- try(st_read(x, quiet = TRUE), silent = TRUE)

  if (inherits(d, "try-error")) {
    message("Failed to read: ", x)
    return(NULL)
  }

  d %>%
    mutate(
      file_date = ymd(date_tag),
      year  = year(file_date),
      month = month(file_date),
      day   = day(file_date)
    )
})

smoke_all <- bind_rows(smoke_list) %>% st_make_valid()

if (is.na(st_crs(smoke_all))) {
  st_crs(smoke_all) <- 4326   # NOAA HMS shapefiles are lon/lat WGS84
}

st_write(
  smoke_all,
  dsn        = SMOKE_GPKG,
  driver     = "GPKG",
  layer      = "smoke",
  delete_dsn = TRUE
)

message("Saved: ", SMOKE_GPKG)

# ---- Optional summary ----
smoke_all %>%
  st_drop_geometry() %>%
  group_by(year, month) %>%
  summarise(n_polygons = n(), .groups = "drop") %>%
  print(n = Inf)

message("02_process_smoke.R complete.")
