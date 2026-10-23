# ==============================================================================
# 04_scrape_weather.R
# ------------------------------------------------------------------------------
# INPUT:  none required locally -- downloads daily weather CSVs directly from
#         Environment and Climate Change Canada's bulk data endpoint.
# OUTPUT: inputs/raw_data/weather/<City>_<Year>_<Month>.csv
#         (one file per station-year-month, 2015-2024; this is what
#         05_process_weather.R reads)
#
# Ported from a standalone bash script (scrape_file.txt) to R so it uses the
# same PROJECT_ROOT/00_config.R path convention as the rest of the pipeline.
# Station IDs and URL structure are unchanged from the original.
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

library(glue)

stations <- list(
  c("51459", "Toronto"),
  c("51157", "Montreal"),
  c("51442", "Vancouver"),
  c("50430", "Calgary"),
  c("49568", "Ottawa"),
  c("50149", "Edmonton"),
  c("27174", "Winnipeg"),
  c("26892", "QuebecCity"),
  c("49908", "Hamilton")
)

years  <- 2015:2024
months <- sprintf("%02d", 1:12)

for (s in stations) {
  id   <- s[1]
  city <- s[2]

  message("Downloading data for ", city, " (", id, ")...")

  for (year in years) {
    for (month in months) {
      url <- glue(
        "https://climate.weather.gc.ca/climate_data/bulk_data_e.html?",
        "format=csv&stationID={id}&Year={year}&Month={month}&Day=1",
        "&timeframe=2&submit=Download+Data"
      )
      outfile <- file.path(WEATHER_RAW_DIR, glue("{city}_{year}_{month}.csv"))

      tryCatch(
        download.file(url, outfile, mode = "wb", quiet = TRUE),
        error = function(e) message("  Failed: ", city, " ", year, "-", month)
      )

      message("  -> Saved ", outfile)
      Sys.sleep(0.3)
    }
  }
}

message("All downloads complete. Files saved in: ", WEATHER_RAW_DIR)
message("04_scrape_weather.R complete.")
