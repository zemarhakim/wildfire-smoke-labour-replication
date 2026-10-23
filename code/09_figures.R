# ==============================================================================
# 09_figures.R
# Author: Zemar Hakim and Christopher S. Cotton
# ------------------------------------------------------------------------------
# Produces three figures, controlled by the toggles below. Each figure's data
# is only loaded if its toggle is on, so switching on just one doesn't pull in
# inputs the others need (panel_ind.csv for Figure 2 vs. the geo files for
# Figures 1 and 3).
#
# INPUT:  inputs/intermediate/panel_ind.csv       (Figure 2 only)
#         inputs/raw_data/geo/lpr_000b21a_e.shp   (Figures 1 and 3)
#         inputs/raw_data/geo/lcma000b21a_e.shp   (Figures 1 and 3)
#         inputs/raw_data/geo/NFDB_point_20250519.shp (Figure 1 only)
#         inputs/raw_data/smoke/smoke.gpkg        (Figure 3 only)
# OUTPUT: outputs/figures/fig1_fire_maps.png
#         outputs/figures/fig2_industry_net.png
#         outputs/figures/fig3_smoke_maps.png
# ==============================================================================

rm(list = ls())
gc()

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

library(tidyverse)
library(fixest)
library(glue)
library(sf)
library(terra)
library(lubridate)
library(janitor)
library(scales)

# ---- Choice of figure production ----
# TRUE/FALSE for whichever figure(s) you want to produce this run.
fig_1_fire  <- F # We use this one for the paper
fig_2_coef  <- T
fig_3_smoke <- F

fig_dir <- OUT_FIGURES
dir.create(fig_dir, showWarnings = FALSE)

# ---- Shared helper functions (used by Figure 2) ------------------------------

scale_model <- function(model, factor = 10) {
  model$coefficients <- model$coefficients * factor   # keeps coef() in sync with coeftable
  ct <- coeftable(model)
  ct[, 1:2] <- ct[, 1:2] * factor
  model$coeftable <- ct
  return(model)
}

fit_scale <- function(formula, data) {
  m <- feols(formula, data = data, weights = ~ finalwt, cluster = ~ cma_name^year)
  s <- scale_model(m)
  s$residuals <- NULL; s$fitted.val <- NULL; s$model_matrix_info <- NULL
  rm(m); gc()
  return(s)
}

# ---- Shared map setup (Figures 1 and 3) --------------------------------------
fire_months  <- 5:10
target_years <- c(2015:2024)   # 8 years, 2020 excluded
crs_proj     <- 3347                       # Statistics Canada Lambert

theme_map <- function() {
  theme_void(base_size = 9) +
    theme(
      panel.background = element_rect(fill = "#c8dce8", color = NA),
      legend.position  = "bottom",
      legend.key.width  = unit(7.5, "cm"),
      legend.key.height = unit(0.28, "cm"),
      legend.title     = element_text(size = 8),
      legend.text      = element_text(size = 7),
      legend.margin    = margin(t = 5, b = 2),
      strip.text       = element_text(size = 9, face = "bold"),
      plot.title       = element_text(size = 14, face = "bold", hjust = 0.5,
                                      margin = margin(b = 3, t = 4)),
      plot.subtitle    = element_text(size = 9, hjust = 0.5, color = "grey40",
                                      margin = margin(b = 6)),
      plot.caption     = element_text(size = 7, hjust = 0, color = "grey50",
                                      face = "bold", margin = margin(t = 6)),
      panel.spacing    = unit(0.25, "lines"),
      plot.background  = element_rect(fill = "white", color = NA),
      plot.margin      = margin(5, 8, 5, 8)
    )
}

nine_cmas <- c(
  "Québec", "Montréal",
  "Ottawa - Gatineau (Ontario part / partie de l'Ontario)",
  "Toronto", "Hamilton", "Winnipeg", "Calgary", "Edmonton", "Vancouver"
)

load_map_base <- function() {
  canada_prov <- st_read(PROV_SHP, quiet = TRUE) %>%
    st_make_valid() %>%
    st_transform(crs_proj)

  canada_union <- canada_prov %>% st_union() %>% st_make_valid()
  can_bbox <- st_bbox(canada_union)

  cma_pts <- st_read(CMA_SHP, quiet = TRUE) %>%
    st_make_valid() %>%
    filter(CMANAME %in% nine_cmas) %>%
    st_transform(crs_proj) %>%
    st_centroid() %>%
    select(CMANAME)

  list(
    canada_prov  = canada_prov,
    canada_union = canada_union,
    xlim_can     = as.numeric(c(can_bbox["xmin"], can_bbox["xmax"])),
    ylim_can     = as.numeric(c(can_bbox["ymin"], can_bbox["ymax"])),
    cma_pts      = cma_pts
  )
}

# ==============================================================================
# FIGURE 1: Wildfire location maps (the paper's published Figure 1)
# ==============================================================================

if (fig_1_fire) {

  map_base <- load_map_base()

  message("Loading NFDB fire points...")

  nfdb_raw <- st_read(NFDB_SHP, quiet = TRUE) %>%
    clean_names() %>%
    st_make_valid() %>%
    st_transform(crs_proj)

  nfdb_season <- nfdb_raw %>%
    mutate(
      yr      = as.integer(year),
      mo      = as.integer(month),
      size_ha = as.numeric(size_ha)
    ) %>%
    filter(
      mo %in% fire_months,
      yr %in% target_years,
      !is.na(size_ha),
      size_ha > 0,
      !st_is_empty(.)
    ) %>%
    mutate(
      size_cat = cut(
        size_ha,
        breaks = c(0, 1, 10, 100, 1000, 10000, Inf),
        labels = c("< 1 ha", "1\u201310 ha", "10\u2013100 ha",
                   "100\u20131,000 ha", "1,000\u201310,000 ha", "> 10,000 ha"),
        right = FALSE
      ),
      year_lbl = factor(as.character(yr), levels = as.character(target_years))
    ) %>%
    arrange(size_ha)

  message("  Fire observations: ", nrow(nfdb_season))

  fire_pal <- c(
    "< 1 ha" = "#fdd0a2", "1\u201310 ha" = "#fdae6b", "10\u2013100 ha" = "#f16913",
    "100\u20131,000 ha" = "#d94801", "1,000\u201310,000 ha" = "#8c2d04", "> 10,000 ha" = "#4a0c01"
  )
  fire_sizes <- c(
    "< 1 ha" = 0.07, "1\u201310 ha" = 0.22, "10\u2013100 ha" = 0.55,
    "100\u20131,000 ha" = 1.05, "1,000\u201310,000 ha" = 1.80, "> 10,000 ha" = 2.80
  )
  fire_alphas <- c(
    "< 1 ha" = 0.20, "1\u201310 ha" = 0.35, "10\u2013100 ha" = 0.55,
    "100\u20131,000 ha" = 0.72, "1,000\u201310,000 ha" = 0.88, "> 10,000 ha" = 0.96
  )

  fig1 <- ggplot() +
    geom_sf(data = map_base$canada_prov, fill = "#e4e4e4", color = NA) +
    geom_sf(data = nfdb_season,
            aes(color = size_cat, size = size_cat, alpha = size_cat), shape = 16) +
    geom_sf(data = map_base$canada_prov, fill = NA, color = "grey20", linewidth = 0.18) +
    geom_sf(data = map_base$cma_pts, shape = 17, size = 2.0, colour = "#47e38b",
            show.legend = FALSE) +
    scale_color_manual(
      name = "Fire size (ha)", values = fire_pal, limits = names(fire_pal), drop = FALSE,
      guide = guide_legend(title.position = "top", title.hjust = 0.5, nrow = 2,
                            override.aes = list(shape = 16, size = 2.5, alpha = 1))
    ) +
    scale_size_manual(values = fire_sizes, drop = FALSE, guide = "none") +
    scale_alpha_manual(values = fire_alphas, drop = FALSE, guide = "none") +
    coord_sf(crs = st_crs(crs_proj), xlim = map_base$xlim_can, ylim = map_base$ylim_can,
             expand = FALSE) +
    facet_wrap(~ year_lbl, ncol = 5, drop = FALSE) +
    theme_map()

  ggsave(file.path(fig_dir, "fig1_fire_maps.png"), fig1, width = 14, height = 7.5, dpi = 300)

  message("Figure 1 saved.")
}

# ==============================================================================
# FIGURE 2: Net PM2.5 effects by industry, covariance-adjusted CIs
# (supplementary)
# ==============================================================================

if (fig_2_coef) {

  needed_cols <- c(
    "cma_name", "year", "month", "finalwt",
    "y_log_earn", "y_actual_hrs_main", "y_condabs",
    "mean_temp", "total_precip", "pm25_15_rel", "smoke_15_rel",
    "ind_agriculture", "ind_forestry", "ind_fishing", "ind_mining",
    "ind_utilities", "ind_construction", "ind_wholesale", "ind_retail",
    "ind_transport", "ind_finance", "ind_realestate", "ind_professional",
    "ind_business_support", "ind_education", "ind_healthcare", "ind_info_culture",
    "ind_accommodation", "ind_other_services", "ind_public_admin"
  )

  panel_ind <- read_csv(PANEL_IND_CSV, col_select = all_of(needed_cols)) %>%
    filter(month %in% c(5, 6, 7, 8, 9, 10)) %>%
    mutate(
      y_log_hrs_p1            = log(y_actual_hrs_main + 1),
      ind_ag_forestry_fishing = as.integer(ind_agriculture + ind_forestry + ind_fishing > 0)
    )

  panel_n2020 <- panel_ind %>% filter(year != 2020)
  rm(panel_ind)
  gc()

  # ---- Industry IV models: three outcomes ----
  # Controls: weather + industry dummies | FEs: cma_name x month + year
  # Endo: pm25_15_rel x industry interactions | Inst: smoke_15_rel x same
  # Manufacturing is the omitted reference group throughout.
  iv_rhs <- paste0(
    "~ mean_temp + total_precip",
    " + ind_ag_forestry_fishing + ind_mining",
    " + ind_utilities + ind_construction",
    " + ind_wholesale + ind_retail + ind_transport",
    " + ind_finance + ind_realestate + ind_professional + ind_business_support",
    " + ind_education + ind_healthcare + ind_info_culture",
    " + ind_accommodation + ind_other_services + ind_public_admin",
    " | cma_name^month + year |",
    " pm25_15_rel",
    " + pm25_15_rel:ind_ag_forestry_fishing",
    " + pm25_15_rel:ind_mining",
    " + pm25_15_rel:ind_utilities + pm25_15_rel:ind_construction",
    " + pm25_15_rel:ind_wholesale + pm25_15_rel:ind_retail",
    " + pm25_15_rel:ind_transport",
    " + pm25_15_rel:ind_finance + pm25_15_rel:ind_realestate",
    " + pm25_15_rel:ind_professional + pm25_15_rel:ind_business_support",
    " + pm25_15_rel:ind_education + pm25_15_rel:ind_healthcare",
    " + pm25_15_rel:ind_info_culture + pm25_15_rel:ind_accommodation",
    " + pm25_15_rel:ind_other_services + pm25_15_rel:ind_public_admin",
    " ~ smoke_15_rel",
    " + smoke_15_rel:ind_ag_forestry_fishing",
    " + smoke_15_rel:ind_mining",
    " + smoke_15_rel:ind_utilities + smoke_15_rel:ind_construction",
    " + smoke_15_rel:ind_wholesale + smoke_15_rel:ind_retail",
    " + smoke_15_rel:ind_transport",
    " + smoke_15_rel:ind_finance + smoke_15_rel:ind_realestate",
    " + smoke_15_rel:ind_professional + smoke_15_rel:ind_business_support",
    " + smoke_15_rel:ind_education + smoke_15_rel:ind_healthcare",
    " + smoke_15_rel:ind_info_culture + smoke_15_rel:ind_accommodation",
    " + smoke_15_rel:ind_other_services + smoke_15_rel:ind_public_admin"
  )

  make_ind_formula <- function(yvar) as.formula(paste(yvar, iv_rhs))

  message("Fitting industry models...")

  m_iv_ind_earn_s      <- fit_scale(make_ind_formula("y_log_earn"),   data = panel_n2020)
  m_iv_ind_actualhrs_s <- fit_scale(make_ind_formula("y_log_hrs_p1"), data = panel_n2020)
  m_iv_ind_absent_s    <- fit_scale(make_ind_formula("y_condabs"),    data = panel_n2020)
  # NOTE: a fourth model on y_hrs_away ("hours away from work") was fit here
  # previously but never used anywhere downstream -- removed.

  message("All industry models fitted.")
  message("Figure 2: computing net effects and population-average reference...")

  # ---- Population-average reference (Pooled baseline IV) ----
  get_base_ref <- function(yvar) {
    f <- as.formula(paste0(
      yvar, " ~ mean_temp + total_precip | cma_name^month + year |",
      " pm25_15_rel ~ smoke_15_rel"
    ))
    m <- feols(f, data = panel_n2020, weights = ~finalwt, cluster = ~cma_name^year)
    est <- coef(m)["fit_pm25_15_rel"] * 10   # scale x10 to match paper units
    rm(m); gc()
    est
  }

  outcome_order <- c("Log Earnings", "Average Hours Worked", "Conditional Absence")

  pop_avg <- tibble(
    outcome = factor(outcome_order, levels = outcome_order),
    xref    = c(
      get_base_ref("y_log_earn"),
      get_base_ref("y_log_hrs_p1"),
      get_base_ref("y_condabs")
    )
  )

  message("Population-average reference estimates computed.")

  # ---- Net effects with covariance-adjusted CIs ----
  # Net effect = main PM2.5 coefficient + industry interaction coefficient.
  # vcov(model) returns the unscaled VCV, since scale_model()'s x10 factor is
  # only applied to model$coefficients and model$coeftable, not the stored
  # covariance matrix -- so it's rescaled here by 100 (=10^2) to match the
  # x10-scaled coeftable estimates used for `estimate`/`net_est` below.
  # Manufacturing is the omitted reference group, so its "net effect" is just
  # the baseline PM2.5 coefficient, with CI from Var(baseline) alone.
  extract_net_effects <- function(model, outcome_label) {

    ct_df <- as.data.frame(coeftable(model))
    ct_df$term <- rownames(ct_df)
    colnames(ct_df)[1:4] <- c("estimate", "se", "tstat", "pval")

    V <- tryCatch({
      100 * vcov(model)
    }, error = function(e) {
      warning(glue(
        "vcov() failed for {outcome_label}: {conditionMessage(e)}\n",
        "Falling back to SE-only CI (no covariance correction)."
      ))
      NULL
    })

    vnames <- if (!is.null(V)) rownames(V) else character(0)

    base_ct   <- "fit_pm25_15_rel"
    base_vcov <- if (base_ct %in% vnames) base_ct else
                 if ("pm25_15_rel" %in% vnames) "pm25_15_rel" else
                 NA_character_

    base_est  <- ct_df[ct_df$term == base_ct, "estimate"]
    base_pval <- ct_df[ct_df$term == base_ct, "pval"]
    var_b     <- if (!is.null(V) && !is.na(base_vcov)) V[base_vcov, base_vcov] else
                 ct_df[ct_df$term == base_ct, "se"]^2

    vcov_nm <- function(ct_nm) {
      if (ct_nm %in% vnames) return(ct_nm)
      plain <- sub("^fit_", "", ct_nm)
      if (plain %in% vnames) return(plain)
      NA_character_
    }

    int_df <- ct_df %>% filter(str_detect(term, "^fit_pm25_15_rel:ind_"))

    net_rows <- map_dfr(seq_len(nrow(int_df)), function(i) {
      ct_nm <- int_df$term[i]
      net   <- base_est + int_df$estimate[i]

      v_nm <- vcov_nm(ct_nm)
      if (!is.null(V) && !is.na(v_nm)) {
        var_i  <- V[v_nm, v_nm]
        cov_bi <- V[base_vcov, v_nm]
      } else {
        var_i  <- int_df$se[i]^2
        cov_bi <- 0
      }

      net_se <- sqrt(max(var_b + var_i + 2 * cov_bi, 0))

      tibble(
        term = ct_nm, net_est = net, net_se = net_se,
        net_ci_lo = net - 1.96 * net_se, net_ci_hi = net + 1.96 * net_se,
        net_pval  = 2 * pnorm(abs(net / net_se), lower.tail = FALSE)
      )
    })

    mfg_se  <- sqrt(var_b)
    mfg_row <- tibble(
      term = "fit_pm25_15_rel:ind_manufacturing", net_est = base_est, net_se = mfg_se,
      net_ci_lo = base_est - 1.96 * mfg_se, net_ci_hi = base_est + 1.96 * mfg_se,
      net_pval = base_pval
    )

    bind_rows(net_rows, mfg_row) %>% mutate(outcome = outcome_label)
  }

  ind_labels <- c(
    "fit_pm25_15_rel:ind_ag_forestry_fishing" = "Agriculture, Forestry & Fishing",
    "fit_pm25_15_rel:ind_mining"              = "Mining",
    "fit_pm25_15_rel:ind_utilities"           = "Utilities",
    "fit_pm25_15_rel:ind_construction"        = "Construction",
    "fit_pm25_15_rel:ind_wholesale"           = "Wholesale",
    "fit_pm25_15_rel:ind_retail"              = "Retail",
    "fit_pm25_15_rel:ind_transport"           = "Transport",
    "fit_pm25_15_rel:ind_finance"             = "Finance",
    "fit_pm25_15_rel:ind_realestate"          = "Real Estate",
    "fit_pm25_15_rel:ind_professional"        = "Professional Services",
    "fit_pm25_15_rel:ind_business_support"    = "Business Support",
    "fit_pm25_15_rel:ind_info_culture"        = "Info & Culture",
    "fit_pm25_15_rel:ind_accommodation"       = "Accommodation & Food",
    "fit_pm25_15_rel:ind_other_services"      = "Other Services",
    "fit_pm25_15_rel:ind_education"           = "Education",
    "fit_pm25_15_rel:ind_healthcare"          = "Healthcare",
    "fit_pm25_15_rel:ind_public_admin"        = "Public Administration",
    "fit_pm25_15_rel:ind_manufacturing"       = "Manufacturing (ref.)"
  )

  ind_order <- c(
    "Manufacturing (ref.)",
    "Agriculture, Forestry & Fishing", "Mining", "Utilities", "Construction",
    "Wholesale", "Retail", "Transport",
    "Finance", "Real Estate", "Professional Services",
    "Business Support", "Info & Culture",
    "Accommodation & Food", "Other Services",
    "Education", "Healthcare", "Public Administration"
  )

  fig2_data <- bind_rows(
    extract_net_effects(m_iv_ind_earn_s,      "Log Earnings"),
    extract_net_effects(m_iv_ind_actualhrs_s, "Average Hours Worked"),
    extract_net_effects(m_iv_ind_absent_s,    "Conditional Absence")
  ) %>%
    mutate(
      industry = ind_labels[term],
      industry = factor(industry, levels = ind_order),
      outcome  = factor(outcome, levels = outcome_order),
      sig = case_when(
        net_pval < 0.01 ~ "p < 0.01",
        net_pval < 0.05 ~ "p < 0.05",
        net_pval < 0.10 ~ "p < 0.10",
        TRUE            ~ "n.s."
      ),
      sig    = factor(sig, levels = c("p < 0.01", "p < 0.05", "p < 0.10", "n.s.")),
      is_ref = (industry == "Manufacturing (ref.)")
    ) %>%
    filter(!is.na(industry))

  theme_paper <- function() {
    theme_minimal(base_size = 11) +
      theme(
        panel.grid.minor   = element_blank(),
        panel.grid.major.y = element_blank(),
        panel.border       = element_rect(colour = "grey88", fill = NA, linewidth = 0.4),
        axis.text.y        = element_text(size = 9.5),
        axis.text.x        = element_text(size = 8.5),
        axis.title         = element_text(size = 10),
        legend.position    = "bottom",
        legend.title       = element_blank(),
        legend.text        = element_text(size = 10),
        legend.key.size    = unit(0.55, "cm"),
        legend.spacing.x   = unit(0.4, "cm"),
        strip.text         = element_text(size = 10.5, face = "bold"),
        strip.background   = element_rect(fill = "grey96", colour = "grey88"),
        plot.title         = element_text(size = 13, face = "bold"),
        plot.subtitle      = element_text(size = 9.5, colour = "grey40", margin = margin(b = 8)),
        plot.caption       = element_text(size = 8, hjust = 0, color = "grey45", margin = margin(t = 8)),
        panel.spacing.x    = unit(0.8, "lines"),
        panel.spacing.y    = unit(0.5, "lines")
      )
  }

  fig2 <- ggplot(fig2_data, aes(x = net_est, y = industry, colour = sig)) +
    geom_vline(xintercept = 0, linetype = "dashed", colour = "grey55", linewidth = 0.45) +
    geom_vline(data = pop_avg, aes(xintercept = xref),
               colour = "#c0392b", linetype = "dotdash", linewidth = 0.6, inherit.aes = FALSE) +
    geom_hline(yintercept = 1.5, colour = "grey75", linewidth = 0.3) +
    geom_errorbarh(aes(xmin = net_ci_lo, xmax = net_ci_hi, linetype = is_ref),
                   height = 0.32, linewidth = 0.65) +
    geom_point(aes(shape = interaction(sig, is_ref)), size = 2.6) +
    scale_colour_manual(
      values = c("p < 0.01" = "#1a4f7a", "p < 0.05" = "#3a7abf",
                 "p < 0.10" = "#85b4d9", "n.s." = "grey62"),
      guide  = guide_legend(title = "Net effect significance",
                            override.aes = list(size = 3.2, linetype = "solid", shape = 19))
    ) +
    scale_shape_manual(
      values = c("p < 0.01.FALSE" = 19, "p < 0.05.FALSE" = 19,
                 "p < 0.10.FALSE" = 1,  "n.s..FALSE"     = 1,
                 "p < 0.01.TRUE"  = 18, "p < 0.05.TRUE"  = 18,
                 "p < 0.10.TRUE"  = 5,  "n.s..TRUE"      = 5),
      guide = "none"
    ) +
    scale_linetype_manual(values = c("FALSE" = "solid", "TRUE" = "longdash"), guide = "none") +
    facet_wrap(~ outcome, scales = "free_x", ncol = 3) +
    labs(
      title    = "Net PM\u2082.\u2085 Effects by Industry",
      subtitle = paste0(
        "Total effect = PM\u2082.\u2085 baseline + industry interaction  \u2502  ",
        "Manufacturing (diamond) is the reference anchor  \u2502  ",
        "Red line: population average"
      ),
      x = "Net coefficient (per 10 \u03bcg/m\u00b3 increase in relative PM\u2082.\u2085)",
      y = NULL,
      caption = paste0(
        "IV estimates, 2020 excluded. 95% CIs from the full VCV matrix, ",
        "accounting for covariance between baseline and interaction coefficients.\n",
        "Manufacturing point reflects the baseline PM\u2082.\u2085 coefficient alone (log(hours+1) for Actual Hours Worked). ",
        "Agriculture, forestry, and fishing are combined into one category. ",
        "Standard errors clustered at CMA\u00d7Year level."
      )
    ) +
    theme_paper()

  ggsave(file.path(fig_dir, "fig2_industry_net.png"), fig2, width = 16, height = 7.5, dpi = 300)

  message("Figure 2 (net effects, covariance-adjusted) saved.")
}

# ==============================================================================
# FIGURE 3 (supplementary): annual smoke-day density maps
# ==============================================================================

if (fig_3_smoke) {

  map_base <- load_map_base()

  message("Loading smoke polygons...")

  smoke_raw <- st_read(SMOKE_GPKG, layer = "smoke", quiet = TRUE) %>%
    st_make_valid() %>%
    st_transform(crs_proj) %>%
    mutate(
      file_date = as.Date(file_date),
      yr = year(file_date),
      mo = month(file_date)
    ) %>%
    filter(mo %in% fire_months, yr %in% target_years, !sf::st_is_empty(geom)) %>%
    filter(Density == "Heavy")

  message("  Loaded: ", nrow(smoke_raw), " smoke polygon-days")

  message("Rasterizing smoke data by year...")

  base_ext <- ext(map_base$xlim_can[1], map_base$xlim_can[2],
                   map_base$ylim_can[1], map_base$ylim_can[2])
  base_r <- rast(base_ext, resolution = 100000, crs = paste0("EPSG:", crs_proj))

  canada_v  <- vect(st_as_sf(map_base$canada_union))
  land_mask <- rasterize(canada_v, base_r, field = 1, background = NA)

  smoke_rast_list <- map(target_years, function(y) {
    message("  Rasterizing year: ", y)

    smoke_yr <- smoke_raw %>% filter(yr == y) %>% st_make_valid() %>%
      filter(!sf::st_is_empty(geom))

    message("    polygons: ", nrow(smoke_yr))

    if (nrow(smoke_yr) == 0L) { r <- base_r; values(r) <- NA_real_; return(r) }

    dates_yr <- sort(unique(smoke_yr$file_date))
    day_layers <- map(dates_yr, function(d) {
      day_sf <- smoke_yr %>% filter(file_date == d) %>% st_make_valid() %>%
        filter(!sf::st_is_empty(geom))
      if (nrow(day_sf) == 0L) return(NULL)
      terra::rasterize(terra::vect(day_sf), base_r, field = 1, background = NA, touches = TRUE)
    }) %>% compact()

    message("    valid daily layers: ", length(day_layers))

    if (length(day_layers) == 0L) { r <- base_r; values(r) <- NA_real_; return(r) }

    r_sum <- terra::app(terra::rast(day_layers), fun = function(x) {
      z <- sum(!is.na(x)); ifelse(z == 0L, NA_real_, as.numeric(z))
    })
    terra::mask(r_sum, land_mask)
  })

  smoke_df <- map2_dfr(smoke_rast_list, target_years, function(r, y) {
    df <- as.data.frame(r, xy = TRUE)
    names(df)[3] <- "smoke_days"
    df$year_lbl <- as.character(y)
    df[!is.na(df$smoke_days) & df$smoke_days > 0, ]
  }) %>%
    mutate(year_lbl = factor(year_lbl, levels = as.character(target_years)))

  message("smoke_df rows: ", nrow(smoke_df))

  max_smoke <- quantile(smoke_df$smoke_days, 0.90, na.rm = TRUE)

  fig3 <- ggplot() +
    geom_sf(data = map_base$canada_prov, fill = "#f5f0eb", color = NA) +
    geom_raster(data = smoke_df, aes(x = x, y = y, fill = smoke_days)) +
    geom_sf(data = map_base$canada_prov, fill = NA, color = "white", linewidth = 0.25) +
    geom_sf(data = map_base$cma_pts, aes(shape = "Metro Area"),
            size = 1.8, colour = "#47e38b", stroke = 0.3) +
    scale_fill_gradientn(
      name = "Annual Smoke Days",
      colors = c("#f7e8e8", "#e8b4c8", "#d4679e", "#9b3080", "#5c1a6b", "#1a0a3d"),
      limits = c(1, max_smoke), oob = scales::squish, trans = "sqrt", na.value = NA,
      breaks = scales::extended_breaks(n = 5),
      guide = guide_colorbar(title.position = "top", title.hjust = 0.5,
                             barwidth = unit(6, "cm"), barheight = unit(0.3, "cm"),
                             ticks.colour = "white", frame.colour = NA, order = 1)
    ) +
    scale_shape_manual(values = c("Metro Area" = 17),
                       guide = guide_legend(title = NULL,
                                            override.aes = list(size = 3, colour = "#47e38b"),
                                            order = 2)) +
    coord_sf(crs = st_crs(crs_proj), xlim = map_base$xlim_can, ylim = map_base$ylim_can, expand = FALSE) +
    facet_wrap(~ year_lbl, ncol = 4, drop = FALSE) +
    labs(
      title = "Annual Number of Smoke Days",
      caption = paste0(
        "This figure plots the number of smoke-exposure days across Canada ",
        "during the May\u2013October fire season.\n",
        "Source: NOAA Hazard Mapping System (HMS) Fire and Smoke Product."
      )
    ) +
    theme_void(base_size = 9) +
    theme(
      plot.background = element_rect(fill = "white", color = NA),
      panel.background = element_rect(fill = "white", color = NA),
      plot.title = element_text(size = 11, hjust = 0.5, margin = margin(b = 6, t = 4)),
      strip.text = element_text(size = 9, margin = margin(b = 3, t = 1)),
      legend.position = "bottom",
      legend.title = element_text(size = 8, face = "bold"),
      legend.text = element_text(size = 7.5),
      legend.margin = margin(t = 4, b = 4),
      plot.caption = element_text(size = 7, hjust = 0, color = "grey30",
                                  margin = margin(t = 8), lineheight = 1.3),
      panel.spacing = unit(0.2, "lines"),
      plot.margin = margin(6, 8, 6, 8)
    )

  ggsave(file.path(fig_dir, "fig3_smoke_maps.png"), fig3, width = 12, height = 6.8, dpi = 300)

  message("Figure 3 saved.")
}

message("09_figures.R complete.")
