# ==============================================================================
# 00_config.R
# ------------------------------------------------------------------------------
# This is the ONLY file where a path needs to be set. Every other script in
# code/ sources this file directly.
#
# HOW PROJECT_ROOT IS PASSED AROUND:
# Every script in this pipeline starts with rm(list = ls()) so that running
# the whole pipeline in one session (via run_all.R) doesn't accumulate every
# previous stage's data in memory. That means PROJECT_ROOT can't be passed
# from one script to the next as an ordinary R object -- rm(list=ls()) would
# just delete it again at the top of the next script. Instead, PROJECT_ROOT
# is read from an OS environment variable (Sys.getenv), which rm(list=ls())
# cannot touch, since it isn't an R object at all.
#
# HOW TO USE:
#   - Running the whole pipeline: open run_all.R, edit PROJECT_ROOT there
#     (it calls Sys.setenv() once, then every stage inherits it), and run
#     run_all.R.
#   - Running one script on its own: edit the PROJECT_ROOT fallback line near
#     the top of that script, then run it directly. (If PROJECT_ROOT is
#     already set as an environment variable -- e.g. you ran run_all.R
#     earlier in the same session -- that value is used instead, and the
#     fallback is ignored.)
# ==============================================================================

# PROJECT_ROOT should already be set (as an env var) by whichever script
# sourced this file. This is just a final safety net in case 00_config.R is
# ever sourced completely on its own with nothing having set it yet.
if (identical(Sys.getenv("PROJECT_ROOT"), "")) {
  Sys.setenv(PROJECT_ROOT = "~/replication")
  # <-- EDIT THIS to the folder containing inputs/, code/, and outputs/,
  #     if you are sourcing 00_config.R directly rather than via
  #     run_all.R or one of the numbered scripts.
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
