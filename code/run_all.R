# ==============================================================================
# run_all.R
# ------------------------------------------------------------------------------
# Runs the full pipeline end to end: raw data acquisition -> processing ->
# panel construction -> tables -> figures -> robustness. Edit PROJECT_ROOT
# below.
#
# WHY THIS FILE NEVER STORES ANYTHING IN AN ORDINARY R VARIABLE OR FUNCTION:
# Every stage script starts with rm(list = ls()), so that running the whole
# pipeline in one session doesn't accumulate every previous stage's data in
# memory. source() runs each stage in the same environment this script is
# executing in, so ANY R object defined here -- a CODE_DIR variable, even a
# small helper function -- would be deleted by the very first stage's
# rm(list=ls()), breaking every source() call after it. So PROJECT_ROOT is
# set as an OS environment variable (Sys.setenv/Sys.getenv), which
# rm(list=ls()) cannot touch, and each stage's path below is written out in
# full rather than built from a shared variable or function.
#
# You do not need to run this all at once. Each stage writes its output to
# disk, so you can comment out stages you've already run (e.g. once
# panel_ind.csv exists, you can skip 01-06 and just re-run 07 onward).
# ==============================================================================

Sys.setenv(PROJECT_ROOT = "/Users/zemarhakim/Library/CloudStorage/Dropbox/wildfire_canada_labour/replication")   # <-- EDIT THIS PATH

message("\n==================== STAGE 1/9: LFS data ====================")
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "01_process_lfs.R"))

message("\n==================== STAGE 2/9: Smoke data ====================")
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "02_process_smoke.R"))

message("\n==================== STAGE 3/9: PM2.5 data ====================")
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "03_process_pm25.R"))

message("\n==================== STAGE 4/9: Scrape weather data ====================")
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "04_scrape_weather.R"))

message("\n==================== STAGE 5/9: Process weather data ====================")
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "05_process_weather.R"))

message("\n==================== STAGE 6/9: Panel construction ====================")
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "06_process_panel.R"))

message("\n==================== STAGE 7/9: Tables 1-3 ====================")
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "07_table_replication.R"))

message("\n==================== STAGE 8/9: Density robustness ====================")
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "08_density_robustness.R"))

message("\n==================== STAGE 9/9: Figures 1-3 ====================")
# Toggle which figure(s) to produce inside 09_figures.R itself
# (fig_1_fire / fig_2_coef / fig_3_smoke).
source(file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "code", "09_figures.R"))

message("\n==================== PIPELINE COMPLETE ====================")
message("Tables:  ", file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "outputs", "tables"))
message("Figures: ", file.path(path.expand(Sys.getenv("PROJECT_ROOT")), "outputs", "figures"))
