# ==============================================================================
# 00_config.R
# ------------------------------------------------------------------------------
# Defines every path used by the pipeline. Sourced by every other script in
# code/. Nothing in this file needs editing.
#
# HOW PROJECT_ROOT IS SET:
# Each script (and run_all.R) finds the replication folder automatically --
# the folder containing code/00_config.R -- and stores it in the PROJECT_ROOT
# environment variable before sourcing this file. An environment variable is
# used rather than an ordinary R object because every stage script starts
# with rm(list = ls()), which would delete an ordinary object but cannot
# touch an environment variable.
#
# HOW TO USE:
#   - Run one script on its own: open the replication folder (or setwd() into
#     it) and run the script from the top.
#   - Run the whole pipeline: run code/run_all.R.
#   - If R can't find the folder (working directory somewhere unrelated), run
#     Sys.setenv(PROJECT_ROOT = "/path/to/replication") first.
# ==============================================================================

if (identical(Sys.getenv("PROJECT_ROOT"), "") ||
    !file.exists(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "00_config.R"))) {
  stop("PROJECT_ROOT is not set to the replication folder. Run a script from ",
       "code/ (they set it automatically), or run ",
       "Sys.setenv(PROJECT_ROOT = '/path/to/replication') first.")
}

PROJECT_ROOT <- path.expand(Sys.getenv("PROJECT_ROOT"))

# ---- Derived paths (do not edit below this line) ----------------------------

RAW_DIR      <- file.path(PROJECT_ROOT, "inputs", "raw_data")
INTERMED_DIR <- file.path(PROJECT_ROOT, "inputs", "intermediate")
CODE_DIR     <- file.path(PROJECT_ROOT, "code")
OUT_TABLES   <- file.path(PROJECT_ROOT, "outputs", "tables")
OUT_FIGURES  <- file.path(PROJECT_ROOT, "outputs", "figures")

LFS_RAW_DIR     <- file.path(RAW_DIR, "lfs")
SMOKE_RAW_DIR   <- file.path(RAW_DIR, "smoke")
PM25_RAW_DIR    <- file.path(RAW_DIR, "pm25")
WEATHER_RAW_DIR <- file.path(RAW_DIR, "weather")
GEO_RAW_DIR     <- file.path(RAW_DIR, "geo")

# Key intermediate/raw files referenced by name across multiple scripts
LFS_COMBINED_CSV    <- file.path(INTERMED_DIR, "lfs_15_25.csv")
PM25_LONG_CSV       <- file.path(INTERMED_DIR, "pm25.csv")
WEATHER_MONTHLY_CSV <- file.path(INTERMED_DIR, "weather_monthly.csv")
SMOKE_GPKG          <- file.path(SMOKE_RAW_DIR, "smoke.gpkg")
CMA_SHP             <- file.path(GEO_RAW_DIR, "lcma000b21a_e.shp")
NFDB_SHP            <- file.path(GEO_RAW_DIR, "NFDB_point_20250519.shp")
PROV_SHP            <- file.path(GEO_RAW_DIR, "lpr_000b21a_e.shp")
PANEL_MONTH_CSV     <- file.path(INTERMED_DIR, "panel_month.csv")
PANEL_IND_CSV       <- file.path(INTERMED_DIR, "panel_ind.csv")

dir.create(RAW_DIR,         recursive = TRUE, showWarnings = FALSE)
dir.create(LFS_RAW_DIR,     recursive = TRUE, showWarnings = FALSE)
dir.create(SMOKE_RAW_DIR,   recursive = TRUE, showWarnings = FALSE)
dir.create(PM25_RAW_DIR,    recursive = TRUE, showWarnings = FALSE)
dir.create(WEATHER_RAW_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(GEO_RAW_DIR,     recursive = TRUE, showWarnings = FALSE)
dir.create(INTERMED_DIR,    recursive = TRUE, showWarnings = FALSE)
dir.create(OUT_TABLES,      recursive = TRUE, showWarnings = FALSE)
dir.create(OUT_FIGURES,     recursive = TRUE, showWarnings = FALSE)

message("PROJECT_ROOT set to: ", PROJECT_ROOT)
