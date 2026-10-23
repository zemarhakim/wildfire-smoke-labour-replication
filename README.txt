================================================================================
REPLICATION PACKAGE
Wildfire smoke increases labor hours among urban workers
Zemar Hakim and Christopher S. Cotton, Queen's University
================================================================================

CONTENTS
--------
1. Folder structure
2. Quick start
3. Obtaining raw data
4. File-by-file guide (what each script reads and writes)
5. Variable dictionary
6. Software requirements


================================================================================
1. FOLDER STRUCTURE
================================================================================

replication/
  inputs/
    raw_data/
      lfs/       LFS PUMF microdata (.sav files), as distributed by StatCan
      smoke/     NOAA HMS smoke plume shapefiles -> smoke.gpkg (built by 02_)
      pm25/      NAPS hourly PM2.5 station CSVs (downloaded by 03_)
      weather/   ECCC daily climate CSVs, one file per station
      geo/       Shapefiles: CMA boundaries, province boundaries, NFDB fire points
    intermediate/
      lfs_15_25.csv          (from 01_process_lfs.R)
      pm25.csv               (from 03_process_pm25.R)
      weather_monthly.csv    (from 05_process_weather.R, plus weather_all.csv /
                              weather_daily.csv)
      panel_month.csv        (from 06_process_panel.R -- CMA x month aggregate)
      panel_ind.csv          (from 06_process_panel.R -- individual x month;
                              this is what every table/figure script reads)
      panel_month_sample.csv / panel_ind_sample.csv (500-row previews)
  code/
    00_config.R                 <- the ONE file with a path to edit
    01_process_lfs.R
    02_process_smoke.R
    03_process_pm25.R
    04_scrape_weather.R
    05_process_weather.R
    06_process_panel.R
    07_table_replication.R
    08_density_robustness.R
    09_figures.R
    run_all.R                   <- master script, runs everything in order
  outputs/
    tables/    estimates.xlsx, density_robustness_n2020.xlsx
    figures/   fig1_fire_maps.png, fig2_industry_net.png (supplementary), fig3_smoke_maps.png (supplementary)
    estimate_map.xlsx <- maps all estimates and numbers that appear in the paper to their associated output from the code


================================================================================
2. QUICK START
================================================================================

1. Place raw data under inputs/raw_data/ (see Section 3).
2. Run code/run_all.R.

No paths need editing. To run a single script on its own, open the
replication folder (or setwd() into it) and run that script from the top.
Every script finds the replication folder automatically by looking for the
folder that contains code/00_config.R. If R can't find it (for example,
because the working directory is somewhere unrelated), run
Sys.setenv(PROJECT_ROOT = "/path/to/replication") first, as the error
message says.

Each stage writes its output to inputs/intermediate/ or outputs/ before the
next stage runs, so you do not need to re-run the whole pipeline every time.
If panel_ind.csv already exists, for instance, you can start at
07_table_replication.R and skip 01-06.


================================================================================
3. OBTAINING RAW DATA
================================================================================

LFS PUMF (inputs/raw_data/lfs/)
  Statistics Canada Labour Force Survey Public Use Microdata Files,
  2015-01 through 2025-08, monthly .sav files. Available to
  registered users via the Data Liberation Initiative (DLI) or directly from
  Statistics Canada (https://www150.statcan.gc.ca/n1/pub/71m0001x/71m0001x2021001-eng.htm).
  01_process_lfs.R expects the following folder layout inside lfs/:
    micro<year>_rebased2025/micro<year>_<month>/LFS_<MonthName>_<year>.sav
    (2025 only: micro2025/micro2025_<month>/LFS_<MonthName>_2025.sav)

NOAA HMS smoke plumes (inputs/raw_data/smoke/)
  Downloaded automatically by 02_process_smoke.R from NOAA's public archive
  (https://satepsanone.nesdis.noaa.gov/pub/FIRE/web/HMS/Smoke_Polygons/Shapefile).
  No manual download needed; requires network access.

NAPS PM2.5 station data (inputs/raw_data/pm25/)
  Downloaded automatically by 03_process_pm25.R from Environment and Climate
  Change Canada's National Air Pollution Surveillance program
  (https://www.canada.ca/en/environment-climate-change/services/air-pollution/
  monitoring-networks-data/national-air-pollution-program.html).

ECCC weather data (inputs/raw_data/weather/)
  Downloaded automatically by 04_scrape_weather.R from ECCC's bulk climate
  data endpoint (https://climate.weather.gc.ca/climate_data/bulk_data_e.html),
  for the nine study CMAs' weather stations, 2015-2024. No manual download
  needed; requires network access.

Geographic boundary files (inputs/raw_data/geo/)
  lcma000b21a_e.shp      -- Statistics Canada Census Metropolitan Area
                             boundaries (2021 Census boundary files,
                             https://www12.statcan.gc.ca/census-recensement/
                             2021/geo/sip-pis/boundary-limites/index2021-eng.cfm)
  lpr_000b21a_e.shp       -- Statistics Canada province/territory boundaries
                             (same source as above)
  NFDB_point_20250519.shp -- Canadian National Fire Database point file
                             (Natural Resources Canada,
                             https://cwfis.cfs.nrcan.gc.ca/ha/nfdb)


================================================================================
4. FILE-BY-FILE GUIDE
================================================================================

00_config.R
  Not a pipeline stage -- sets PROJECT_ROOT and every derived path (RAW_DIR,
  INTERMED_DIR, OUT_TABLES, OUT_FIGURES, and named paths to specific raw/
  intermediate files). Sourced by every other script.

01_process_lfs.R
  Reads:  inputs/raw_data/lfs/**/*.sav
  Writes: inputs/intermediate/lfs_15_25.csv
  Combines monthly LFS PUMF files (2015-01 to 2025-08) into one long CSV, one
  row per respondent-month. Includes optional diagnostic summaries (sample
  sizes by CMA/year, industry distribution, union coverage) that are not
  required for downstream steps.

02_process_smoke.R
  Reads:  none locally (downloads from NOAA)
  Writes: inputs/raw_data/smoke/smoke.gpkg
  Downloads daily HMS smoke plume shapefiles for 2015-2024, unzips them, and
  combines all days into a single GeoPackage layer ("smoke") with a
  `file_date` column. Skips files/days already present, so it can be
  interrupted and resumed.

03_process_pm25.R
  Reads:  none locally (downloads from ECCC/NAPS)
  Writes: inputs/intermediate/pm25.csv
  Downloads hourly PM2.5 readings for all NAPS stations, 2015-2025,
  canonicalizes column names (headers have changed format over the years),
  and reshapes to long format (one row per station-city, date, hour).

04_scrape_weather.R
  Reads:  none locally (downloads from ECCC)
  Writes: inputs/raw_data/weather/<City>_<Year>_<Month>.csv
  Downloads daily climate data for the nine study CMAs' weather stations
  (2015-2024) from ECCC's bulk data endpoint, one file per station-year-month.
  Ported from a standalone bash script to fit this package's path convention;
  station IDs and URL structure are unchanged from the original.

05_process_weather.R
  Reads:  inputs/raw_data/weather/*.csv
  Writes: inputs/intermediate/weather_all.csv, weather_daily.csv,
          weather_monthly.csv
  Cleans per-station daily climate records, derives wind direction bins
  (following Borgschulte, Molitor & Zou 2024's approach; wind is not used in
  the paper's final specifications but is retained for completeness/
  robustness), and aggregates to daily and monthly station-level panels.
  06_process_panel.R only reads weather_monthly.csv.

06_process_panel.R  *** the core panel-construction script ***
  Reads:  smoke.gpkg, lcma000b21a_e.shp, NFDB_point_20250519.shp, pm25.csv,
          weather_monthly.csv, lfs_15_25.csv
  Writes: inputs/intermediate/panel_month.csv (CMA x month aggregate --
          used for reduced-form/descriptive checks, not the main IV tables)
          inputs/intermediate/panel_ind.csv (individual x month -- the file
          every table/figure script actually reads)
          panel_month_sample.csv / panel_ind_sample.csv (500-row previews)
  Spatially joins smoke plumes to the nine study CMAs (25km buffer), computes
  30-day rolling PM2.5 and smoke-day exposure aligned to each LFS reference
  week, constructs every outcome/control/industry variable described in
  Section 5 below, and merges everything into the final individual-level
  panel. 

07_table_replication.R
  Reads:  panel_ind.csv
  Writes: outputs/tables/estimates.xlsx.
  hours as log(hours+1), Agriculture/Forestry/Fishing combined into one
  industry category.

08_density_robustness.R
  Reads:  panel_ind.csv, smoke.gpkg, lcma000b21a_e.shp
  Writes: outputs/tables/density_robustness_n2020.xlsx
  Re-estimates industry specification with two alternative smoke
  instruments (Medium+Heavy days only; Heavy days only, per NOAA's aerosol
  optical depth classification) instead of all plume-intersecting days. This
  is the source for the SI section ‘Robustness: smoke plume density’. 
  Does not repeat the baseline ("all smoke days") fit, since
  that's identical to Industry_Earnings/AvgHours/Absent in estimates.xlsx.

09_figures.R
  Reads:  panel_ind.csv, lpr_000b21a_e.shp, lcma000b21a_e.shp,
          NFDB_point_20250519.shp (Figure 1 only), smoke.gpkg (Figure 3 only)
  Writes: outputs/figures/fig1_fire_maps.png, fig2_industry_net.png,
          fig3_smoke_maps.png
  Three independently-toggled figures (edit fig_1_fire / fig_2_coef /
  fig_3_smoke at the top of the script):
    Figure 1 -- the paper's published wildfire location maps (Figure 1).
    Figure 2 (supplementary) -- net PM2.5 effect by industry (baseline +
      interaction combined into one number per industry).
    Figure 3 (supplementary) -- annual smoke-day density maps, Heavy-density
      plumes only.
  Each figure's data is only loaded if its toggle is on.

run_all.R
  Master script. Set PROJECT_ROOT once here and it sources every stage above
  in order.


================================================================================
5. VARIABLE DICTIONARY
================================================================================

This section documents the variables that actually feed the published
tables and figures. panel_ind.csv also contains a large number of additional
heterogeneity/exploratory variables (occupation categories, job-search
reasons, precarity indices, etc.) built in 06_process_panel.R from the same
raw LFS fields for supplementary/exploratory use; they are constructed the
same way as the variables below (weighted shares or 0/1 indicators from the
raw LFS codes) and are documented via in-line comments in that script rather
than repeated here.

---- 5.1 Raw LFS PUMF fields consumed (see StatCan's LFS PUMF data dictionary
     for the authoritative code definitions) ----

  cma, survyear, survmnth   Metro area code; survey year/month
  lfsstat                   Labour force status (1=employed-at work,
                            2=employed-absent, 3=unemployed, 4=not in labour force)
  hrlyearn                  Usual hourly wage (employees only)
  uhrsmain, ahrsmain        Usual / actual hours worked, main job (employees only)
  utothrs, atothrs          Usual / actual hours worked, all jobs (employees only)
  yabsent, wksaway, payaway, yaway, hrsaway   Absence reason/duration/pay status
  ftptmain, whypt           Full-/part-time status; reason for part-time
  mjh                       Multiple-jobholder flag
  union, permtemp, tenure   Union status; permanent/temporary status; job tenure
  paidot, unpaidot, xtrahrs Paid/unpaid overtime hours
  durunemp, lkemploy, lkatads, lkpubag, lkrels   Unemployment duration and
                            job-search method flags
  flowunem, whyleftn, ynolook   Labour-market flow / reason-for-leaving codes
  age_12, gender, marstat, educ, immig   Demographics
  cowmain                   Class of worker (1=public sector, 2=private,
                            3-6=self-employed, 7=unpaid family worker)
  estsize, firmsize         Establishment / firm size category
  agyownk, schooln          Age of youngest child; student status
  naics_21                  21-category industry classification
  noc_10                    10-category occupation classification
  finalwt                   LFS final survey weight (used in all regressions)

---- 5.2 Outcome variables (panel_ind.csv, "y_" prefix) ----

  y_emp            = 1 if lfsstat==1 (employed, at work)
  y_lfp            = 1 if lfsstat in {1,2,3} (in the labour force)
  y_log_earn       = log(hrlyearn); NA for anyone without a wage
  y_actual_hrs_main = ahrsmain (actual hours, main job, employees only).
                     Table/figure scripts derive y_log_hrs_p1 = log(hours+1)
                     from this for all main specifications
  y_condabs        = 1 if absent during the reference week, conditional on
                     being employed (lfsstat in {1,2}); NA otherwise
  (y_usual_hrs_main, y_usual_hrs_all, y_actual_hrs_all, y_hrs_away, and
  several absence/overtime/job-transition variables are also constructed but
  not used in the published tables/figures.)

---- 5.3 Instrument and endogenous regressor ----

  pm25_15_rel   CMA-demeaned mean PM2.5 (ug/m3) over the 30-day window ending
                on the LFS reference week's month-15th (the endogenous
                regressor, instrumented)
  smoke_15_rel  CMA-demeaned count of smoke-plume-intersecting days over the
                same 30-day window (the instrument)
  smoke_medh_rel, smoke_h_rel   Same construction restricted to Medium+Heavy
                or Heavy-only smoke density (08_density_robustness.R only)

---- 5.4 Weather controls ----

  mean_temp      CMA-month mean daily temperature (degrees C)
  total_precip   CMA-month total precipitation (mm)

---- 5.5 Job characteristics ----

  union, pt, small_firm, public_sector   0/1 indicators, defined directly
  from union/ftptmain/firmsize/cowmain

---- 5.6 Industry indicators (naics_21-based, one dummy each) ----

  ind_agriculture, ind_forestry, ind_fishing, ind_mining, ind_utilities,
  ind_construction, ind_manufacturing, ind_wholesale, ind_retail,
  ind_transport, ind_finance, ind_realestate, ind_professional,
  ind_business_support, ind_education, ind_healthcare, ind_info_culture,
  ind_accommodation, ind_other_services, ind_public_admin

  Manufacturing is the omitted/reference category (never appears as its own dummy in the regression
  formula). Combined category used throughout the final tables/figures:
    ind_ag_combined (table/figure scripts) /
    ind_ag_forestry_fishing (09_figures.R's appendix figure)
      = 1 if ind_agriculture + ind_forestry + ind_fishing > 0
    Agriculture, Forestry, and Fishing are individually small-n and
    imprecisely estimated; Mining is left separate since it is precisely
    estimated on its own.
  Also constructed but not used in the final tables: ind_primary (adds
  Mining to the combined category above) and ind_consumer_services
  (Retail + Accommodation combined).

---- 5.7 Geography and time ----

  cma_name   One of the nine study Census Metropolitan Areas (Quebec City,
             Montreal, Ottawa-Gatineau [Ontario part], Toronto, Hamilton,
             Winnipeg, Calgary, Edmonton, Vancouver)
  year, month, ym   Calendar year / month / year-month date
  Fixed effects used throughout: cma_name x month (seasonal-by-city) and year




================================================================================
6. SOFTWARE REQUIREMENTS
================================================================================

R (>= 4.2 recommended). Packages used across the pipeline:
  tidyverse, sf, terra, lubridate, janitor, glue, readr, haven, stringi,
  fixest, modelsummary, openxlsx, scales, fs, httr

Install via:
  install.packages(c("tidyverse", "sf", "terra", "lubridate", "janitor",
                      "glue", "readr", "haven", "stringi", "fixest",
                      "modelsummary", "openxlsx", "scales", "fs", "httr"))

sf and terra require GDAL/GEOS/PROJ system libraries; see
https://r-spatial.github.io/sf/#installing for platform-specific instructions
if install.packages() fails on those two.
