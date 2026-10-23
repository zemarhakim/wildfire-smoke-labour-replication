# ==============================================================================
# 06_process_panel.R
# ------------------------------------------------------------------------------
# INPUT:  inputs/raw_data/smoke/smoke.gpkg          (from 02_process_smoke.R)
#         inputs/raw_data/geo/lcma000b21a_e.shp     (StatCan CMA boundaries --
#                                                    see README.txt for source)
#         inputs/raw_data/geo/NFDB_point_20250519.shp (Canadian National Fire
#                                                    Database point file --
#                                                    see README.txt for source)
#         inputs/intermediate/pm25.csv              (from 03_process_pm25.R)
#         inputs/intermediate/weather_monthly.csv   (from 05_process_weather.R)
#         inputs/intermediate/lfs_15_25.csv         (from 01_process_lfs.R)
# OUTPUT: inputs/intermediate/panel_month.csv  (CMA x month aggregate panel)
#         inputs/intermediate/panel_ind.csv   (individual x month panel --
#                                              this is what every downstream
#                                              table/figure script reads)
#         inputs/intermediate/panel_month_sample.csv / panel_ind_sample.csv
#         (500-row samples for quick inspection)
# ==============================================================================

rm(list=ls())

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

# ---- Libraries ----
library(tidyverse)
library(sf)
library(lubridate)
library(janitor)
library(glue)
library(readr)
library(fixest)
library(stringi)

# Load spatial data
smoke <- st_read(SMOKE_GPKG)
cma   <- st_read(CMA_SHP)
nfdb  <- st_read(NFDB_SHP) %>%
  st_make_valid() %>%
  st_transform(3347)

# Load tabular data
pm25    <- read_csv(PM25_LONG_CSV)
weather <- read_csv(WEATHER_MONTHLY_CSV)
lfs     <- read_csv(LFS_COMBINED_CSV)

# # Quick inspection
# glimpse(smoke)
# glimpse(cma)
# glimpse(pm25)
# glimpse(weather)
# glimpse(lfs)
# glimpse(nfdb)

# ---- LFS 9 CMAs Lookup ----
lfs_cma_lookup <- tribble(
  ~cma_code, ~cma_name,
  1, "Québec",
  2, "Montréal",
  3, "Ottawa - Gatineau (Ontario part / partie de l'Ontario)",
  4, "Toronto",
  5, "Hamilton",
  6, "Winnipeg",
  7, "Calgary",
  8, "Edmonton",
  9, "Vancouver",
  0, "Other CMA or non-CMA"
)

nine_cmas <- lfs_cma_lookup$cma_name[lfs_cma_lookup$cma_code != 0]

# ---- PM2.5 City to CMA Mapping ----
city_to_cma <- tribble(
  ~city_clean,         ~cma_name,
  # BC cities
  "Chilliwack",        "Vancouver",
  "Victoria",          "Vancouver",
  "Nanaimo",           "Vancouver",
  "Kamloops",          "Vancouver",
  "Kelowna",           "Vancouver",
  "Prince George",     "Vancouver",
  # Atlantic (excluded)
  "St Johns",          "Other CMA or non-CMA",
  "Saint John",        "Other CMA or non-CMA",
  "Sydney",            "Other CMA or non-CMA",
  # Quebec
  "Montreal",          "Montréal",
  "Quebec",            "Québec",
  "Trois Rivieres",    "Montréal",
  "Shawinigan",        "Montréal",
  "Lassomption",       "Montréal",
  # Ontario
  "Ottawa",            "Ottawa - Gatineau (Ontario part / partie de l'Ontario)",
  "Toronto",           "Toronto",
  "Mississauga",       "Toronto",
  "Oshawa",            "Toronto",
  "Hamilton",          "Hamilton",
  "St Catharines",     "Hamilton",
  "Kitchener",         "Toronto",
  # Prairies
  "Winnipeg",          "Winnipeg",
  "Calgary",           "Calgary",
  "Edmonton",          "Edmonton"
)

# ---- Weather Station to CMA Mapping Function ----
station_to_cma <- function(stn) {
  s <- tolower(stn)
  case_when(
    str_detect(s, "calgary")                           ~ "Calgary",
    str_detect(s, "edmonton")                          ~ "Edmonton",
    str_detect(s, "vancouver|abbotsford|victoria|yvr") ~ "Vancouver",
    str_detect(s, "winnipeg")                          ~ "Winnipeg",
    str_detect(s, "toronto|pearson|yyz|buttonville")   ~ "Toronto",
    str_detect(s, "hamilton|mount hope")               ~ "Hamilton",
    str_detect(s, "montreal|montr")                    ~ "Montréal",
    str_detect(s, "quebec|québec|ste foy|jean lesage") ~ "Québec",
    str_detect(s, "ottawa|gatineau|kanata|rockcliffe") ~ "Ottawa - Gatineau (Ontario part / partie de l'Ontario)",
    TRUE ~ NA_character_
  )
}

# ---- CMA Lookup (CMAUID to CMANAME) ----
cma_lookup <- cma %>%
  st_drop_geometry() %>%
  select(CMAUID, CMANAME) %>%
  filter(CMANAME %in% nine_cmas)


# ---- 3A. Smoke Exposure (CMA x Month) ----

# Prepare smoke spatial data
smoke_sf <- smoke %>%
  mutate(date = as.Date(file_date)) %>%
  st_make_valid() %>%
  st_transform(3347)

# Buffer CMAs (25km to capture nearby smoke)
cma_buf <- st_buffer(st_transform(cma, 3347), 25000)

# Spatial intersection: which CMAs are exposed to smoke on which days?
smoke_intersect <- st_intersects(cma_buf, smoke_sf)

# Build smoke-CMA-date table
smoke_cma_day <- tibble(
  CMAUID  = rep(cma_buf$CMAUID, lengths(smoke_intersect)),
  CMANAME = rep(cma_buf$CMANAME, lengths(smoke_intersect)),
  date    = smoke_sf$file_date[unlist(smoke_intersect)]
) %>%
  distinct(CMAUID, CMANAME, date)

# Aggregate to monthly smoke days
smoke_cma_month <- smoke_cma_day %>%
  mutate(ym = floor_date(as.Date(date), "month")) %>%
  group_by(CMAUID, CMANAME, ym) %>%
  summarise(smoke_days = n_distinct(date), .groups = "drop") %>%
  filter(CMANAME %in% nine_cmas)

# Create complete month grid and fill missing with 0
# (We'll define all_months after processing LFS to match its time range)

# ---- 3B. PM2.5 (CMA x Month) ----

# Clean PM2.5 data
pm25_clean <- pm25 %>%
  mutate(
    city_clean = stri_trans_general(city, "Latin-ASCII"),
    city_clean = str_to_title(str_squish(str_replace_all(city_clean, "[-\\.]", " "))),
    date = as.Date(date)
  ) %>%
  filter(value >= 0)  # Drop invalid values

# Daily averages by city
pm25_daily <- pm25_clean %>%
  group_by(city_clean, date) %>%
  summarise(pm25_day = mean(value, na.rm = TRUE), .groups = "drop")

make_exposure_weeks <- function(pm25_cma_day, smoke_cma_day, lfs_ind) {
  
  message("Constructing CMA-week exposures aligned to LFS reference week...")
  
  # 1. Define reference and lag weeks for each CMA-month ------------------------
  refweek_def <- lfs_ind %>%
    distinct(cma_name, ym) %>%
    arrange(cma_name, ym) %>%
    mutate(
      mid_date   = ym + days(14),                       # ~15th of month
      ref_start  = floor_date(mid_date, "week", week_start = 1),  # Monday–Sunday
      ref_end    = ref_start + days(6),
      lag_start  = ref_start - days(7),
      lag_end    = ref_start - days(1)
    )
  
  # 2. Compute PM2.5 exposures --------------------------------------------------
  pm25_ref0 <- pm25_cma_day %>%
    inner_join(refweek_def, by = "cma_name") %>%
    filter(date >= ref_start & date <= ref_end) %>%
    group_by(cma_name, ym) %>%
    summarise(pm25_ref0 = mean(pm25_day, na.rm = TRUE), .groups = "drop")
  
  pm25_refm1 <- pm25_cma_day %>%
    inner_join(refweek_def, by = "cma_name") %>%
    filter(date >= lag_start & date <= lag_end) %>%
    group_by(cma_name, ym) %>%
    summarise(pm25_refm1 = mean(pm25_day, na.rm = TRUE), .groups = "drop")
  
  # 3. Compute smoke-day exposures ---------------------------------------------
  smoke_ref0 <- smoke_cma_day %>%
    rename(cma_name = CMANAME) %>%
    inner_join(refweek_def, by = "cma_name") %>%
    filter(date >= ref_start & date <= ref_end) %>%
    group_by(cma_name, ym) %>%
    summarise(smoke_ref0 = n_distinct(date), .groups = "drop")
  smoke_ref0 <- refweek_def %>%
    distinct(cma_name, ym) %>%
    left_join(smoke_ref0, by = c("cma_name", "ym")) %>%
    mutate(smoke_ref0 = replace_na(smoke_ref0, 0L))
  
  smoke_refm1 <- smoke_cma_day %>%
    rename(cma_name = CMANAME) %>%
    inner_join(refweek_def, by = "cma_name") %>%
    filter(date >= lag_start & date <= lag_end) %>%
    group_by(cma_name, ym) %>%
    summarise(smoke_refm1 = n_distinct(date), .groups = "drop")
  smoke_refm1 <- refweek_def %>%
    distinct(cma_name, ym) %>%
    left_join(smoke_refm1, by = c("cma_name", "ym")) %>%
    mutate(smoke_refm1 = replace_na(smoke_refm1, 0L))
  
  # 4. Merge all exposures ------------------------------------------------------
  expo_weeks <- refweek_def %>%
    left_join(pm25_ref0,  by = c("cma_name", "ym")) %>%
    left_join(pm25_refm1, by = c("cma_name", "ym")) %>%
    left_join(smoke_ref0,  by = c("cma_name", "ym")) %>%
    left_join(smoke_refm1, by = c("cma_name", "ym"))
  
  # 5. Create relative versions (demeaned within CMA) --------------------------
  expo_weeks <- expo_weeks %>%
    group_by(cma_name) %>%
    mutate(
      pm25_ref0_rel  = pm25_ref0  - mean(pm25_ref0,  na.rm = TRUE),
      pm25_refm1_rel = pm25_refm1 - mean(pm25_refm1, na.rm = TRUE),
      smoke_ref0_rel = smoke_ref0 - mean(smoke_ref0, na.rm = TRUE),
      smoke_refm1_rel = smoke_refm1 - mean(smoke_refm1, na.rm = TRUE)
    ) %>%
    ungroup()
  
  message("✓ Exposure-week variables created successfully.")
  return(expo_weeks)
}

# Monthly averages by CMA
pm25_month <- pm25_daily %>%
  left_join(city_to_cma, by = "city_clean") %>%
  filter(!is.na(cma_name), cma_name %in% nine_cmas) %>%
  mutate(ym = floor_date(date, "month")) %>%
  group_by(cma_name, ym) %>%
  summarise(pm25 = mean(pm25_day, na.rm = TRUE), .groups = "drop")

# ---- 3C. Weather (CMA x Month) ----

weather_month <- weather %>%
  clean_names() %>%
  mutate(
    month = as.numeric(month),
    year  = as.numeric(year),
    ym    = make_date(year, month, 1),
    cma_name = station_to_cma(station_name)
  ) %>%
  filter(!is.na(cma_name), cma_name %in% nine_cmas) %>%
  group_by(cma_name, ym) %>%
  summarise(
    mean_temp    = mean(mean_temp, na.rm = TRUE),
    total_precip = sum(mean_precip, na.rm = TRUE),
    # Add wind variables
    mean_wind_dir = mean(mean_wind_dir, na.rm = TRUE),
    mean_wind_speed = mean(mean_wind_speed, na.rm = TRUE),
    # Keep the most common wind bin
    wind_bin_60 = {
      bins <- na.omit(wind_bin_60)
      if(length(bins) > 0) {
        names(sort(table(bins), decreasing = TRUE))[1]
      } else {
        NA_character_
      }
    },
    wind_cardinal = {
      dirs <- na.omit(wind_cardinal)
      if(length(dirs) > 0) {
        names(sort(table(dirs), decreasing = TRUE))[1]
      } else {
        NA_character_
      }
    },
    .groups = "drop"
  )

# ---- 3D. Fire Events (CMA x Month) ----

# Clean fire data
fire_clean <- nfdb %>%
  clean_names() %>%
  mutate(
    fire_date = case_when(
      !is.na(rep_date) ~ as.Date(rep_date),
      !is.na(attk_date) ~ as.Date(attk_date),
      TRUE ~ as.Date(paste0(year, "-", month, "-", day), format = "%Y-%m-%d")
    ),
    ym = floor_date(fire_date, "month")
  ) %>%
  filter(!is.na(ym), !is.na(size_ha))

# Spatial join: fires within buffered CMAs
fire_join <- st_join(cma_buf, fire_clean, left = FALSE) %>%
  st_drop_geometry()

# Aggregate to monthly fire counts and burned area
fire_cma_month <- fire_join %>%
  group_by(CMAUID, CMANAME, ym) %>%
  summarise(
    n_fires = n_distinct(fire_id),
    total_burned = sum(size_ha, na.rm = TRUE),
    .groups = "drop"
  )

# ---- 3E. Reference-Week Exposures ----
pm25_cma_day <- pm25_daily %>%
  left_join(city_to_cma, by = "city_clean") %>%
  filter(!is.na(cma_name), cma_name %in% nine_cmas)

# Remove intermediate spatial processing objects
rm(
  smoke_sf,
  smoke_intersect,
  cma_buf,
  fire_clean,
  fire_join
)

# Remove daily-level data (already aggregated to monthly)
rm(
  pm25_clean,
  pm25_daily
  #smoke_cma_day
)

# Remove intermediate exposure calculation objects
rm(
  mid_month
  #expo_weeks
)

# Remove raw source data (already processed)
rm(
  smoke,
  pm25,
  weather,
  nfdb,
  cma  # Keep cma_lookup, but drop the full spatial object
)

# Force garbage collection to free memory
gc()

# ---- 4A. LFS Monthly Aggregates (Weighted) - FULLY EXPANDED ----
lfs_month <- lfs %>%
  clean_names() %>%
  left_join(lfs_cma_lookup, by = c("cma" = "cma_code")) %>%
  filter(cma != 0) %>%  # Drop non-CMA
  mutate(ym = make_date(survyear, as.numeric(survmnth), 1)) %>%
  group_by(cma_name, prov, ym) %>%
  summarise(
    # ---- Core Labor Market Outcomes ----
    earnings = weighted.mean(hrlyearn, finalwt, na.rm = TRUE),
    emp_rate = weighted.mean(lfsstat == 1, finalwt, na.rm = TRUE),
    lfp_rate = weighted.mean(lfsstat %in% c(1, 2), finalwt, na.rm = TRUE),
    unemp_rate = weighted.mean(lfsstat == 3, finalwt, na.rm = TRUE),
    nilf_rate = weighted.mean(lfsstat == 4, finalwt, na.rm = TRUE),
    
    # ---- Hours Worked (Intensive Margin) ----
    usual_hrs_main = weighted.mean(uhrsmain, finalwt, na.rm = TRUE),
    actual_hrs_main = weighted.mean(ahrsmain, finalwt, na.rm = TRUE),
    usual_hrs_all = weighted.mean(utothrs, finalwt, na.rm = TRUE),
    actual_hrs_all = weighted.mean(atothrs, finalwt, na.rm = TRUE),
    
    # ---- Work Absence Outcomes ----
    absent_rate = weighted.mean(lfsstat == 2, finalwt, na.rm = TRUE),
    absent_illness = weighted.mean(yabsent == 1, finalwt, na.rm = TRUE),
    absent_family = weighted.mean(yabsent == 2, finalwt, na.rm = TRUE),
    absent_vacation = weighted.mean(yabsent == 3, finalwt, na.rm = TRUE),
    weeks_absent = weighted.mean(wksaway, finalwt, na.rm = TRUE),
    paid_absence_rate = weighted.mean(payaway == 1, finalwt, na.rm = TRUE),
    
    # ---- Part-week Absence ----
    partweek_absent_illness = weighted.mean(yaway == 1, finalwt, na.rm = TRUE),
    partweek_absent_family = weighted.mean(yaway == 2, finalwt, na.rm = TRUE),
    
    # ---- Full-time vs Part-time ----
    ft_rate = weighted.mean(ftptmain == 1, finalwt, na.rm = TRUE),
    pt_rate = weighted.mean(ftptmain == 2, finalwt, na.rm = TRUE),
    pt_involuntary = weighted.mean(whypt %in% c(6, 7), finalwt, na.rm = TRUE),
    pt_illness = weighted.mean(whypt == 1, finalwt, na.rm = TRUE),
    pt_childcare = weighted.mean(whypt == 2, finalwt, na.rm = TRUE),
    
    # ---- Job Quality Indicators ----
    multiple_jobs = weighted.mean(mjh == 2, finalwt, na.rm = TRUE),
    union_rate = weighted.mean(union == 1, finalwt, na.rm = TRUE),
    covered_by_union = weighted.mean(union %in% c(1, 2), finalwt, na.rm = TRUE),
    permanent_rate = weighted.mean(permtemp == 1, finalwt, na.rm = TRUE),
    temp_rate = weighted.mean(permtemp %in% c(2, 3, 4), finalwt, na.rm = TRUE),
    temp_seasonal = weighted.mean(permtemp == 2, finalwt, na.rm = TRUE),
    temp_contract = weighted.mean(permtemp == 3, finalwt, na.rm = TRUE),
    temp_casual = weighted.mean(permtemp == 4, finalwt, na.rm = TRUE),
    
    # ---- Job Tenure ----
    avg_tenure = weighted.mean(tenure, finalwt, na.rm = TRUE),
    
    # ---- Overtime ----
    paid_ot_hrs = weighted.mean(paidot, finalwt, na.rm = TRUE),
    unpaid_ot_hrs = weighted.mean(unpaidot, finalwt, na.rm = TRUE),
    any_ot = weighted.mean(!is.na(xtrahrs) & xtrahrs > 0, finalwt, na.rm = TRUE),
    
    # ---- Unemployment & Job Search ----
    unemp_duration = weighted.mean(durunemp, finalwt, na.rm = TRUE),
    search_employer = weighted.mean(lkemploy == 1, finalwt, na.rm = TRUE),
    search_ads = weighted.mean(lkatads == 1, finalwt, na.rm = TRUE),
    search_public = weighted.mean(lkpubag == 1, finalwt, na.rm = TRUE),
    search_network = weighted.mean(lkrels == 1, finalwt, na.rm = TRUE),
    
    # ---- Labor Market Flows ----
    job_loser_rate = weighted.mean(flowunem %in% c(1, 2), finalwt, na.rm = TRUE),
    job_leaver_rate = weighted.mean(flowunem == 3, finalwt, na.rm = TRUE),
    new_entrant_rate = weighted.mean(flowunem == 5, finalwt, na.rm = TRUE),
    reentrant_rate = weighted.mean(flowunem %in% c(6, 7), finalwt, na.rm = TRUE),
    
    # ---- Reasons for Leaving/Not Working ----
    left_illness = weighted.mean(whyleftn == 1, finalwt, na.rm = TRUE),
    left_childcare = weighted.mean(whyleftn == 2, finalwt, na.rm = TRUE),
    left_business_conditions = weighted.mean(whyleftn == 12, finalwt, na.rm = TRUE),
    discouraged_rate = weighted.mean(ynolook == 6, finalwt, na.rm = TRUE),
    not_looking_illness = weighted.mean(ynolook == 1, finalwt, na.rm = TRUE),
    
    # ---- Demographics (for context) ----
    avg_age = weighted.mean(as.numeric(age_12), finalwt, na.rm = TRUE),
    female_share = weighted.mean(gender == 2, finalwt, na.rm = TRUE),
    immigrant_share = weighted.mean(immig %in% c(1, 2), finalwt, na.rm = TRUE),
    recent_immigrant_share = weighted.mean(immig == 1, finalwt, na.rm = TRUE),
    
    # ---- Age Group Shares ----
    youth_share = weighted.mean(age_12 <= 2, finalwt, na.rm = TRUE),
    prime_age_share = weighted.mean(age_12 %in% c(3:8), finalwt, na.rm = TRUE),
    older_share = weighted.mean(age_12 >= 9, finalwt, na.rm = TRUE),
    
    # ---- Education Levels ----
    low_edu_share = weighted.mean(educ %in% c(0, 1), finalwt, na.rm = TRUE),
    high_school_share = weighted.mean(educ == 2, finalwt, na.rm = TRUE),
    postsec_share = weighted.mean(educ %in% c(4, 5, 6), finalwt, na.rm = TRUE),
    high_edu_share = weighted.mean(educ %in% c(5, 6), finalwt, na.rm = TRUE),
    
    # ---- Family Structure ----
    has_children_share = weighted.mean(!is.na(agyownk), finalwt, na.rm = TRUE),
    young_children_share = weighted.mean(agyownk == 1, finalwt, na.rm = TRUE),
    
    # ---- Student Status ----
    student_share = weighted.mean(schooln %in% c(2, 3), finalwt, na.rm = TRUE),
    
    # ---- Industry Shares (All) ----
    ind_agriculture = weighted.mean(naics_21 == 1, finalwt, na.rm = TRUE),
    ind_forestry = weighted.mean(naics_21 == 2, finalwt, na.rm = TRUE),
    ind_fishing = weighted.mean(naics_21 == 3, finalwt, na.rm = TRUE),
    ind_mining = weighted.mean(naics_21 == 4, finalwt, na.rm = TRUE),
    ind_utilities = weighted.mean(naics_21 == 5, finalwt, na.rm = TRUE),
    ind_construction = weighted.mean(naics_21 == 6, finalwt, na.rm = TRUE),
    ind_manufacturing = weighted.mean(naics_21 %in% c(7, 8), finalwt, na.rm = TRUE),
    ind_wholesale = weighted.mean(naics_21 == 9, finalwt, na.rm = TRUE),
    ind_retail = weighted.mean(naics_21 == 10, finalwt, na.rm = TRUE),
    ind_transport = weighted.mean(naics_21 == 11, finalwt, na.rm = TRUE),
    ind_finance = weighted.mean(naics_21 == 12, finalwt, na.rm = TRUE),
    ind_realestate = weighted.mean(naics_21 == 13, finalwt, na.rm = TRUE),
    ind_professional = weighted.mean(naics_21 == 14, finalwt, na.rm = TRUE),
    ind_business_support = weighted.mean(naics_21 == 15, finalwt, na.rm = TRUE),
    ind_education = weighted.mean(naics_21 == 16, finalwt, na.rm = TRUE),
    ind_healthcare = weighted.mean(naics_21 == 17, finalwt, na.rm = TRUE),
    ind_info_culture = weighted.mean(naics_21 == 18, finalwt, na.rm = TRUE),
    ind_accommodation = weighted.mean(naics_21 == 19, finalwt, na.rm = TRUE),
    ind_other_services = weighted.mean(naics_21 == 20, finalwt, na.rm = TRUE),
    ind_public_admin = weighted.mean(naics_21 == 21, finalwt, na.rm = TRUE),
    
    # ---- Broad Industry Categories ----
    ind_goods = weighted.mean(naics_21 %in% c(1:8), finalwt, na.rm = TRUE),
    ind_services = weighted.mean(naics_21 %in% c(9:21), finalwt, na.rm = TRUE),
    ind_primary = weighted.mean(naics_21 %in% c(1, 2, 3, 4), finalwt, na.rm = TRUE),
    
    # ---- Occupation Shares ----
    occ_management = weighted.mean(noc_10 == 1, finalwt, na.rm = TRUE),
    occ_business = weighted.mean(noc_10 == 2, finalwt, na.rm = TRUE),
    occ_sciences = weighted.mean(noc_10 == 3, finalwt, na.rm = TRUE),
    occ_health = weighted.mean(noc_10 == 4, finalwt, na.rm = TRUE),
    occ_education_social = weighted.mean(noc_10 == 5, finalwt, na.rm = TRUE),
    occ_arts = weighted.mean(noc_10 == 6, finalwt, na.rm = TRUE),
    occ_sales_service = weighted.mean(noc_10 == 7, finalwt, na.rm = TRUE),
    occ_trades = weighted.mean(noc_10 == 8, finalwt, na.rm = TRUE),
    occ_natural_resources = weighted.mean(noc_10 == 9, finalwt, na.rm = TRUE),
    occ_manufacturing_occ = weighted.mean(noc_10 == 10, finalwt, na.rm = TRUE),
    
    # ---- Sector ----
    public_sector = weighted.mean(cowmain == 1, finalwt, na.rm = TRUE),
    private_sector = weighted.mean(cowmain == 2, finalwt, na.rm = TRUE),
    self_employed = weighted.mean(cowmain %in% c(3, 4, 5, 6), finalwt, na.rm = TRUE),
    
    # ---- Firm Size ----
    small_firm_share = weighted.mean(firmsize == 1, finalwt, na.rm = TRUE),
    large_firm_share = weighted.mean(firmsize == 4, finalwt, na.rm = TRUE),
    
    # ========================================
    # EXPOSURE & VULNERABILITY PROXIES
    # ========================================
    
    # ---- Outdoor Work ----
    outdoor_work_share = weighted.mean(
      naics_21 %in% c(1, 2, 3, 4, 6) | noc_10 %in% c(8, 9), 
      finalwt, na.rm = TRUE
    ),
    outdoor_industry_share = weighted.mean(
      naics_21 %in% c(1, 2, 3, 4, 6), 
      finalwt, na.rm = TRUE
    ),
    outdoor_occupation_share = weighted.mean(
      noc_10 %in% c(8, 9), 
      finalwt, na.rm = TRUE
    ),
    
    # ---- Semi-Outdoor/Mobile ----
    semi_outdoor_share = weighted.mean(
      naics_21 %in% c(5, 11, 15), 
      finalwt, na.rm = TRUE
    ),
    
    # ---- Work Environment ----
    climate_controlled_share = weighted.mean(
      naics_21 %in% c(12, 14, 16, 18, 21) & noc_10 %in% c(1, 2, 3, 5),
      finalwt, na.rm = TRUE
    ),
    industrial_indoor_share = weighted.mean(
      naics_21 %in% c(7, 8, 9) | noc_10 == 10,
      finalwt, na.rm = TRUE
    ),
    
    # ---- Physical Exertion ----
    high_exertion_share = weighted.mean(
      naics_21 %in% c(1, 2, 3, 6, 7, 8, 11) | noc_10 %in% c(8, 9, 10),
      finalwt, na.rm = TRUE
    ),
    manual_labor_share = weighted.mean(
      noc_10 %in% c(8, 9, 10),
      finalwt, na.rm = TRUE
    ),
    
    # ---- Work Flexibility ----
    inflexible_location_share = weighted.mean(
      naics_21 %in% c(1:11, 15, 16, 17, 19, 21) | noc_10 %in% c(7, 8, 9, 10),
      finalwt, na.rm = TRUE
    ),
    can_wfh_share = weighted.mean(
      naics_21 %in% c(12, 14, 18) & noc_10 %in% c(1, 2, 3),
      finalwt, na.rm = TRUE
    ),
    
    # ---- Essential Workers ----
    essential_worker_share = weighted.mean(
      naics_21 %in% c(5, 16, 17, 21) | noc_10 %in% c(4, 5),
      finalwt, na.rm = TRUE
    ),
    healthcare_worker_share = weighted.mean(
      naics_21 == 17 | noc_10 == 4,
      finalwt, na.rm = TRUE
    ),
    
    # ---- Customer-Facing ----
    customer_facing_share = weighted.mean(
      naics_21 %in% c(10, 12, 19, 20) | noc_10 == 7,
      finalwt, na.rm = TRUE
    ),
    
    # ---- Precarity/Vulnerability ----
    precarious_share = weighted.mean(
      permtemp %in% c(2, 3, 4) | (union == 3 & ftptmain == 2),
      finalwt, na.rm = TRUE
    ),
    vulnerable_worker_share = weighted.mean(
      educ %in% c(0, 1) | immig == 1 | permtemp %in% c(2, 3, 4) | age_12 <= 2,
      finalwt, na.rm = TRUE
    ),
    health_sensitive_share = weighted.mean(
      age_12 >= 9 | agyownk == 1 | age_12 <= 2,
      finalwt, na.rm = TRUE
    ),
    
    # ---- Professional Status ----
    professional_share = weighted.mean(
      noc_10 %in% c(1, 2, 3, 4, 5),
      finalwt, na.rm = TRUE
    ),
    
    .groups = "drop"
  )



# Define complete month grid based on LFS time range
all_months <- tibble(ym = sort(unique(lfs_month$ym)))

# Complete the smoke grid
smoke_cma_month <- cma_lookup %>%
  crossing(all_months) %>%
  left_join(smoke_cma_month, by = c("CMAUID", "CMANAME", "ym")) %>%
  mutate(smoke_days = replace_na(smoke_days, 0))

# Complete fire grid
all_fire_months <- tibble(ym = seq.Date(
  from = min(fire_cma_month$ym, na.rm = TRUE),
  to   = max(fire_cma_month$ym, na.rm = TRUE),
  by   = "month"
))

fire_cma_month <- cma_lookup %>%
  crossing(all_fire_months) %>%
  left_join(fire_cma_month, by = c("CMAUID", "CMANAME", "ym")) %>%
  mutate(
    n_fires = replace_na(n_fires, 0),
    total_burned = replace_na(total_burned, 0)
  )

# ---- 4B. LFS Individual-Level Data ----

lfs_ind <- lfs %>%
  clean_names() %>%
  left_join(lfs_cma_lookup, by = c("cma" = "cma_code")) %>%
  filter(cma != 0) %>%
  mutate(
    ym = make_date(survyear, as.numeric(survmnth), 1),
    year  = year(ym),
    month = month(ym),
    
    # ========================================
    # OUTCOME VARIABLES
    # ========================================
    
    # ---- Primary Outcomes ----
    y_earn = hrlyearn,
    y_emp = as.integer(lfsstat == 1),
    y_lfp = as.integer(lfsstat %in% c(1, 2, 3)),
    y_unemp = as.integer(lfsstat == 3),
    y_nilf = as.integer(lfsstat == 4),
    
    # ---- Work Intensity (Hours) ----
    y_usual_hrs_main = uhrsmain,
    y_actual_hrs_main = ahrsmain,
    y_usual_hrs_all = utothrs,
    y_actual_hrs_all = atothrs,
    
    # ---- Absence Outcomes ----
    y_absent = as.integer(lfsstat == 2),
    y_atwork = as.integer(lfsstat == 1),
    y_condabs = ifelse(lfsstat %in% c(1, 2), as.integer(lfsstat == 2), NA),
    y_absent_illness = as.integer(yabsent == 1),
    y_absent_family = as.integer(yabsent == 2),
    y_absent_vacation = as.integer(yabsent == 3),
    y_weeks_absent = wksaway,
    y_paid_absence = as.integer(payaway == 1),
    
    # # ---- Part-week Absence ----
    y_partweek_absent_illness = as.integer(yaway == 1),
    y_partweek_absent_family = as.integer(yaway == 2),
    y_hrs_away = hrsaway,
    
    # ---- Full-time vs Part-time ----
    y_fulltime = as.integer(ftptmain == 1),
    y_parttime = as.integer(ftptmain == 2),
    y_pt_involuntary = as.integer(whypt %in% c(6, 7)),
    y_pt_illness = as.integer(whypt == 1),
    y_pt_childcare = as.integer(whypt == 2),
    
    # ---- Job Quality ----
    y_multiple_jobs = as.integer(mjh == 2),
    y_union = as.integer(union == 1),
    y_covered_by_union = as.integer(union %in% c(1, 2)),
    y_permanent = as.integer(permtemp == 1),
    y_temporary = as.integer(permtemp %in% c(2, 3, 4)),
    y_temp_seasonal = as.integer(permtemp == 2),
    y_temp_contract = as.integer(permtemp == 3),
    y_temp_casual = as.integer(permtemp == 4),
    y_tenure = tenure,
    
    # ---- Overtime ----
    y_paid_ot = paidot,
    y_unpaid_ot = unpaidot,
    y_any_ot = as.integer(!is.na(xtrahrs) & xtrahrs > 0),
    
    # ---- Unemployment Duration & Search ----
    y_unemp_duration = durunemp,
    y_search_employer = as.integer(lkemploy == 1),
    y_search_ads = as.integer(lkatads == 1),
    y_search_public_agency = as.integer(lkpubag == 1),
    y_search_network = as.integer(lkrels == 1),
    
    # ---- Labor Market Transitions ----
    y_job_loser = as.integer(flowunem %in% c(1, 2)),
    y_job_loser_temp = as.integer(flowunem == 1),
    y_job_loser_perm = as.integer(flowunem == 2),
    y_job_leaver = as.integer(flowunem == 3),
    y_new_entrant = as.integer(flowunem == 5),
    y_reentrant = as.integer(flowunem %in% c(6, 7)),
    
    # ---- Reason for Job Leaving (detailed) ----
    y_left_illness = as.integer(whyleftn == 1),
    y_left_childcare = as.integer(whyleftn == 2),
    y_left_dissatisfied = as.integer(whyleftn == 6),
    y_left_business_closed = as.integer(whyleftn %in% c(8, 11)),
    y_left_business_conditions = as.integer(whyleftn == 12),
    
    # ---- Discouraged Workers ----
    y_discouraged = as.integer(ynolook == 6),
    y_not_looking_illness = as.integer(ynolook == 1),
    y_not_looking_childcare = as.integer(ynolook == 2),
    
    # ========================================
    # CONTROL VARIABLES & HETEROGENEITY
    # ========================================
    
    # ---- Demographics ----
    age = as.numeric(age_12),
    age_sq = as.numeric(age_12)^2,
    female = as.integer(gender == 2),
    married = as.integer(marstat %in% c(1, 2)),
    
    # ---- Age Groups for Heterogeneity ----
    age_15_24 = as.integer(age_12 %in% c(1, 2)),
    age_25_34 = as.integer(age_12 %in% c(3, 4)),
    age_35_44 = as.integer(age_12 %in% c(5, 6)),
    age_45_54 = as.integer(age_12 %in% c(7, 8)),
    age_55_plus = as.integer(age_12 >= 9),
    age_youth = as.integer(age_12 <= 2),
    age_prime = as.integer(age_12 %in% c(3:8)),
    age_older = as.integer(age_12 >= 9),
    
    # ---- Education ----
    educ_cat = factor(educ),
    low_edu = as.integer(educ %in% c(0, 1)),
    high_school = as.integer(educ == 2),
    some_postsec = as.integer(educ == 3),
    postsec_cert = as.integer(educ == 4),
    bachelors = as.integer(educ == 5),
    above_bachelors = as.integer(educ == 6),
    high_edu = as.integer(educ %in% c(5, 6)),
    
    # ---- Immigration Status ----
    immigrant = as.integer(immig %in% c(1, 2)),
    recent_immigrant = as.integer(immig == 1),
    established_immigrant = as.integer(immig == 2),
    
    # ---- Job Characteristics ----
    union = as.integer(union == 1),
    covered_by_union = as.integer(union %in% c(1, 2)),
    non_union = as.integer(union == 3),
    ft = as.integer(ftptmain == 1),
    pt = as.integer(ftptmain == 2),
    public_sector = as.integer(cowmain == 1),
    private_sector = as.integer(cowmain == 2),
    self_employed = as.integer(cowmain %in% c(3, 4, 5, 6)),
    self_employed_incorp = as.integer(cowmain %in% c(3, 4)),
    self_employed_unincorp = as.integer(cowmain %in% c(5, 6)),
    
    # ---- Establishment/Firm Size ----
    small_establishment = as.integer(estsize == 1),
    large_establishment = as.integer(estsize == 4),
    small_firm = as.integer(firmsize == 1),
    large_firm = as.integer(firmsize == 4),
    
    # ---- Family Structure ----
    agyownk = na_if(trimws(agyownk), ""),   # turn blanks into NA
    agyownk = as.numeric(agyownk),          # convert to numeric if read as char

    # --- Child indicators ---
    has_children        = as.integer(!is.na(agyownk)),  # 1 if any child <25
    young_children      = as.integer(agyownk == 1),     # youngest <6
    school_age_children = as.integer(agyownk == 2),     # 6–12
    teen_children       = as.integer(agyownk == 3),     # 13–17
    adult_children      = as.integer(agyownk == 4),      # 18–24 (still at home)
    
    # ---- Student Status ----
    student = as.integer(schooln %in% c(2, 3)),
    fulltime_student = as.integer(schooln == 2),
    parttime_student = as.integer(schooln == 3),
    
    # ========================================
    # POLLUTION EXPOSURE & VULNERABILITY PROXIES
    # ========================================
    
    # ---- Outdoor Work (Primary Exposure Proxy) ----
    outdoor_industry = as.integer(naics_21 %in% c(1, 2, 3, 4, 6)),
    outdoor_occupation = as.integer(noc_10 %in% c(8, 9)),
    outdoor_work = as.integer(
      naics_21 %in% c(1, 2, 3, 4, 6) | noc_10 %in% c(8, 9)
    ),
    
    # ---- Specific Outdoor Industries ----
    ind_agriculture = as.integer(naics_21 == 1),
    ind_forestry = as.integer(naics_21 == 2),
    ind_fishing = as.integer(naics_21 == 3),
    ind_mining = as.integer(naics_21 == 4),
    ind_utilities = as.integer(naics_21 == 5),
    ind_construction = as.integer(naics_21 == 6),
    ind_manufacturing = as.integer(naics_21 %in% c(7, 8)),
    ind_wholesale = as.integer(naics_21 == 9),
    ind_retail = as.integer(naics_21 == 10),
    ind_transport = as.integer(naics_21 == 11),
    ind_finance = as.integer(naics_21 == 12),
    ind_realestate = as.integer(naics_21 == 13),
    ind_professional = as.integer(naics_21 == 14),
    ind_business_support = as.integer(naics_21 == 15),
    ind_education = as.integer(naics_21 == 16),
    ind_healthcare = as.integer(naics_21 == 17),
    ind_info_culture = as.integer(naics_21 == 18),
    ind_accommodation = as.integer(naics_21 == 19),
    ind_other_services = as.integer(naics_21 == 20),
    ind_public_admin = as.integer(naics_21 == 21),
    
    # ---- Semi-Outdoor/Mobile Work ----
    semi_outdoor = as.integer(naics_21 %in% c(5, 11, 15)),
    delivery_logistics = as.integer(
      naics_21 %in% c(9, 10, 11) | noc_10 == 8
    ),
    
    # ---- Indoor Work Environment Quality ----
    climate_controlled = as.integer(
      naics_21 %in% c(12, 14, 16, 18, 21) & 
      noc_10 %in% c(1, 2, 3, 5) & 
      cowmain != 7
    ),
    industrial_indoor = as.integer(
      naics_21 %in% c(7, 8, 9) | noc_10 == 10
    ),
    
    # ---- Physical Exertion (more air intake) ----
    high_exertion = as.integer(
      naics_21 %in% c(1, 2, 3, 6, 7, 8, 11) | 
      noc_10 %in% c(8, 9, 10)
    ),
    manual_labor = as.integer(noc_10 %in% c(8, 9, 10)),
    
    # ---- Work Location Flexibility ----
    inflexible_location = as.integer(
      naics_21 %in% c(1:11, 15, 16, 17, 19, 21) | 
      noc_10 %in% c(7, 8, 9, 10)
    ),
    can_work_from_home = as.integer(
      naics_21 %in% c(12, 14, 18) & 
      noc_10 %in% c(1, 2, 3)
    ),
    
    # ---- Essential Workers ----
    essential_worker = as.integer(
      naics_21 %in% c(5, 16, 17, 21) | 
      noc_10 %in% c(4, 5)
    ),
    healthcare_worker = as.integer(
      naics_21 == 17 | noc_10 == 4
    ),
    education_worker = as.integer(
      naics_21 == 16 | noc_10 == 5
    ),
    
    # ---- Customer-Facing/Public Contact ----
    customer_facing = as.integer(
      naics_21 %in% c(10, 12, 19, 20) | 
      noc_10 == 7
    ),
    
    # ---- Job Precarity/Vulnerability ----
    precarious_job = as.integer(
      permtemp %in% c(2, 3, 4) | 
      (union == 3 & ftptmain == 2) |
      cowmain == 7
    ),
    temp_job = as.integer(permtemp %in% c(2, 3, 4)),
    no_union_protection = as.integer(union == 3),
    
    # ---- Employer Size (proxy for benefits/protections) ----
    small_employer_est = as.integer(estsize == 1),
    small_employer_firm = as.integer(firmsize == 1),
    large_employer = as.integer(estsize == 4 | firmsize == 4),
    
    # ---- Composite Vulnerability Indicators ----
    vulnerable_worker = as.integer(
      low_edu == 1 | 
      recent_immigrant == 1 | 
      permtemp %in% c(2, 3, 4) | 
      age_15_24 == 1 |
      (ftptmain == 2 & union == 3)
    ),
    
    health_sensitive = as.integer(
      age_55_plus == 1 | 
      young_children == 1 |
      age_15_24 == 1
    ),
    
    high_pollution_exposure = as.integer(
      (naics_21 %in% c(1, 2, 3, 4, 6) | noc_10 %in% c(8, 9)) &
      !(naics_21 %in% c(12, 14, 16, 18) & noc_10 %in% c(1, 2))
    ),
    
    limited_job_protections = as.integer(
      union == 3 & 
      (estsize == 1 | firmsize == 1) &
      permtemp %in% c(2, 3, 4)
    ),
    
    # ---- Industry Categories (broader) ----
    ind_goods = as.integer(naics_21 %in% c(1:8)),
    ind_services = as.integer(naics_21 %in% c(9:21)),
    ind_primary = as.integer(naics_21 %in% c(1, 2, 3, 4)),
    
    # ---- Occupation Categories (NOC_10) ----
    occ_management = as.integer(noc_10 == 1),
    occ_business = as.integer(noc_10 == 2),
    occ_sciences = as.integer(noc_10 == 3),
    occ_health = as.integer(noc_10 == 4),
    occ_education_social = as.integer(noc_10 == 5),
    occ_arts = as.integer(noc_10 == 6),
    occ_sales_service = as.integer(noc_10 == 7),
    occ_trades = as.integer(noc_10 == 8),
    occ_natural_resources = as.integer(noc_10 == 9),
    occ_manufacturing = as.integer(noc_10 == 10),
    
    # ---- Professional vs Non-Professional ----
    professional = as.integer(noc_10 %in% c(1, 2, 3, 4, 5)),
    non_professional = as.integer(noc_10 %in% c(7, 8, 9, 10))
  ) %>%
  select(
    # Identifiers
    rec_num, prov, cma_name, ym, year, month,
    
    # All outcome variables (y_*)
    starts_with("y_"),
    
    # Demographics
    age, age_sq, female, married,
    
    # Age groups
    starts_with("age_"),
    
    # Education
    educ_cat, low_edu, high_school, some_postsec, 
    postsec_cert, bachelors, above_bachelors, high_edu,
    
    # Immigration
    immigrant, recent_immigrant, established_immigrant,
    
    # Job characteristics
    union, covered_by_union, non_union, ft, pt,
    public_sector, private_sector, 
    self_employed, self_employed_incorp, self_employed_unincorp,
    
    # Firm/establishment size
    small_establishment, large_establishment,
    small_firm, large_firm,
    small_employer_est, small_employer_firm, large_employer,
    
    # Family & student
    has_children, young_children, school_age_children, teen_children,
    student, fulltime_student, parttime_student,
    
    # Outdoor/exposure indicators
    outdoor_industry, outdoor_occupation, outdoor_work,
    ind_agriculture, ind_forestry, ind_fishing, ind_mining, 
    ind_utilities, ind_construction, ind_manufacturing,
    ind_wholesale, ind_retail, ind_transport, ind_finance,
    ind_realestate, ind_professional, ind_business_support,
    ind_education, ind_healthcare, ind_info_culture,
    ind_accommodation, ind_other_services, ind_public_admin,
    semi_outdoor, delivery_logistics,
    
    # Work environment
    climate_controlled, industrial_indoor,
    high_exertion, manual_labor,
    inflexible_location, can_work_from_home,
    
    # Essential/customer-facing
    essential_worker, healthcare_worker, education_worker,
    customer_facing,
    
    # Precarity/vulnerability
    precarious_job, temp_job, no_union_protection,
    vulnerable_worker, health_sensitive,
    high_pollution_exposure, limited_job_protections,
    
    # Industry categories
    ind_goods, ind_services, ind_primary,
    
    # Occupation categories
    starts_with("occ_"),
    professional, non_professional,
    
    # Survey weight
    finalwt
  )

message("Constructing 15→15 month exposure windows...")

# Step 1: Define 15th of each month for each CMA-month
mid_month <- lfs_ind %>%
  distinct(cma_name, ym) %>%
  arrange(cma_name, ym) %>%
  mutate(
    mid      = ym + days(14),         # ≈ 15th of month
    win_start = mid - months(1),      # previous 15th
    win_end   = mid                   # current 15th
  )

# Step 2: Smoke exposure (count distinct days)
smoke_15 <- smoke_cma_day %>%
  rename(cma_name = CMANAME) %>%
  inner_join(mid_month, by = "cma_name") %>%
  filter(date >= win_start & date <= win_end) %>%
  group_by(cma_name, ym) %>%
  summarise(
    smoke_15 = n_distinct(date),
    .groups = "drop"
  )

smoke_15 <- mid_month %>%
  distinct(cma_name, ym) %>%
  left_join(smoke_15, by = c("cma_name", "ym")) %>%
  mutate(smoke_15 = replace_na(smoke_15, 0L))

# Step 3: PM2.5 exposure (mean)
pm25_15 <- pm25_cma_day %>%
  inner_join(mid_month, by = "cma_name") %>%
  filter(date >= win_start & date <= win_end) %>%
  group_by(cma_name, ym) %>%
  summarise(
    pm25_15 = mean(pm25_day, na.rm = TRUE),
    .groups = "drop"
  )

# Step 4: Relative (demeaned within CMA)
smoke_15 <- smoke_15 %>%
  group_by(cma_name) %>%
  mutate(smoke_15_rel = smoke_15 - mean(smoke_15, na.rm = TRUE)) %>%
  ungroup()

pm25_15 <- pm25_15 %>%
  group_by(cma_name) %>%
  mutate(pm25_15_rel = pm25_15 - mean(pm25_15, na.rm = TRUE)) %>%
  ungroup()

message("✓ Created smoke_15, pm25_15, smoke_15_rel, pm25_15_rel (grid-completed for smoke)")

# ==============================================================================
# 5. MERGE PANELS
# ==============================================================================

# ---- 5A. Monthly Aggregate Panel (for Reduced Form) ----

panel_month <- lfs_month %>%
  left_join(cma_lookup, by = c("cma_name" = "CMANAME")) %>%
  left_join(smoke_cma_month, by = c("CMAUID", "cma_name" = "CMANAME", "ym")) %>%
  left_join(pm25_month, by = c("cma_name", "ym")) %>%
  left_join(weather_month, by = c("cma_name", "ym")) %>%
  left_join(fire_cma_month, by = c("CMAUID", "cma_name" = "CMANAME", "ym")) %>%  
  mutate(
    year  = year(ym),
    month = month(ym),
    ym_str = format(ym, "%Y-%m"),
    # Fill exposure NAs
    smoke_days = replace_na(smoke_days, 0),
    n_fires = replace_na(n_fires, 0),           
    total_burned = replace_na(total_burned, 0)     
  ) %>%
  mutate(
    wind_0_60 = as.integer(wind_bin_60 == "bin_0_60"),
    wind_60_120 = as.integer(wind_bin_60 == "bin_60_120"),
    wind_120_180 = as.integer(wind_bin_60 == "bin_120_180"),
    wind_180_240 = as.integer(wind_bin_60 == "bin_180_240"),
    wind_240_300 = as.integer(wind_bin_60 == "bin_240_300"),
    wind_300_360 = as.integer(wind_bin_60 == "bin_300_360")
  ) %>%
  arrange(cma_name, ym)

# Sanity check: one row per CMA × month
stopifnot(nrow(panel_month) == nrow(distinct(panel_month, cma_name, ym)))

cat("\n✓ Monthly panel created successfully\n")
cat("  Dimensions:", nrow(panel_month), "rows ×", ncol(panel_month), "columns\n")
cat("  Time range:", min(panel_month$year), "to", max(panel_month$year), "\n")
cat("  CMAs:", n_distinct(panel_month$cma_name), "\n")

# ---- 5B. Individual-Level Panel (for IV Analysis) ----

# Helper function to normalize date formats
norm_ym <- function(x) {
  if (inherits(x, "Date")) x else as.Date(paste0(x, "-01"))
}

# Ensure consistent date formats across exposure tables
smoke_cma_month <- smoke_cma_month %>% mutate(ym = norm_ym(ym))
pm25_month      <- pm25_month %>% mutate(ym = norm_ym(ym))
weather_month   <- weather_month %>% mutate(ym = norm_ym(ym))
fire_cma_month  <- fire_cma_month %>% mutate(ym = norm_ym(ym))

# Merge individual LFS with exposures
ind_expo <- lfs_ind %>%
  left_join(cma_lookup, by = c("cma_name" = "CMANAME")) %>%
  left_join(smoke_cma_month, by = c("CMAUID", "cma_name" = "CMANAME", "ym")) %>%
  left_join(pm25_month, by = c("cma_name", "ym")) %>%
  left_join(weather_month, by = c("cma_name", "ym")) %>%
  left_join(fire_cma_month, by = c("CMAUID", "cma_name" = "CMANAME", "ym")) %>%
  mutate(
    smoke_days   = replace_na(smoke_days, 0),
    n_fires      = replace_na(n_fires, 0),
    total_burned = replace_na(total_burned, 0)
    # Keep pm25, mean_temp, total_precip as-is (may have NAs for filtering)
  )

expo_weeks <- make_exposure_weeks(pm25_cma_day, smoke_cma_day, lfs_ind)

ind_expo <- ind_expo %>%
  left_join(expo_weeks, by = c("cma_name", "ym")) %>%
  left_join(smoke_15, by = c("cma_name", "ym")) %>%
  left_join(pm25_15,  by = c("cma_name", "ym"))

cat("\n✓ Individual-level panel created successfully\n")
cat("  Dimensions:", nrow(ind_expo), "rows ×", ncol(ind_expo), "columns\n")
cat("  Observations:", format(nrow(ind_expo), big.mark = ","), "\n")



# ---- 6. Prep IV Data Set -----

panel_ind <- ind_expo %>%
  filter(
    !is.na(pm25), 
    !is.na(smoke_days),
    !is.na(mean_temp), 
    !is.na(total_precip)
  ) %>%
  mutate(
    cma_fe    = cma_name,
    prov_name = case_when(
      prov == 24 ~ "QC",
      prov == 35 ~ "ON",
      prov == 46 ~ "MB",
      prov == 48 ~ "AB",
      prov == 59 ~ "BC",
      TRUE ~ "OTHER"
    ),
    prov_year = paste0(prov_name, "_", year),

    
    # Log earnings (for log-linear specs)
    y_log_earn = log(y_earn),  # NA for unemployed, which is CORRECT
    
    # Earnings conditional on employment
    y_earn_cond = ifelse(y_emp == 1, y_earn, NA_real_)
  )

# Add wind dummies to individual panel
panel_ind <- panel_ind %>%
  mutate(
    wind_0_60 = as.integer(wind_bin_60 == "bin_0_60"),
    wind_60_120 = as.integer(wind_bin_60 == "bin_60_120"),
    wind_120_180 = as.integer(wind_bin_60 == "bin_120_180"),
    wind_180_240 = as.integer(wind_bin_60 == "bin_180_240"),
    wind_240_300 = as.integer(wind_bin_60 == "bin_240_300"),
    wind_300_360 = as.integer(wind_bin_60 == "bin_300_360")
  )

cat("\n✓ IV analysis dataset created successfully\n")
cat("  Dimensions:", nrow(panel_ind), "rows ×", ncol(panel_ind), "columns\n")
cat("  Observations with complete data:", format(nrow(panel_ind), big.mark = ","), "\n")
cat("  % of original sample:", round(100 * nrow(panel_ind) / nrow(ind_expo), 1), "%\n")

cat("\n" , rep("=", 80), "\n", sep = "")
cat("DATA QUALITY CHECKS\n")
cat(rep("=", 80), "\n", sep = "")

# ---- Monthly Panel Checks ----
cat("\n[MONTHLY PANEL]\n")

# Check for duplicates
dups <- panel_month %>%
  group_by(cma_name, ym) %>%
  filter(n() > 1) %>%
  nrow()

if (dups > 0) {
  warning("⚠ Found ", dups, " duplicate CMA-month observations!")
} else {
  cat("✓ No duplicate CMA-month observations\n")
}

# Check smoke exposure distribution
cat("\nSmoke exposure summary:\n")
panel_month %>%
  summarise(
    mean_smoke_days = mean(smoke_days, na.rm = TRUE),
    median_smoke_days = median(smoke_days, na.rm = TRUE),
    max_smoke_days = max(smoke_days, na.rm = TRUE),
    pct_with_smoke = mean(smoke_days > 0) * 100
  ) %>%
  print()

# Check PM2.5 availability
cat("\nPM2.5 coverage:\n")
panel_month %>%
  summarise(
    n_obs = n(),
    n_with_pm25 = sum(!is.na(pm25)),
    pct_coverage = round(100 * n_with_pm25 / n_obs, 1)
  ) %>%
  print()

# ---- Individual Panel Checks ----
cat("\n[INDIVIDUAL-LEVEL PANEL]\n")

# Check outcome variable completeness
cat("\nOutcome variable completeness:\n")
panel_ind %>%
  summarise(
    earn_complete = sum(!is.na(y_earn)),
    emp_complete = sum(!is.na(y_emp)),
    lfp_complete = sum(!is.na(y_lfp)),
    hrs_complete = sum(!is.na(y_actual_hrs_main)),
    n_total = n()
  ) %>%
  mutate(across(ends_with("complete"), ~round(100 * . / n_total, 1))) %>%
  print()

# Check exposure proxies
cat("\nExposure proxy distribution:\n")
panel_ind %>%
  summarise(
    outdoor_work_pct = mean(outdoor_work, na.rm = TRUE) * 100,
    vulnerable_worker_pct = mean(vulnerable_worker, na.rm = TRUE) * 100,
    health_sensitive_pct = mean(health_sensitive, na.rm = TRUE) * 100,
    high_pollution_exposure_pct = mean(high_pollution_exposure, na.rm = TRUE) * 100
  ) %>%
  print()

# Check survey weights
cat("\nSurvey weights check:\n")
panel_ind %>%
  summarise(
    n_missing_weights = sum(is.na(finalwt)),
    min_weight = min(finalwt, na.rm = TRUE),
    mean_weight = mean(finalwt, na.rm = TRUE),
    max_weight = max(finalwt, na.rm = TRUE)
  ) %>%
  print()


# ----7.  Preview ----


cat("\n", rep("=", 80), "\n", sep = "")
cat("DATA PREVIEW\n")
cat(rep("=", 80), "\n", sep = "")

cat("\n[MONTHLY PANEL - First 10 rows]\n")
panel_month %>% 
  select(cma_name, ym, smoke_days, pm25, n_fires, 
         earnings, emp_rate, absent_rate, outdoor_work_share) %>% 
  head(10) %>%
  print()

cat("\n[INDIVIDUAL PANEL - First 10 rows]\n")
panel_ind %>%
  select(cma_name, ym, smoke_days, pm25, y_earn, y_emp, 
         outdoor_work, vulnerable_worker, finalwt) %>%
  head(10) %>%
  print()




# ---- 8. Summary Stats ----

cat("\n", rep("=", 80), "\n", sep = "")
cat("SUMMARY STATISTICS\n")
cat(rep("=", 80), "\n", sep = "")

cat("\n[KEY OUTCOMES - Weighted Means]\n")
panel_ind %>%
  summarise(
    mean_earnings = weighted.mean(y_earn, finalwt, na.rm = TRUE),
    emp_rate = weighted.mean(y_emp, finalwt, na.rm = TRUE),
    lfp_rate = weighted.mean(y_lfp, finalwt, na.rm = TRUE),
    absent_rate = weighted.mean(y_absent, finalwt, na.rm = TRUE),
    ft_rate = weighted.mean(y_fulltime, finalwt, na.rm = TRUE),
    avg_hrs = weighted.mean(y_actual_hrs_main, finalwt, na.rm = TRUE),
    union_rate = weighted.mean(y_union, finalwt, na.rm = TRUE)
  ) %>%
  print()

cat("\n[EXPOSURES]\n")
panel_ind %>%
  summarise(
    mean_smoke_days = mean(smoke_days, na.rm = TRUE),
    sd_smoke_days = sd(smoke_days, na.rm = TRUE),
    mean_pm25 = mean(pm25, na.rm = TRUE),
    sd_pm25 = sd(pm25, na.rm = TRUE),
    mean_temp = mean(mean_temp, na.rm = TRUE),
    mean_fires = mean(n_fires, na.rm = TRUE)
  ) %>%
  print()

cat("\n[HETEROGENEITY GROUPS - % of Sample]\n")
panel_ind %>%
  summarise(
    outdoor_work = mean(outdoor_work, na.rm = TRUE) * 100,
    vulnerable_worker = mean(vulnerable_worker, na.rm = TRUE) * 100,
    health_sensitive = mean(health_sensitive, na.rm = TRUE) * 100,
    precarious_job = mean(precarious_job, na.rm = TRUE) * 100,
    essential_worker = mean(essential_worker, na.rm = TRUE) * 100,
    youth = mean(age_youth, na.rm = TRUE) * 100,
    older = mean(age_older, na.rm = TRUE) * 100,
    low_edu = mean(low_edu, na.rm = TRUE) * 100,
    recent_immigrant = mean(recent_immigrant, na.rm = TRUE) * 100
  ) %>%
  pivot_longer(everything(), names_to = "group", values_to = "percent") %>%
  arrange(desc(percent)) %>%
  print()


# 11. FINAL VALIDATION

cat("\n", rep("=", 80), "\n", sep = "")
cat("FINAL VALIDATION\n")
cat(rep("=", 80), "\n", sep = "")

validation_passed <- TRUE

# Check 1: Panel structure
if (nrow(panel_month) != n_distinct(panel_month$cma_name) * n_distinct(panel_month$ym)) {
  cat("✗ Panel structure issue detected\n")
  validation_passed <- FALSE
} else {
  cat("✓ Panel structure validated\n")
}

# Check 2: Exposure variables
if (any(is.na(panel_ind$smoke_days)) | any(is.na(panel_ind$pm25))) {
  cat("✗ Missing exposure data in IV dataset\n")
  validation_passed <- FALSE
} else {
  cat("✓ Exposure data complete in IV dataset\n")
}

# Check 3: Survey weights
if (any(is.na(panel_ind$finalwt)) | any(panel_ind$finalwt <= 0)) {
  cat("✗ Invalid survey weights detected\n")
  validation_passed <- FALSE
} else {
  cat("✓ Survey weights valid\n")
}

# Check 4: Key outcomes
key_outcomes <- c("y_earn", "y_emp", "y_lfp")
missing_pct <- panel_ind %>%
  summarise(across(all_of(key_outcomes), ~mean(is.na(.)))) %>%
  max()

if (missing_pct > 0.5) {
  cat("✗ Excessive missing data in key outcomes (>50%)\n")
  validation_passed <- FALSE
} else {
  cat("✓ Key outcomes have acceptable completeness\n")
}

# Check 5: Fixed effects identifiers
if (any(is.na(panel_ind$cma_fe)) | any(is.na(panel_ind$prov_year))) {
  cat("✗ Missing fixed effects identifiers\n")
  validation_passed <- FALSE
} else {
  cat("✓ Fixed effects identifiers complete\n")
}

# Final message
cat("\n", rep("=", 80), "\n", sep = "")
if (validation_passed) {
  cat("✓✓✓ ALL VALIDATION CHECKS PASSED ✓✓✓\n")
  cat("Dataset is ready for:\n")
  cat("  • Reduced-form analysis\n")
  cat("  • IV estimation\n")
  cat("  • Heterogeneity analysis\n")
} else {
  cat("✗✗✗ VALIDATION FAILED - REVIEW ISSUES ABOVE ✗✗✗\n")
}
cat(rep("=", 80), "\n", sep = "")



# ---- Data Diagnostics ----

# ---- Check Data Structure ----
check_data_structure <- function(panel_ind, panel_month) {
  
  cat("\n=== DATA STRUCTURE CHECK ===\n")
  
  # Individual-level data
  cat("\nIndividual-level data (panel_ind):\n")
  cat("Total observations:", nrow(panel_ind), "\n")
  cat("Unique CMAs:", n_distinct(panel_ind$cma_name), "\n")
  cat("Unique time periods:", n_distinct(panel_ind$ym), "\n")
  cat("Obs per CMA-month:", nrow(panel_ind) / 
      (n_distinct(panel_ind$cma_name) * n_distinct(panel_ind$ym)), "\n")
    
  # Monthly aggregates
  cat("\nMonthly aggregate data (panel_month):\n")
  cat("Total CMA-months:", nrow(panel_month), "\n")
  cat("Time span:", min(panel_month$year), "to", max(panel_month$year), "\n")
  
  return(TRUE)
}

check_data_structure(panel_ind, panel_month)

# ---- Missing Data Analysis ----
analyze_missingness <- function(data) {
  na_summary <- data %>%
    summarise(across(everything(),
                     list(n_na = ~sum(is.na(.)),
                          pct_na = ~mean(is.na(.))*100))) %>%
    pivot_longer(everything(),
                 names_to = c("variable", ".value"),
                 names_pattern = "(.*)_(n_na|pct_na)")
  
  # Group by missingness pattern
  na_patterns <- na_summary %>%
    mutate(pattern = case_when(
      pct_na < 1 ~ "Complete",
      between(pct_na, 35, 40) ~ "NILF + Unemployed + Absent",
      between(pct_na, 45, 50) ~ "NILF + Unemployed", 
      pct_na > 90 ~ "Conditional (rare events)",
      TRUE ~ "Other"
    ))
  
  return(na_patterns)
}

analyze_missingness(panel_ind)
analyze_missingness(panel_month)


# ---- Save ----

write_csv(panel_month, PANEL_MONTH_CSV)
write_csv(panel_ind, PANEL_IND_CSV)

message("Saved: ", PANEL_MONTH_CSV)
message("Saved: ", PANEL_IND_CSV)

# ---- Samples ----
write_csv(sample_n(panel_month, min(500, nrow(panel_month))),
           file.path(INTERMED_DIR, "panel_month_sample.csv"))

write_csv(sample_n(panel_ind, min(500, nrow(panel_ind))),
           file.path(INTERMED_DIR, "panel_ind_sample.csv"))

message("06_process_panel.R complete.")

